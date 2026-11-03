import AVFoundation
import Combine
import QuickLook
import UIKit

/// One page of the viewer: shows what its view model says the item is, and reports what only a view can find out
/// (an image or video that won't decode).
@MainActor
final class FilePageViewController: UIViewController {
    /// This page's position in the viewer's items.
    let index: Int

    private let viewModel: FilePageViewModel
    /// The viewer's one player. This page's item is on it only while the page is visible.
    private let player: AVPlayer
    private let openEditor: @MainActor (VaultItem) -> Void
    private var subscriptions: Set<AnyCancellable> = []
    private var itemStatus: AnyCancellable?
    private var playerLayer: AVPlayerLayer?
    private var playerItem: AVPlayerItem?
    /// Where the video was when the page left, so coming back continues from there, paused.
    private var resumeTime: CMTime?
    private var previewURL: URL?
    private var imageView: UIImageView?
    private var scrollView: UIScrollView?
    private var errorLabel: UILabel?
    private var isOnScreen = false

    /// - Parameter openEditor: opens the editor for this `.rtf` page's item. The viewer does it, because what
    ///   happens after the editor closes is a change of page.
    init(
        index: Int, viewModel: FilePageViewModel, player: AVPlayer,
        openEditor: @escaping @MainActor (VaultItem) -> Void
    ) {
        self.index = index
        self.viewModel = viewModel
        self.player = player
        self.openEditor = openEditor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "filePage.\(viewModel.item.name)"
        // On the main queue, not inside the publisher's will-set: `reportFailure` sets `content` again, and a
        // set made during the will-set would be overwritten when it finishes.
        viewModel.$content
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] content in self?.show(content) }
            .store(in: &subscriptions)
        viewModel.$playerAsset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] asset in self?.showVideo(asset) }
            .store(in: &subscriptions)
        // Strong on purpose: the load must finish even if the page goes, so its decrypted copy reaches the
        // viewer's model to be removed.
        Task { [viewModel] in await viewModel.load() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isOnScreen = true
        viewModel.setVisible(true)
        openEditorIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        viewModel.setVisible(false)
    }

    // MARK: - Content

    private func show(_ content: FilePageViewModel.Content) {
        switch content {
        case .loading:
            break
        case .image(let url):
            guard let image = UIImage(contentsOfFile: url.path) else {
                viewModel.reportFailure()
                return
            }
            installImageView(image)
        case .video:
            view.accessibilityIdentifier = "filePage.\(viewModel.item.name).videoPlayer"
        case .editor:
            openEditorIfNeeded()
        case .document(let url):
            previewURL = url
            installQuickLook()
        case .failed(let message):
            playerLayer?.isHidden = true
            showError(message)
        }
    }

    /// Waits until the page is on screen: a preloaded neighbour mustn't open anything. The viewer ignores this
    /// while an editor is open, and takes this page off the pager when the editor closes, so it doesn't reopen.
    private func openEditorIfNeeded() {
        guard isOnScreen, viewModel.content == .editor else { return }
        openEditor(viewModel.item)
    }

    private func showError(_ message: String) {
        guard errorLabel == nil else { return }
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "filePage.\(viewModel.item.name).errorLabel"
        view.addSubview(label)
        var constraints: [NSLayoutConstraint] = []
        constraints.append(label.centerXAnchor.constraint(equalTo: view.centerXAnchor))
        constraints.append(label.centerYAnchor.constraint(equalTo: view.centerYAnchor))
        constraints.append(label.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor))
        constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor))
        NSLayoutConstraint.activate(constraints)
        errorLabel = label
    }

    // MARK: - Video

    private func showVideo(_ asset: AVURLAsset?) {
        if let asset {
            takePlayer(with: asset)
        } else {
            releasePlayer()
        }
    }

    private func takePlayer(with asset: AVURLAsset) {
        let item = AVPlayerItem(asset: asset)
        // A file that can't be decoded (or decrypted while streaming) fails asynchronously.
        itemStatus = item.publisher(for: \.status)
            .filter { $0 == .failed }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.viewModel.reportFailure() }
        playerItem = item
        // The player keeps its rate across items, and the page before may not have let go yet.
        player.pause()
        player.replaceCurrentItem(with: item)
        // Exact: by default a seek may land on a keyframe, which in a short video can be the start.
        // Only a real time: the player can report an invalid one, and seeking to that raises an exception.
        if let resumeTime, resumeTime.isValid, resumeTime.isNumeric {
            player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        let layer = playerLayer ?? AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        layer.player = player
        if playerLayer == nil { view.layer.addSublayer(layer) }
        playerLayer = layer
    }

    /// Lets go only of this page's own item: the next page may already have put its item on the player, since
    /// UIKit doesn't promise the old page disappears before the new one appears.
    private func releasePlayer() {
        guard let playerItem else { return }
        if player.currentItem === playerItem {
            resumeTime = player.currentTime()
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        self.playerItem = nil
        itemStatus = nil
        playerLayer?.player = nil
    }

    // MARK: - Image

    private func installImageView(_ image: UIImage) {
        let scrollView = UIScrollView()
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.accessibilityIdentifier = "filePage.\(viewModel.item.name).scrollView"
        view.addSubview(scrollView)

        var constraints: [NSLayoutConstraint] = []
        constraints.append(scrollView.topAnchor.constraint(equalTo: view.topAnchor))
        constraints.append(scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor))
        constraints.append(scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor))
        constraints.append(scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor))
        NSLayoutConstraint.activate(constraints)

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        imageView.frame = view.bounds
        imageView.accessibilityIdentifier = "filePage.\(viewModel.item.name).imageView"

        scrollView.addSubview(imageView)
        scrollView.contentSize = view.bounds.size
        self.imageView = imageView
        self.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let scrollView else { return }
        if scrollView.zoomScale > 1.0 {
            scrollView.setZoomScale(1.0, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 3, height: scrollView.bounds.height / 3)
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    // MARK: - QuickLook

    private func installQuickLook() {
        let preview = QLPreviewController()
        preview.dataSource = self
        addChild(preview)
        view.addSubview(preview.view)
        preview.view.frame = view.bounds
        preview.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        preview.view.accessibilityIdentifier = "filePage.\(viewModel.item.name).quickLook"
        preview.didMove(toParent: self)
        preview.reloadData()
    }
}

// MARK: - QLPreviewControllerDataSource

extension FilePageViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? viewModel.item.diskURL) as QLPreviewItem
    }
}

// MARK: - UIScrollViewDelegate

extension FilePageViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard let imageView else { return }
        let boundsSize = scrollView.bounds.size
        var frameToCenter = imageView.frame
        frameToCenter.origin.x =
            frameToCenter.width < boundsSize.width
            ? (boundsSize.width - frameToCenter.width) / 2 : 0
        frameToCenter.origin.y =
            frameToCenter.height < boundsSize.height
            ? (boundsSize.height - frameToCenter.height) / 2 : 0
        imageView.frame = frameToCenter
    }
}
