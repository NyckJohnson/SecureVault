import AVFoundation
import Combine
import UIKit

/// The full-screen viewer: a pager of file pages under a top bar and the video controls.
///
/// It owns the one player its pages share. A page puts its item on the player while it is the visible page, so
/// this screen only follows the player: whatever is on it is what the controls show.
@MainActor
final class FileViewerViewController: UIViewController, AlertPresenting {
    private let viewModel: FileViewerViewModel
    private let store: any VaultStoring
    private let videoAssets: any VideoAssetProviding
    private let exportPresenter: ExportPresenter
    private let makeEditor: @MainActor (VaultItem) -> UIViewController
    private let player = AVPlayer()
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private var subscriptions: Set<AnyCancellable> = []
    private var playerSubscriptions: Set<AnyCancellable> = []
    private var itemDuration: AnyCancellable?
    private var timeObservation: PeriodicTimeObservation?
    private var isScrubbing = false
    private var didTearDown = false

    // Top bar
    private let navBar = UIView()
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let exportButton = UIButton(type: .system)

    // Video controls
    private let videoControls = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let skipBackButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let scrubber = UISlider()
    private let currentTimeLabel = UILabel()
    private let totalTimeLabel = UILabel()
    private let bufferView = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var bufferWidthConstraint: NSLayoutConstraint?

    /// - Parameter makeEditor: makes the screen an `.rtf` page opens.
    init(
        items: [VaultItem], startingAt index: Int, store: any VaultStoring,
        videoAssets: any VideoAssetProviding, exportPresenter: ExportPresenter,
        makeEditor: @escaping @MainActor (VaultItem) -> UIViewController
    ) {
        self.viewModel = FileViewerViewModel(items: items, startingAt: index, store: store)
        self.store = store
        self.videoAssets = videoAssets
        self.exportPresenter = exportPresenter
        self.makeEditor = makeEditor
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { nil }

    /// The last way out: a stack dismissed from below this screen reports nothing to it. `close()` does nothing
    /// the second time, so this is harmless after a normal close.
    deinit {
        Task { @MainActor [viewModel] in viewModel.close() }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "viewer"
        setupPager()
        setupNavBar()
        setupVideoControls()
        bindViewModel()
        bindPlayer()
        render()
    }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { tearDown() }
    }

    // MARK: - Binding

