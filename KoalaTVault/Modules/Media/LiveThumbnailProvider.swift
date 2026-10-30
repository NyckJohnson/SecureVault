import AVFoundation
import UIKit
import os

/// The drawing and media work behind thumbnails, kept apart from the provider's caching,
/// decrypt limit and cancellation so those can be tested without QuickLook or AVFoundation.
protocol ThumbnailRendering: Sendable {
    /// QuickLook's thumbnail of the file at `url`, or nil when it can't make one.
    func quickLookThumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> UIImage?
    /// The asset's duration in seconds, or nil when it can't be read.
    func videoDuration(of asset: AVURLAsset) async -> TimeInterval?
    /// The frame at `time` seconds, fitted to `size` at `scale`, or nil when it can't be read.
    func videoFrame(of asset: AVURLAsset, at time: TimeInterval, size: CGSize, scale: CGFloat) async -> UIImage?
    /// The plain folder icon at `size`.
    func folderIcon(size: CGSize, scale: CGFloat) -> UIImage?
    /// `media` drawn inside `folderIcon`.
    func compose(_ media: UIImage, onto folderIcon: UIImage, size: CGSize, scale: CGFloat) -> UIImage?
}

/// Thumbnails for the browser grid.
///
/// - Plaintext files: QuickLook on the disk file.
/// - Encrypted videos: a frame at `frameTime(forDuration:)` read through the streaming asset from
///   `VideoAssetProviding`; no plaintext touches the disk.
/// - Other encrypted files: decrypted into a store temp folder, thumbnailed, and the folder removed.
///   At most `maxConcurrentDecrypts` of these run at once.
/// - Folders: the first image or video inside (by name) composed onto the folder icon, else the icon.
///
/// Any failure (locked vault, corrupt or truncated file, missing file, render failure) gives nil,
/// which the grid shows as the kind's icon; failures are not cached. Results are cached by item id.
final class LiveThumbnailProvider: ThumbnailProviding {
    private let store: any VaultStoring
    private let cipher: any FileCipher
    private let videoAssets: any VideoAssetProviding
    private let renderer: any ThumbnailRendering
    private let cache = ThumbnailCache()
    private let decryptSlots: DecryptSlots
    /// The running generation tasks per item id, so `cancel(_:)` can cancel them.
    private let running = OSAllocatedUnfairLock(initialState: [String: [UUID: Task<UIImage?, Never>]]())

    /// - Parameters:
    ///   - store: lists folders and provides the temp folders for decrypted copies.
    ///   - cipher: decrypts encrypted files and checks encrypted video headers.
    ///   - videoAssets: streaming assets for encrypted videos.
    ///   - renderer: QuickLook, video frames and folder icon drawing.
    ///   - maxConcurrentDecrypts: how many encrypted files may be decrypted at once (at least 1).
    init(
        store: any VaultStoring, cipher: any FileCipher, videoAssets: any VideoAssetProviding,
        renderer: any ThumbnailRendering, maxConcurrentDecrypts: Int = 2
    ) {
        self.store = store
        self.cipher = cipher
        self.videoAssets = videoAssets
        self.renderer = renderer
        decryptSlots = DecryptSlots(count: maxConcurrentDecrypts)
    }

    /// The time of the video frame used as a thumbnail: the smaller of 5 seconds and half the duration
    /// (0 for an unknown, invalid or zero duration).
    static func frameTime(forDuration duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(5, duration / 2)
    }

    func thumbnail(for item: VaultItem, size: CGSize, scale: CGFloat) async -> UIImage? {
        if let cached = cache.image(for: item.id) { return cached }
        let generation = cache.generation
        let token = UUID()
        // An unstructured task so `cancel(_:)` can cancel this request from outside.
        let task = Task { [self] in
            await generate(item, size: size, scale: scale, generation: generation)
        }
        running.withLock { $0[item.id, default: [:]][token] = task }
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        running.withLock { running in
            running[item.id]?[token] = nil
            if running[item.id]?.isEmpty == true { running[item.id] = nil }
        }
        return image
    }

    func cancel(_ item: VaultItem) {
        let tasks = running.withLock { Array(($0[item.id] ?? [:]).values) }
        for task in tasks { task.cancel() }
    }

    func clearCache() {
        cache.removeAll()
    }

    func clearCache(for item: VaultItem) {
        cache.remove(id: item.id)
    }

    // MARK: Generation

    /// Makes and caches the item's thumbnail; nil when cancelled or when none can be made.
    private func generate(_ item: VaultItem, size: CGSize, scale: CGFloat, generation: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let image =
            if item.isDirectory {
                await folderThumbnail(item, size: size, scale: scale, generation: generation)
            } else {
                await fileThumbnail(item, size: size, scale: scale)
            }
        guard let image, !Task.isCancelled else { return nil }
        cache.store(image, for: item.id, generation: generation)
        return image
    }

