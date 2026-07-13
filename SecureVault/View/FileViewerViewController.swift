//
//  FileViewerViewController.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 5/11/26.
//

import UIKit
import AVKit

final class FileViewerViewController: UIViewController {
    private let items:              [FileItem]
    private var currentIndex:       Int
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
    var player: AVPlayer?
    
    init(items: [FileItem], startingAt index: Int) {
        self.items = items
        self.currentIndex = index
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    //MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPageViewController()
        setupNavBar()
        setupVideoControls()
        updateUI(for: items[currentIndex])
    }
    
    override var prefersStatusBarHidden: Bool { true }
    
    //MARK: - Page View Controller
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
    
    //MARK: - Nav Bar
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
            navBar.topAnchor.constraint(equalTo: view.topAnchor),
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
            exportButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }
    
    private func setupVideoControls() {
        videoControls.backgroundColor = UIColor.black.withAlphaComponent(0.5)
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

        videoControls.addSubview(skipBackButton)
        videoControls.addSubview(playPauseButton)
        videoControls.addSubview(skipForwardButton)
        
        NSLayoutConstraint.activate([
            videoControls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoControls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoControls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoControls.heightAnchor.constraint(equalToConstant: 80),

            playPauseButton.centerXAnchor.constraint(equalTo: videoControls.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: videoControls.centerYAnchor),

            skipBackButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -40),
            skipBackButton.centerYAnchor.constraint(equalTo: videoControls.centerYAnchor),

            skipForwardButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 40),
            skipForwardButton.centerYAnchor.constraint(equalTo: videoControls.centerYAnchor),
        ])
    }
    
    @objc private func toggleNavBar() {
        isNavBarHidden.toggle()
        UIView.animate(withDuration: 0.3) {
            self.navBar.alpha = self.isNavBarHidden ? 0 : 1
            self.videoControls.alpha = self.isNavBarHidden ? 0 : 1
        }
    }
    
    // MARK: - UI Updates
    func updateUI(for item: FileItem) {
        titleLabel.text = item.name
        let isVideo = ["mp4", "mov", "m4v", "avi"].contains(item.url.pathExtension.lowercased())
        videoControls.isHidden = !isVideo
    }
    
    func updatePlayPauseButton(isPlaying: Bool) {
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        let name   = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: name, withConfiguration: config), for: .normal)
    }
    
    // mark: - Actions
    @objc private func close() {
        player?.pause()
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
        } else {
            player.play()
            updatePlayPauseButton(isPlaying: true)
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
}

// MARK: - UIPageViewControllerDataSource
extension FileViewerViewController: UIPageViewControllerDataSource {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard currentIndex > 0 else { return nil }
        return FilePageViewController(item: items[currentIndex - 1], viewer: self)
    }
    
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard currentIndex < items.count - 1 else { return nil }
        return FilePageViewController(item: items[currentIndex + 1], viewer: self)
    }
}

// MARK: - UIViewControllerDelegate
extension FileViewerViewController: UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed,
              let current = pageViewController.viewControllers?.first as? FilePageViewController else { return }
        currentIndex = items.firstIndex(where: { $0.id == current.item.id }) ?? currentIndex
        updateUI(for: items[currentIndex])
    }
}
