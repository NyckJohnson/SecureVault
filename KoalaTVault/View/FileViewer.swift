//
//  FileViewerViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/11/26.
//

import UIKit
import AVKit

final class FileViewerViewController: UIViewController {
    private let items: [VaultItem]
    private var currentIndex: Int
    private var pageViewController: UIPageViewController!
    private var isNavBarHidden      = false
    
    // Nav Bar Elements
    private let navBar      = UIView()
    private let closeButton = UIButton(type: .system)
    private let titleLabel  = UILabel()
    
    // Video Controls
    private let videoControls     = UIView()
    private let playPauseButton   = UIButton(type: .system)
    private let skipBackButton    = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let scrubber          = UISlider()
    private let currentTimeLabel  = UILabel()
    private let totalTimeLabel    = UILabel()
    private let bufferView        = UIView()
    private let spinner           = UIActivityIndicatorView(style: .medium)
    private var isScrubbing       = false
    private var bufferWidthConstraint: NSLayoutConstraint?
    private var timeObserver: Any?
    private var hideControlsTimer: Timer?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?

    var player: AVPlayer? {
        didSet {
            oldValue.map { removeTimeObserver(from: $0) }
            resetVideoControls()
            if let player { addTimeObserver(to: player) }
        }
    }
    
    init(items: [VaultItem], startingAt index: Int) {
        self.items = items
        self.currentIndex = index
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPageViewController()
        setupNavBar()
        setupVideoControls()
        updateUI(for: items[currentIndex])
    }
    
    override var prefersStatusBarHidden: Bool { true }
    