    private func fileThumbnail(_ item: VaultItem, size: CGSize, scale: CGFloat) async -> UIImage? {
        guard item.isEncrypted else {
            return await renderer.quickLookThumbnail(for: item.diskURL, size: size, scale: scale)
        }
        if item.kind == .video {
            return await encryptedVideoThumbnail(item, size: size, scale: scale)
        }
        return await decryptedThumbnail(item, size: size, scale: scale)
    }

    /// A frame of the streaming asset; nothing is written to disk.
    private func encryptedVideoThumbnail(_ item: VaultItem, size: CGSize, scale: CGFloat) async -> UIImage? {
        // Reading the header first turns a locked vault or a corrupt file into nil before any
        // AVFoundation work starts.
        guard (try? cipher.streamInfo(of: item.diskURL)) != nil,
            let asset = try? videoAssets.asset(for: item)
        else { return nil }
        let duration = await renderer.videoDuration(of: asset) ?? 0
        guard !Task.isCancelled else { return nil }
        return await renderer.videoFrame(
            of: asset, at: Self.frameTime(forDuration: duration), size: size, scale: scale)
    }

    /// Decrypts into a store temp folder, thumbnails the copy, and always removes the folder.
    /// The decrypt slot is held from before the decrypt until the folder is removed.
    private func decryptedThumbnail(_ item: VaultItem, size: CGSize, scale: CGFloat) async -> UIImage? {
        do {
            try await decryptSlots.acquire()
        } catch {
            return nil  // Cancelled while waiting: no work done.
        }
        defer { decryptSlots.release() }
        guard !Task.isCancelled, let folder = try? store.makeTempDirectory() else { return nil }
        defer { store.removeTemporary(folder) }
        let copy = folder.appendingPathComponent(Self.tempFileName(for: item), isDirectory: false)
        guard (try? cipher.decryptFile(at: item.diskURL, to: copy)) != nil, !Task.isCancelled else { return nil }
        return await renderer.quickLookThumbnail(for: copy, size: size, scale: scale)
    }

    /// The decrypted copy's name: the item's name (QuickLook needs its extension), never a path.
    private static func tempFileName(for item: VaultItem) -> String {
        let name = (item.name as NSString).lastPathComponent
        return name.isEmpty || name == "/" || name == "." || name == ".." ? "file" : name
    }

    // MARK: Folders

    /// The first image or video inside (sorted by name) composed onto the folder icon; the plain icon
    /// when there is none or its thumbnail fails. The media thumbnail runs in this task, so cancelling
    /// the folder cancels it.
    private func folderThumbnail(_ item: VaultItem, size: CGSize, scale: CGFloat, generation: Int) async -> UIImage? {
        var media: VaultItem?
        if let directory = item.asDirectory {
            let children = (try? await store.contents(of: directory, sortedBy: .name, .ascending)) ?? []
            media = children.first { !$0.isDirectory && ($0.kind == .image || $0.kind == .video) }
        }
        guard let icon = renderer.folderIcon(size: size, scale: scale) else { return nil }
        guard let media else { return icon }

        let mediaImage: UIImage?
        if let cached = cache.image(for: media.id) {
            mediaImage = cached
        } else {
            mediaImage = await fileThumbnail(media, size: size, scale: scale)
            if let mediaImage, !Task.isCancelled {
                cache.store(mediaImage, for: media.id, generation: generation)
            }
        }
        guard let mediaImage else { return icon }
        return renderer.compose(mediaImage, onto: icon, size: size, scale: scale) ?? icon
    }
}

/// A counting semaphore for async code: `acquire()` waits (first come, first served) for a free slot
/// and throws `CancellationError` if its task is cancelled while waiting; `release()` frees the slot.
private final class DecryptSlots: Sendable {
    private struct Waiter: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private enum AcquireOutcome: Sendable {
        case acquired, cancelled, parked
    }

    private struct State: Sendable {
        var available: Int
        var waiters: [Waiter] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(count: Int) {
        state = OSAllocatedUnfairLock(initialState: State(available: max(1, count)))
    }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { state -> AcquireOutcome in
                    // Checked under the lock: if the cancel handler ran first, the flag is already set.
                    if Task.isCancelled { return .cancelled }
                    if state.available > 0 {
                        state.available -= 1
                        return .acquired
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return .parked
                }
                switch outcome {
                case .acquired: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .parked: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Frees a slot, handing it straight to the longest waiter if there is one.
    func release() {
        let next = state.withLock { state -> Waiter? in
            guard !state.waiters.isEmpty else {
                state.available += 1
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.continuation.resume()
    }
}
