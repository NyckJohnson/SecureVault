import Foundation

/// Temporary files: decrypted copies for `open`, staged plaintext for `write`, export copies.
///
/// Every temporary folder lives in one folder the store owns, `<temporaryRoot>/VaultStore`, so
/// `removeAllTemporaryFiles` removes exactly what the store created and nothing else in the app's temp folder.
extension LiveVaultStore {
    /// The name of the store's own folder under `temporaryRoot`.
    private static let temporaryFolderName = "VaultStore"

    /// The folder every temporary folder of this store is created in.
    nonisolated var storeTemporaryFolder: URL {
        temporaryRoot.appendingPathComponent(Self.temporaryFolderName, isDirectory: true)
    }

    nonisolated func makeTempDirectory() throws -> URL {
        let url = storeTemporaryFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            // Complete protection on the folder: files created in it, such as the plaintext the cipher
            // decrypts for `open`, inherit it.
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        } catch {
            throw VaultStoreError.from(error)
        }
        return url
    }

    /// Removes `url` and everything in it. Only URLs inside the store's temporary folder are removed, so a
    /// vault file (such as the disk URL `open` returns for a plaintext item) is never deleted by mistake.
    /// A missing URL is not an error.
    nonisolated func removeTemporary(_ url: URL) {
        let folderPath = Self.standardPath(storeTemporaryFolder)
        guard Self.standardPath(url).hasPrefix(folderPath + "/") else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Best-effort by contract (non-throwing): a file that can't be removed now is removed by the next
        // `removeAllTemporaryFiles`.
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the store's temporary folder with everything in it; the next `makeTempDirectory` recreates it.
    nonisolated func removeAllTemporaryFiles() {
        guard FileManager.default.fileExists(atPath: storeTemporaryFolder.path) else { return }
        // Best-effort by contract (non-throwing); the system also clears the temp folder eventually.
        try? FileManager.default.removeItem(at: storeTemporaryFolder)
    }
}
