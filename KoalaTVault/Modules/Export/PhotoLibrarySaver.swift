import Foundation
import Photos

/// The photo library operations a save needs, so tests can run without the real library.
protocol PhotoLibraryAdding: Sendable {
    /// Asks for add-only access; true when it is granted.
    func requestAddOnlyAccess() async -> Bool
    /// Adds the image or video file at `url` to the library.
    func saveMedia(at url: URL, isVideo: Bool) async throws
}

/// The real photo library, using add-only access.
struct SystemPhotoLibraryAdder: PhotoLibraryAdding {
    // coverage-exempt-begin: needs the real photo library and the iOS permission prompt
    func requestAddOnlyAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
    }

    func saveMedia(at url: URL, isVideo: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            if isVideo {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
        }
    }
    // coverage-exempt-end
}

/// Saves the images and videos among vault items to the photo library, one at a time.
struct PhotoLibrarySaver: Sendable {
    private let store: any VaultStoring
    private let library: any PhotoLibraryAdding

    init(store: any VaultStoring, library: any PhotoLibraryAdding) {
        self.store = store
        self.library = library
    }

    /// Whether the item is an image or video file. A folder never is, whatever its name says.
    static func isSavable(_ item: VaultItem) -> Bool {
        !item.isDirectory && (item.kind == .image || item.kind == .video)
    }

    /// Saves the items' media and counts the outcome. A failure on one item is counted in `failed`
    /// and the rest still save. Access is only requested when there is media to save.
    /// - Throws: `ExportError.photoAccessDenied` without add-only access; `CancellationError` when the
    ///   task is cancelled or the library reports cancellation, which is never counted as a failure.
    @concurrent
    func save(_ items: [VaultItem]) async throws -> PhotoSaveResult {
        let media = items.filter(Self.isSavable)
        var result = PhotoSaveResult(saved: 0, failed: 0, skipped: items.count - media.count)
        guard !media.isEmpty else { return result }
        guard await library.requestAddOnlyAccess() else { throw ExportError.photoAccessDenied }

        for item in media {
            try Task.checkCancellation()
            do {
                try await saveOne(item)
                result.saved += 1
            } catch let error as CancellationError {
                throw error
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    private func saveOne(_ item: VaultItem) async throws {
        let opened = try await store.open(item)
        // `open` gives a plaintext item's own disk URL: only a separate copy's folder is a temp folder.
        defer {
            if opened.standardizedFileURL != item.diskURL.standardizedFileURL {
                store.removeTemporary(opened.deletingLastPathComponent())
            }
        }
        try await library.saveMedia(at: opened, isVideo: item.kind == .video)
    }
}