    private func bindViewModel() {
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
        viewModel.$barsVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in self?.showBars(visible) }
            .store(in: &subscriptions)
    }

    private func bindPlayer() {
        player.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.currentItemChanged(item) }
            .store(in: &playerSubscriptions)
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.showPlayerStatus(status) }
            .store(in: &playerSubscriptions)
        player.publisher(for: \.timeControlStatus)
            .map { $0 != .paused }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in self?.viewModel.playbackStateChanged(isPlaying: isPlaying) }
            .store(in: &playerSubscriptions)
        timeObservation = PeriodicTimeObservation(
            player: player, interval: CMTime(seconds: 0.5, preferredTimescale: 600)
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncPlayback()
                self.updateBufferIndicator()
            }
        }
    }

    private func render() {
        titleLabel.text = viewModel.title
        videoControls.isHidden = !viewModel.showsVideoControls
        guard !isScrubbing else { return }
        scrubber.value = Float(viewModel.progress)
        currentTimeLabel.text = FileViewerViewModel.formatTime(viewModel.currentTime)
        totalTimeLabel.text = FileViewerViewModel.formatTime(viewModel.duration)
    }

    private func showBars(_ visible: Bool) {
        UIView.animate(withDuration: 0.3) {
            self.navBar.alpha = visible ? 1 : 0
            self.videoControls.alpha = visible ? 1 : 0
        }
    }

    private func currentItemChanged(_ item: AVPlayerItem?) {
        bufferWidthConstraint?.constant = 0
        viewModel.updatePlayback(currentTime: 0, duration: 0)
        itemDuration = item?.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncPlayback() }
    }

    private func showPlayerStatus(_ status: AVPlayer.TimeControlStatus) {
        let isBuffering = status == .waitingToPlayAtSpecifiedRate
        if isBuffering {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        playPauseButton.isHidden = isBuffering
        let name = status == .paused ? "play.fill" : "pause.fill"
        playPauseButton.setImage(UIImage(systemName: name, withConfiguration: Self.buttonSymbols), for: .normal)
    }

    /// Hands the player's position to the view model; not while the user holds the scrubber.
    private func syncPlayback() {
        guard !isScrubbing else { return }
        viewModel.updatePlayback(
            currentTime: player.currentTime().seconds,
            duration: player.currentItem?.duration.seconds ?? 0)
    }

    private func updateBufferIndicator() {
        guard let item = player.currentItem else { return }
        let total = item.duration.seconds
        guard total.isFinite, total > 0 else { return }
        let now = player.currentTime()
        let buffered =
            item.loadedTimeRanges.map(\.timeRangeValue)
            .filter { $0.containsTime(now) }
            .map(\.end.seconds)
            .max() ?? 0
        let width = scrubber.bounds.width * CGFloat(min(buffered / total, 1))
        UIView.animate(withDuration: 0.3) {
            self.bufferWidthConstraint?.constant = width
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Actions

    @objc private func toggleBars() {
        viewModel.toggleBars()
    }

    @objc private func close() {
        tearDown()
        dismiss(animated: true)
    }

    /// Stops playback, ends the time updates and removes this viewer's decrypted copies. Runs once, on whichever
    /// way out comes first.
    private func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        player.pause()
        timeObservation = nil
        playerSubscriptions = []
        itemDuration = nil
        viewModel.close()
    }

    @objc private func exportCurrent() {
        guard viewModel.items.indices.contains(viewModel.currentIndex) else { return }
        exportPresenter.presentExportSheet(
            for: [viewModel.items[viewModel.currentIndex]], from: self, anchor: .sourceView(navBar))
    }

    @objc private func togglePlayPause() {
        guard player.currentItem != nil else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    @objc private func skipBack() {
        syncPlayback()
        seek(toSeconds: viewModel.skipBackward())
    }

    @objc private func skipForward() {
        syncPlayback()
        seek(toSeconds: viewModel.skipForward())
    }

    private func seek(toSeconds seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    @objc private func scrubberTouchBegan() {
        isScrubbing = true
        viewModel.scrubbingChanged(true)
    }

    @objc private func scrubberValueChanged() {
        currentTimeLabel.text = FileViewerViewModel.formatTime(Double(scrubber.value) * viewModel.duration)
    }

    @objc private func scrubberTouchEnded() {
        // AVFoundation raises an exception on a seek with a completion handler before the item is ready.
        guard player.currentItem?.status == .readyToPlay, viewModel.duration > 0 else {
            finishScrubbing()
            return
        }
        let time = CMTime(seconds: Double(scrubber.value) * viewModel.duration, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.finishScrubbing() }
        }
    }

    private func finishScrubbing() {
        isScrubbing = false
        syncPlayback()
        viewModel.scrubbingChanged(false)
    }

    // MARK: - Setup

    private func setupPager() {
        pager.dataSource = self
        pager.delegate = self
        if let initial = makePage(at: viewModel.currentIndex) {
            pager.setViewControllers([initial], direction: .forward, animated: false)
        }
        addChild(pager)
        view.addSubview(pager.view)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pager.view.accessibilityIdentifier = "viewer.pager"
        pager.didMove(toParent: self)
        pager.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleBars)))
    }

    private func makePage(at index: Int) -> FilePageViewController? {
        guard viewModel.items.indices.contains(index) else { return nil }
        // Strong on purpose, and not a cycle: the viewer's model holds no page. A page still opening its file
        // after the viewer has gone keeps the model until it has reported the copy, which `close` then removes
        // at once; a weak reference would leave that decrypted copy behind.
        let viewerModel = viewModel
        let pageModel = FilePageViewModel(
            item: viewModel.items[index], store: store, videoAssets: videoAssets,
            onTemporaryFile: { url in viewerModel.registerTemporaryFile(url) })
        return FilePageViewController(index: index, viewModel: pageModel, player: player, makeEditor: makeEditor)
    }

    private func setupNavBar() {
        navBar.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        navBar.translatesAutoresizingMaskIntoConstraints = false
        navBar.accessibilityIdentifier = "viewer.topBar"
        view.addSubview(navBar)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityIdentifier = "viewer.closeButton"

        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.accessibilityIdentifier = "viewer.titleLabel"

        exportButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        exportButton.tintColor = .white
        exportButton.addTarget(self, action: #selector(exportCurrent), for: .touchUpInside)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.accessibilityIdentifier = "viewer.shareButton"

        navBar.addSubview(closeButton)
        navBar.addSubview(titleLabel)
        navBar.addSubview(exportButton)

        var constraints: [NSLayoutConstraint] = []
        constraints.append(navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor))
        constraints.append(navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor))
        constraints.append(navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor))
        constraints.append(navBar.heightAnchor.constraint(equalToConstant: 60))

        constraints.append(closeButton.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 16))
        constraints.append(closeButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor))
        constraints.append(closeButton.widthAnchor.constraint(equalToConstant: 44))
        constraints.append(closeButton.heightAnchor.constraint(equalToConstant: 44))

        constraints.append(titleLabel.centerXAnchor.constraint(equalTo: navBar.centerXAnchor))
        constraints.append(titleLabel.centerYAnchor.constraint(equalTo: navBar.centerYAnchor))
        constraints.append(
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8))
        constraints.append(
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: navBar.trailingAnchor, constant: -60))

        constraints.append(exportButton.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -16))
        constraints.append(exportButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor))
        constraints.append(exportButton.widthAnchor.constraint(equalToConstant: 44))
        constraints.append(exportButton.heightAnchor.constraint(equalToConstant: 44))
        NSLayoutConstraint.activate(constraints)
    }

    private static let buttonSymbols = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)

    private func setupVideoControls() {
        videoControls.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        videoControls.translatesAutoresizingMaskIntoConstraints = false
        videoControls.accessibilityIdentifier = "viewer.videoControls"
        view.addSubview(videoControls)

        skipBackButton.setImage(
            UIImage(systemName: "gobackward.10", withConfiguration: Self.buttonSymbols), for: .normal)
        skipBackButton.tintColor = .white
        skipBackButton.addTarget(self, action: #selector(skipBack), for: .touchUpInside)
        skipBackButton.translatesAutoresizingMaskIntoConstraints = false
        skipBackButton.accessibilityIdentifier = "viewer.skipBackButton"

        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: Self.buttonSymbols), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.accessibilityIdentifier = "viewer.playPauseButton"

        skipForwardButton.setImage(
            UIImage(systemName: "goforward.10", withConfiguration: Self.buttonSymbols), for: .normal)
        skipForwardButton.tintColor = .white
        skipForwardButton.addTarget(self, action: #selector(skipForward), for: .touchUpInside)
        skipForwardButton.translatesAutoresizingMaskIntoConstraints = false
        skipForwardButton.accessibilityIdentifier = "viewer.skipForwardButton"

        currentTimeLabel.text = "0:00"
        currentTimeLabel.textColor = .white
        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.accessibilityIdentifier = "viewer.currentTimeLabel"

        totalTimeLabel.text = "0:00"
        totalTimeLabel.textColor = .white
        totalTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        totalTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        totalTimeLabel.accessibilityIdentifier = "viewer.totalTimeLabel"

        bufferView.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        bufferView.layer.cornerRadius = 1
        bufferView.translatesAutoresizingMaskIntoConstraints = false
        bufferView.accessibilityIdentifier = "viewer.bufferIndicator"

        scrubber.minimumValue = 0
        scrubber.maximumValue = 1
        scrubber.value = 0
        scrubber.minimumTrackTintColor = .white
        scrubber.maximumTrackTintColor = .clear
        scrubber.setThumbImage(makeThumbImage(), for: .normal)
        scrubber.addTarget(self, action: #selector(scrubberTouchBegan), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubberValueChanged), for: .valueChanged)
        scrubber.addTarget(
            self, action: #selector(scrubberTouchEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.accessibilityIdentifier = "viewer.scrubber"

        spinner.tintColor = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.accessibilityIdentifier = "viewer.bufferingSpinner"

        videoControls.addSubview(bufferView)
        videoControls.addSubview(scrubber)
        videoControls.addSubview(currentTimeLabel)
        videoControls.addSubview(totalTimeLabel)
        videoControls.addSubview(skipBackButton)
        videoControls.addSubview(playPauseButton)
        videoControls.addSubview(skipForwardButton)
        videoControls.addSubview(spinner)
        layoutVideoControls()
    }

    private func layoutVideoControls() {
        let bufferWidth = bufferView.widthAnchor.constraint(equalToConstant: 0)
        bufferWidthConstraint = bufferWidth

        var constraints: [NSLayoutConstraint] = []
        constraints.append(videoControls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor))
        constraints.append(videoControls.leadingAnchor.constraint(equalTo: view.leadingAnchor))
        constraints.append(videoControls.trailingAnchor.constraint(equalTo: view.trailingAnchor))
        constraints.append(videoControls.heightAnchor.constraint(equalToConstant: 100))

        constraints.append(
            currentTimeLabel.leadingAnchor.constraint(equalTo: videoControls.leadingAnchor, constant: 16))
        constraints.append(currentTimeLabel.topAnchor.constraint(equalTo: videoControls.topAnchor, constant: 12))

        constraints.append(
            totalTimeLabel.trailingAnchor.constraint(equalTo: videoControls.trailingAnchor, constant: -16))
        constraints.append(totalTimeLabel.topAnchor.constraint(equalTo: videoControls.topAnchor, constant: 12))

        constraints.append(scrubber.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 8))
        constraints.append(scrubber.trailingAnchor.constraint(equalTo: totalTimeLabel.leadingAnchor, constant: -8))
        constraints.append(scrubber.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor))

        constraints.append(bufferView.leadingAnchor.constraint(equalTo: scrubber.leadingAnchor, constant: 2))
        constraints.append(bufferWidth)
        constraints.append(bufferView.centerYAnchor.constraint(equalTo: scrubber.centerYAnchor))
        constraints.append(bufferView.heightAnchor.constraint(equalToConstant: 2))

        constraints.append(playPauseButton.centerXAnchor.constraint(equalTo: videoControls.centerXAnchor))
        constraints.append(playPauseButton.topAnchor.constraint(equalTo: scrubber.bottomAnchor, constant: 8))

        constraints.append(
            skipBackButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -40))
        constraints.append(skipBackButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor))

        constraints.append(
            skipForwardButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 40))
        constraints.append(skipForwardButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor))

        constraints.append(spinner.centerXAnchor.constraint(equalTo: videoControls.centerXAnchor))
        constraints.append(spinner.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor))
        NSLayoutConstraint.activate(constraints)
    }

    private func makeThumbImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }
}

// MARK: - UIPageViewControllerDataSource

extension FileViewerViewController: UIPageViewControllerDataSource {
    func pageViewController(
        _ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? FilePageViewController,
            let index = viewModel.previousIndex(of: page.index)
        else { return nil }
        return makePage(at: index)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? FilePageViewController,
            let index = viewModel.nextIndex(of: page.index)
        else { return nil }
        return makePage(at: index)
    }
}

// MARK: - UIPageViewControllerDelegate

extension FileViewerViewController: UIPageViewControllerDelegate {
    func pageViewController(
        _ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
        guard completed, let page = pageViewController.viewControllers?.first as? FilePageViewController else { return }
        viewModel.pageDidChange(to: page.index)
    }
}

// MARK: - Time observation

/// A periodic time observer that is removed from its player when this is released, so it can't outlive the player
/// (this holds the player) and is removed however its owner goes away.
private final class PeriodicTimeObservation {
    private let player: AVPlayer
    private let token: Any

    /// - Parameter update: runs on the main queue.
    init(player: AVPlayer, interval: CMTime, update: @escaping @Sendable () -> Void) {
        self.player = player
        self.token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in update() }
    }

    deinit {
        player.removeTimeObserver(token)
    }
}