    // MARK: - Page View Controller
    private func setupPageViewController() {
        pageViewController            = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pageViewController.dataSource = self
        pageViewController.delegate   = self
        
        let initial = FilePageViewController(item: items[currentIndex], viewer: self)
        pageViewController.setViewControllers([initial], direction: .forward, animated: false)
        
        addChild(pageViewController)
        view.addSubview(pageViewController.view)
        pageViewController.view.frame = view.bounds
        pageViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageViewController.didMove(toParent: self)
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleNavBar))
        pageViewController.view.addGestureRecognizer(tap)
    }
    
    // MARK: - Nav Bar
    private func setupNavBar() {
        navBar.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        navBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(navBar)
        
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        
        titleLabel.textColor     = .white
        titleLabel.font          = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        navBar.addSubview(closeButton)
        navBar.addSubview(titleLabel)
        
        let exportButton = UIButton(type: .system)
        exportButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        exportButton.tintColor = .white
        exportButton.addTarget(self, action: #selector(exportCurrent), for: .touchUpInside)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        navBar.addSubview(exportButton)
        
        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 60),
            
            closeButton.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            
            titleLabel.centerXAnchor.constraint(equalTo: navBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: navBar.trailingAnchor, constant: -60),
            
            exportButton.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -16),
            exportButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            exportButton.widthAnchor.constraint(equalToConstant: 44),
            exportButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    private func setupVideoControls() {
        videoControls.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        videoControls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoControls)

        let buttonConfig = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)

        skipBackButton.setImage(UIImage(systemName: "gobackward.10", withConfiguration: buttonConfig), for: .normal)
        skipBackButton.tintColor = .white
        skipBackButton.addTarget(self, action: #selector(skipBack), for: .touchUpInside)
        skipBackButton.translatesAutoresizingMaskIntoConstraints = false

        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: buttonConfig), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false

        skipForwardButton.setImage(UIImage(systemName: "goforward.10", withConfiguration: buttonConfig), for: .normal)
        skipForwardButton.tintColor = .white
        skipForwardButton.addTarget(self, action: #selector(skipForward), for: .touchUpInside)
        skipForwardButton.translatesAutoresizingMaskIntoConstraints = false

        currentTimeLabel.text = "0:00"
        currentTimeLabel.textColor = .white
        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false

        totalTimeLabel.text = "0:00"
        totalTimeLabel.textColor = .white
        totalTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        totalTimeLabel.translatesAutoresizingMaskIntoConstraints = false

        // buffer background track
        bufferView.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        bufferView.layer.cornerRadius = 1
        bufferView.translatesAutoresizingMaskIntoConstraints = false

        scrubber.minimumValue = 0
        scrubber.maximumValue = 1
        scrubber.value = 0
        scrubber.minimumTrackTintColor = .white
        scrubber.maximumTrackTintColor = .clear
        scrubber.setThumbImage(makeThumbImage(), for: .normal)
        scrubber.addTarget(self, action: #selector(scrubberTouchBegan), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubberValueChanged), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubberTouchEnded), for: [.touchUpInside, .touchUpOutside])
        scrubber.translatesAutoresizingMaskIntoConstraints = false

        spinner.tintColor = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        videoControls.addSubview(bufferView)
        videoControls.addSubview(scrubber)
        videoControls.addSubview(currentTimeLabel)
        videoControls.addSubview(totalTimeLabel)
        videoControls.addSubview(skipBackButton)
        videoControls.addSubview(playPauseButton)
        videoControls.addSubview(skipForwardButton)
        videoControls.addSubview(spinner)

        let bufferWidth = bufferView.widthAnchor.constraint(equalToConstant: 0)
        bufferWidthConstraint = bufferWidth

        NSLayoutConstraint.activate([
            videoControls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            videoControls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoControls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoControls.heightAnchor.constraint(equalToConstant: 100),

            currentTimeLabel.leadingAnchor.constraint(equalTo: videoControls.leadingAnchor, constant: 16),
            currentTimeLabel.topAnchor.constraint(equalTo: videoControls.topAnchor, constant: 12),

            totalTimeLabel.trailingAnchor.constraint(equalTo: videoControls.trailingAnchor, constant: -16),
            totalTimeLabel.topAnchor.constraint(equalTo: videoControls.topAnchor, constant: 12),

            scrubber.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 8),
            scrubber.trailingAnchor.constraint(equalTo: totalTimeLabel.leadingAnchor, constant: -8),
            scrubber.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),

            bufferView.leadingAnchor.constraint(equalTo: scrubber.leadingAnchor, constant: 2),
            bufferWidth,
            bufferView.centerYAnchor.constraint(equalTo: scrubber.centerYAnchor),
            bufferView.heightAnchor.constraint(equalToConstant: 2),

            playPauseButton.centerXAnchor.constraint(equalTo: videoControls.centerXAnchor),
            playPauseButton.topAnchor.constraint(equalTo: scrubber.bottomAnchor, constant: 8),

            skipBackButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -40),
            skipBackButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),

            skipForwardButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 40),
            skipForwardButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: videoControls.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor)
        ])
    }

    private func makeThumbImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }
    
    @objc private func toggleNavBar() {
        isNavBarHidden.toggle()
        UIView.animate(withDuration: 0.3) {
            self.navBar.alpha = self.isNavBarHidden ? 0 : 1
            self.videoControls.alpha = self.isNavBarHidden ? 0 : 1
        }
    }
    
    // MARK: - UI Updates
    private func resetVideoControls() {
        scrubber.value = 0
        currentTimeLabel.text = "0:00"
        totalTimeLabel.text = "0:00"
        bufferWidthConstraint?.constant = 0
    }

    func updateUI(for item: VaultItem) {
        titleLabel.text = item.name
        let ext = (item.name as NSString).pathExtension.lowercased()
        videoControls.isHidden = FileKind(extension: ext) != .video
    }
    
    func updatePlayPauseButton(isPlaying: Bool) {
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        let name   = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: name, withConfiguration: config), for: .normal)
    }
    
    // MARK: - Actions
    @objc private func close() {
        if let player { removeTimeObserver(from: player) }
        player?.pause()
        FileSystem.shared.cleanupTempFiles()
        dismiss(animated: true)
    }
    
    @objc private func exportCurrent() {
        let item = items[currentIndex]
        ExportService.shared.export(item, from: self, sourceView: navBar)
    }
    
    @objc func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            updatePlayPauseButton(isPlaying: false)
            cancelHideControlsTimer()
        } else {
            player.play()
            updatePlayPauseButton(isPlaying: true)
            startHideControlsTimer()
        }
    }
    
    @objc func skipBack() {
        guard let player else { return }
        let newTime = CMTimeSubtract(player.currentTime(), CMTimeMakeWithSeconds(10, preferredTimescale: 1))
        player.seek(to: newTime)
    }
    
    @objc func skipForward() {
        guard let player else { return }
        let newTime = CMTimeAdd(player.currentTime(), CMTimeMakeWithSeconds(10, preferredTimescale: 1))
        player.seek(to: newTime)
    }
    
    // MARK: - Video Helpers
    private func startHideControlsTimer() {
        cancelHideControlsTimer()
        guard !videoControls.isHidden else { return }
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player?.timeControlStatus == .playing else { return }
                UIView.animate(withDuration: 0.3) {
                    self.navBar.alpha = 0
                    self.videoControls.alpha = 0
                    self.isNavBarHidden = true
                }
            }
        }
    }

    private func cancelHideControlsTimer() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
    }
    
    private func addTimeObserver(to player: AVPlayer) {
        // observe playback time
        let interval = CMTimeMakeWithSeconds(0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.updateScrubber(time: time, player: player)
                self.updateBufferIndicator(player: player)
                self.updateSpinner(player: player)
            }
        }

        // observe buffering status
        statusObservation = player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.updateSpinner(player: player)
            }
        }

        // update total time label as soon as the item's duration becomes known
        durationObservation = player.currentItem?.observe(\.duration) { @Sendable [weak self] item, _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                let duration = item.duration
                guard duration.isValid, !duration.isIndefinite else { return }
                self.totalTimeLabel.text = self.formatTime(CMTimeGetSeconds(duration))
                self.updateScrubber(time: player.currentTime(), player: player)
            }
        }
    }

    private func removeTimeObserver(from player: AVPlayer) {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
    }

    private func updateScrubber(time: CMTime, player: AVPlayer) {
        guard let duration = player.currentItem?.duration,
              duration.isValid, !duration.isIndefinite else { return }
        let current = CMTimeGetSeconds(time)
        let total = CMTimeGetSeconds(duration)
        scrubber.value = Float(current / total)
        currentTimeLabel.text = formatTime(current)
        totalTimeLabel.text = formatTime(total)
    }

    private func updateBufferIndicator(player: AVPlayer) {
        guard let item = player.currentItem,
              let duration = item.duration.isValid ? item.duration : nil,
              !duration.isIndefinite else { return }
        let total = CMTimeGetSeconds(duration)
        guard total > 0 else { return }
        let buffered = item.loadedTimeRanges.compactMap { $0.timeRangeValue }
            .filter { CMTimeRangeContainsTime($0, time: player.currentTime()) }
            .map { CMTimeGetSeconds($0.end) }
            .max() ?? 0
        let bufferFraction = CGFloat(min(buffered / total, 1.0))
        let scrubberWidth = scrubber.bounds.width
        UIView.animate(withDuration: 0.3) {
            self.bufferWidthConstraint?.constant = scrubberWidth * bufferFraction
            self.view.layoutIfNeeded()
        }
    }

    private func updateSpinner(player: AVPlayer) {
        let isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if isBuffering {
            spinner.startAnimating()
            playPauseButton.isHidden = true
        } else {
            spinner.stopAnimating()
            playPauseButton.isHidden = false
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN, !seconds.isInfinite else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    // MARK: - Scrubber actions
    @objc private func scrubberTouchBegan() {
        isScrubbing = true
        cancelHideControlsTimer()
    }

    @objc private func scrubberValueChanged() {
        guard let player,
              let duration = player.currentItem?.duration,
              duration.isValid, !duration.isIndefinite else { return }
        let total = CMTimeGetSeconds(duration)
        let newTime = Double(scrubber.value) * total
        currentTimeLabel.text = formatTime(newTime)
    }

    @objc private func scrubberTouchEnded() {
        guard let player,
              let duration = player.currentItem?.duration,
              duration.isValid, !duration.isIndefinite else {
            isScrubbing = false
            return
        }
        let total = CMTimeGetSeconds(duration)
        let newTime = Double(scrubber.value) * total
        player.seek(to: CMTimeMakeWithSeconds(newTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isScrubbing = false
                self?.startHideControlsTimer()
            }
        }
    }
}

// MARK: - UIPageViewControllerDataSource
extension FileViewerViewController: UIPageViewControllerDataSource {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard currentIndex > 0 else { return nil }
        return FilePageViewController(item: items[currentIndex - 1], viewer: self)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard currentIndex < items.count - 1 else { return nil }
        return FilePageViewController(item: items[currentIndex + 1], viewer: self)
    }
}

// MARK: - UIViewControllerDelegate
extension FileViewerViewController: UIPageViewControllerDelegate {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed,
              let current = pageViewController.viewControllers?.first as? FilePageViewController else { return }
        currentIndex = items.firstIndex(where: { $0.id == current.item.id }) ?? currentIndex
        updateUI(for: items[currentIndex])
    }
}
