@preconcurrency import Photos
import os

/// The live photo library.
struct PhotoLibraryAccess: CameraRollDeleting {
    private static let logger = Logger(subsystem: "com.KoalaTVault", category: "Import")

    func deleteAssets(withIdentifiers ids: [String]) async {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.firstObject != nil else { return }
        // coverage-exempt-begin: needs the real photo library and iOS's delete confirmation
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch {
            // Declining iOS's confirmation lands here too; the protocol has no way to report it and the
            // originals simply stay in the library.
            Self.logger.info("Camera-roll delete did not complete: \(error.localizedDescription)")
        }
        // coverage-exempt-end
    }
}
