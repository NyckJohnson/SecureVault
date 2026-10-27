import Foundation

// coverage-exempt-file: declarations only

/// Files ready to share, and how to remove the decrypted copies afterwards.
struct ExportBundle: Sendable {
    let urls: [URL]
    let cleanUp: @Sendable () -> Void
}

/// The outcome of saving to the photo library.
struct PhotoSaveResult: Sendable, Equatable {
    var saved: Int
    var failed: Int
    var skipped: Int
}

/// Errors thrown by an export.
enum ExportError: Error, Equatable, Sendable {
    case photoAccessDenied, nothingToExport
}

/// Decrypted copies for sharing, saved to Files or the photo library.
protocol VaultExporting: Sendable {
    /// URLs to share for the items (decrypted copies where encrypted).
    func prepareForSharing(_ items: [VaultItem]) async throws -> ExportBundle
    /// Saves the images and videos among the items to the photo library.
    func saveToPhotos(_ items: [VaultItem]) async throws -> PhotoSaveResult
    /// Whether any item is an image or a video.
    func canSaveToPhotos(_ items: [VaultItem]) -> Bool
}
