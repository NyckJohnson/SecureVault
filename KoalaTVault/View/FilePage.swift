//
//  LegacyFilePageViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/12/26.
//

import UIKit
import AVKit
import QuickLook

final class LegacyFilePageViewController: UIViewController {
    let item: VaultItem
    private let vaultStore: any VaultStoring
    private let videoAssets: any VideoAssetProviding
    private weak var viewer: LegacyFileViewerViewController?
    private var playerLayer: AVPlayerLayer?
    /// This page's own player. The pager loads neighbour pages before they show, so the page hands it to the
    /// viewer's controls only when it appears (`viewDidAppear`) and pauses it when it leaves.
    private var player: AVPlayer?
    private var previewURL: URL?
    private var imageView: UIImageView?
    private var scrollView: UIScrollView?
    private var playerItemStatusObservation: NSKeyValueObservation?  // invalidated when released
    private var errorLabel: UILabel?
    
    /// - Parameters:
    ///   - vaultStore: the app's vault store, which opens (decrypts) the item.
    ///   - videoAssets: the app's one video loader, which streams encrypted videos.
    init(
        item: VaultItem, viewer: LegacyFileViewerViewController, vaultStore: any VaultStoring,
        videoAssets: any VideoAssetProviding
    ) {
        self.item = item
        self.viewer = viewer
        self.vaultStore = vaultStore
        self.videoAssets = videoAssets
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "filePage.\(item.name)"
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch item.kind {
        case .image:
            setupImageView()
        case .video:
            setupVideoPlayer()
        default:
            if ext == "rtf" {
                openInTextEditor()
            } else {
                setupQuickLook()
            }
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = view.bounds
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The visible page drives the viewer's controls (nil for non-video pages releases the last video).
        guard let viewer, viewer.player !== player else { return }
        viewer.player = player
        viewer.updatePlayPauseButton(isPlaying: player?.timeControlStatus == .playing)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player?.pause()
        if let viewer, viewer.player === player { viewer.updatePlayPauseButton(isPlaying: false) }
    }
    
    /// Shows "This file can't be opened." centred on the page (any load or decrypt failure).
    private func showErrorLabel() {
        guard errorLabel == nil else { return }
        let label = UILabel()
            label.text          = "This file can't be opened."
            label.textColor     = .white
            label.textAlignment = .center
            label.numberOfLines = 0
            label.font          = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.translatesAutoresizingMaskIntoConstraints = false
            label.accessibilityIdentifier = "filePage.\(item.name).errorLabel"
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor)
        ])
        errorLabel = label
    }
    
    /// The item's plaintext URL from the store (decrypted off the main actor), or nil on any failure.
    private func openItem() async -> URL? {
        try? await vaultStore.open(item)
    }

    private func setupImageView() {
        Task {
            guard let url = await openItem(),
                  let image = UIImage(contentsOfFile: url.path) else {
                showErrorLabel()
                return
            }
            installImageView(image)
        }
    }

    private func installImageView(_ image: UIImage) {
        let scrollView = UIScrollView()
            scrollView.delegate         = self
            scrollView.minimumZoomScale = 1.0
            scrollView.maximumZoomScale = 5.0
            scrollView.showsVerticalScrollIndicator   = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.accessibilityIdentifier = "filePage.\(item.name).scrollView"
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.image       = image
            imageView.frame       = view.bounds
            imageView.accessibilityIdentifier = "filePage.\(item.name).imageView"
        
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
    
    private func setupVideoPlayer() {
        guard item.isEncrypted else {
            playOpenedItem()
            return
        }
        // Encrypted: stream through the Media loader. The asset keeps the loader set as its resource
        // loader's delegate; the loader itself lives for the app's lifetime (built once in AppDependencies).
        let asset: AVURLAsset
        do {
            asset = try videoAssets.asset(for: item)
        } catch {
            // Streaming setup failed (invalid header, locked vault): play a decrypted copy instead.
            playOpenedItem()
            return
        }
        installVideoPlayer(url: nil, asset: asset)
    }

    /// Opens (decrypts if needed) the item through the vault store and plays the result.
    private func playOpenedItem() {
        Task {
            guard let url = await openItem() else {
                showErrorLabel()
                return
            }
            installVideoPlayer(url: url)
        }
    }

    private func installVideoPlayer(url: URL?, asset: AVURLAsset? = nil) {
        let playerItem: AVPlayerItem
        if let asset {
            playerItem = AVPlayerItem(asset: asset)
        } else if let url {
            playerItem = AVPlayerItem(url: url)
        } else {
            showErrorLabel()
            return
        }
        // A file that can't be decoded (or decrypted while streaming) fails asynchronously.
        playerItemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { [weak self] in
                self?.playerLayer?.isHidden = true
                self?.showErrorLabel()
            }
        }
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        playerLayer = layer
        view.accessibilityIdentifier = "filePage.\(item.name).videoPlayer"
    }
    
    private func openInTextEditor() {
        let editor = LegacyTextEditorViewController(item: item, vaultStore: vaultStore)
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    
    private func setupQuickLook() {
        Task {
            previewURL = await openItem()
            guard previewURL != nil else {
                showErrorLabel()
                return
            }
            installQuickLook()
        }
    }

    private func installQuickLook() {
        let qlController = QLPreviewController()
        qlController.dataSource = self
        addChild(qlController)
        view.addSubview(qlController.view)
        qlController.view.frame = view.bounds
        qlController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        qlController.view.accessibilityIdentifier = "filePage.\(item.name).quickLook"
        qlController.didMove(toParent: self)
        qlController.reloadData()
    }
}

// MARK: - QLPreviewControlleDataSource
extension LegacyFilePageViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? item.diskURL) as QLPreviewItem
    }
}

extension LegacyFilePageViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard let imageView else { return }
        let boundsSize = scrollView.bounds.size
        var frameToCenter = imageView.frame
        frameToCenter.origin.x = frameToCenter.width < boundsSize.width
            ? (boundsSize.width - frameToCenter.width) / 2 : 0
        frameToCenter.origin.y = frameToCenter.height < boundsSize.height
            ? (boundsSize.height - frameToCenter.height) / 2 : 0
        imageView.frame = frameToCenter
    }
}
