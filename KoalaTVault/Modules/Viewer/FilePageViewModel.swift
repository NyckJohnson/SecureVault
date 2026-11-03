import AVFoundation
import Combine
import Foundation

/// The logic of one viewer page: what the item shows as, opening it, and the shared video player.
@MainActor
final class FilePageViewModel: ObservableObject {
    /// What the page shows.
    enum Content: Equatable {
        case loading
        /// A zoomable image of the opened file.
        case image(URL)
        /// The video; `playerAsset` holds the asset while the page is visible.
        case video
        /// The rich-text editor, which opens the file itself.
        case editor
        /// A QuickLook preview of the opened file.
        case document(URL)
        case failed(String)
    }

    private static let failureMessage = "This file can't be opened."

    let item: VaultItem

    @Published private(set) var content: Content = .loading
    /// The asset for the shared player; set only while this page is a visible video.
    @Published private(set) var playerAsset: AVURLAsset?

    private let store: any VaultStoring
    private let videoAssets: any VideoAssetProviding
    private let onTemporaryFile: @MainActor (URL) -> Void
    private var isVisible = false
    private var didStartLoading = false

    /// - Parameter onTemporaryFile: told the URL of each decrypted copy this page opens, for the viewer to
    ///   remove on close. Never told a plaintext vault file's own URL.
    init(
        item: VaultItem, store: any VaultStoring, videoAssets: any VideoAssetProviding,
        onTemporaryFile: @escaping @MainActor (URL) -> Void
    ) {
        self.item = item
        self.store = store
        self.videoAssets = videoAssets
        self.onTemporaryFile = onTemporaryFile
    }

    /// Routes the item by kind and, for images and documents, opens it.
    func load() async {
        guard !didStartLoading else { return }
        didStartLoading = true
        switch item.kind {
        case .image:
            await open(as: Content.image)
        case .video:
            content = .video
            updatePlayer()
        default:
            if (item.name as NSString).pathExtension.lowercased() == "rtf" {
                content = .editor
            } else {
                await open(as: Content.document)
            }
        }
    }

    /// Only the visible page drives the shared player: a preloaded neighbour never takes it, and a page
    /// that stops being visible lets go of it.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        updatePlayer()
    }

    /// The view couldn't decode the opened image or video: shows the failure and lets go of the player.
    /// Safe to call repeatedly; a later `load()` starts over and can replace the failure.
    func reportFailure() {
        content = .failed(Self.failureMessage)
        playerAsset = nil
        didStartLoading = false
    }

    private func open(as makeContent: (URL) -> Content) async {
        let item = item
        let store = store
        // Detached because decrypting is slow: this project's `nonisolated async` functions run on the
        // caller's actor (approachable concurrency), so a plain `await store.open` could stay on the main thread.
        let opened = await Task.detached { try await store.open(item) }.result
        switch opened {
        case .success(let url):
            if item.isEncrypted { onTemporaryFile(url) }
            content = makeContent(url)
        case .failure:
            content = .failed(Self.failureMessage)
        }
    }

    private func updatePlayer() {
        guard isVisible, content == .video else {
            playerAsset = nil
            return
        }
        guard playerAsset == nil else { return }
        do {
            playerAsset = try videoAssets.asset(for: item)
        } catch {
            content = .failed(Self.failureMessage)
        }
    }
}
