//
//  FilePageViewController.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 5/12/26.
//

import UIKit
import AVKit
import QuickLook

final class FilePageViewController: UIViewController {
    let item: VaultItem
    private weak var viewer: FileViewerViewController?
    private var playerLayer: AVPlayerLayer?
    private var previewURL: URL?
    private var imageView:   UIImageView?
    private var scrollView:  UIScrollView?
    private var resourceLoaderDelegate: VaultResourceLoaderDelegate?
    
    init(item: VaultItem, viewer: FileViewerViewController) {
        self.item = item
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch FileKind(extension: ext) {
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
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        viewer?.player?.pause()
    }
    
    private func setupImageView() {
        guard let url = try? FileSystem.shared.open(item) else { return }
        let scrollView = UIScrollView()
            scrollView.delegate         = self
            scrollView.minimumZoomScale = 1.0
            scrollView.maximumZoomScale = 5.0
            scrollView.showsVerticalScrollIndicator   = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        
        let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.image       = UIImage(contentsOfFile: url.path)
            imageView.frame       = view.bounds
        
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
        let ext = (item.name as NSString).pathExtension.lowercased()

        guard item.isEncrypted,
              let delegate = VaultResourceLoaderDelegate(encryptedURL: item.diskURL, fileExtension: ext) else {
            // Not encrypted (or streaming setup failed) — play directly.
            guard let url = try? FileSystem.shared.open(item) else { return }
            installVideoPlayer(url: url)
            return
        }

        resourceLoaderDelegate = delegate
        var comps = URLComponents(url: item.diskURL, resolvingAgainstBaseURL: false)!
        comps.scheme = "vault-stream"
        let asset = AVURLAsset(url: comps.url!)
        asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue(label: "com.securevault.resourceloader"))
        installVideoPlayer(url: nil, asset: asset)
    }

    private func installVideoPlayer(url: URL?, asset: AVURLAsset? = nil) {
        let playerItem: AVPlayerItem
        if let asset {
            playerItem = AVPlayerItem(asset: asset)
        } else if let url {
            playerItem = AVPlayerItem(url: url)
        } else {
            return
        }
        let player = AVPlayer(playerItem: playerItem)
        viewer?.player = player
        viewer?.updatePlayPauseButton(isPlaying: false)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        playerLayer = layer
    }
    
    private func openInTextEditor() {
        let editor = TextEditorViewController(item: item)
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    
    private func setupQuickLook() {
        previewURL = try? FileSystem.shared.open(item)
        let qlController = QLPreviewController()
        qlController.dataSource = self
        addChild(qlController)
        view.addSubview(qlController.view)
        qlController.view.frame = view.bounds
        qlController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        qlController.didMove(toParent: self)
        qlController.reloadData()
    }
}

// MARK: - QLPreviewControlleDataSource
extension FilePageViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? item.diskURL) as QLPreviewItem
    }
}

extension FilePageViewController: UIScrollViewDelegate {
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
