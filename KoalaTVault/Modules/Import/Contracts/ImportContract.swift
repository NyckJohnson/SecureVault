import Foundation

// coverage-exempt-file: declarations only

/// The outcome of a file or folder import.
struct ImportResult: Sendable, Equatable {
    var imported: Int
    var skippedDuplicates: Int
    var failed: Int
}

/// The outcome of a photo import.
struct PhotoImportResult: Sendable, Equatable {
    var importedAssetIDs: [String]
    var failed: Int
}

/// Errors thrown by an import.
enum ImportError: Error, Equatable, Sendable {
    case fileLimitReached(limit: Int), unreadableSource(String)
}

/// Brings files, folders and photos into the vault.
protocol VaultImporting: Sendable {
    /// Throws `.fileLimitReached` when adding `count` files would pass the free limit.
    func checkAllowed(adding count: Int) async throws
    /// Imports files and folders into `directory`, reporting progress from 0 to 1.
    func importItems(
        _ urls: [URL],
        into directory: VaultDirectory,
        progress: @Sendable (Double) -> Void
    ) async throws -> ImportResult
    /// Imports picked photos and videos into `directory`.
    func importPhotos(_ assets: [PhotoImportSource], into directory: VaultDirectory) async throws -> PhotoImportResult
}

/// One picked photo or video: its asset identifier (nil without library access) and a loader for its file.
struct PhotoImportSource: Sendable {
    /// The photo library asset identifier, if known.
    let assetID: String?
    /// The name to store the file under.
    let suggestedName: String
    /// Loads the asset's file into a temporary URL.
    let loadFile: @Sendable () async throws -> URL
}

/// Deletes imported originals from the photo library.
protocol CameraRollDeleting: Sendable {
    /// Asks the photo library to delete the assets (iOS shows its own confirmation).
    func deleteAssets(withIdentifiers ids: [String]) async
}
