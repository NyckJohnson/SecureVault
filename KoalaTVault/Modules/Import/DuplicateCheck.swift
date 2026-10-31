import CryptoKit
import Foundation

/// Decides whether a file about to be imported is already in the target folder.
struct DuplicateCheck: Sendable {
    private let store: any VaultStoring

    init(store: any VaultStoring) {
        self.store = store
    }

    /// True when `directory` holds a file called `name` with the same SHA-256 as `source`. An encrypted
    /// file is decrypted to a store temp folder to hash it, and that folder is removed afterwards.
    ///
    /// Throws the store's error if the folder can't be searched. A file that can't be read, on either
    /// side, can't be shown to match, so it gives false: the add that follows then reports an unreadable
    /// source, and an unreadable existing file is kept alongside the new one under a " 1" name.
    func isDuplicate(source: URL, named name: String, in directory: VaultDirectory) async throws -> Bool {
        guard let existing = try await store.findItem(named: name, in: directory), !existing.isDirectory,
            let existingURL = try? await store.open(existing)
        else {
            return false
        }
        defer { if existing.isEncrypted { store.removeTemporary(existingURL.deletingLastPathComponent()) } }
        guard let sourceHash = Self.sha256(ofFileAt: source),
            let existingHash = Self.sha256(ofFileAt: existingURL)
        else {
            return false
        }
        return sourceHash == existingHash
    }

    /// The file's hash, read a piece at a time so a large video stays out of memory; nil if it can't be read.
    private static func sha256(ofFileAt url: URL) -> SHA256.Digest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            var hasMore = true
            while hasMore {
                hasMore = try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { return false }
                    hasher.update(data: chunk)
                    return true
                }
            }
        } catch {
            return nil  // coverage-exempt: read failure after a successful open can't be simulated
        }
        return hasher.finalize()
    }
}
