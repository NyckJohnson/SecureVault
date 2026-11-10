import Foundation

/// One entry of a folder's `.vault_map`: the original name of an encrypted `<UUID>` file.
///
/// Encodes as `{ "originalName": "…" }`, the shape earlier app versions wrote.
struct VaultIndexEntry: Codable, Sendable, Equatable {
    let originalName: String
}

/// How one store operation treats the vault, decided once at its start.
struct VaultOperationMode: Sendable {
    /// `lockMode != .none`: new content and indexes are written encrypted.
    let isEncrypted: Bool
    /// Whether a master key was loaded when the operation started.
    let keyLoaded: Bool
}

/// Reads and writes the per-folder `.vault_map` index (UUID disk name → original name).
///
/// Reads accept, in order: plaintext JSON (written by older builds or in plaintext mode), then, when a key
/// is loaded, ciphertext sealed with ".vault_map", the folder's root-relative path, the legacy
/// "<folder>/.vault_map" path, or "". An index that exists but reads in none of these ways is
/// `.indexUnreadable` and callers must never overwrite it.
struct VaultIndex: Sendable {
    /// The index file's name in every folder.
    static let fileName = ".vault_map"

    let cipher: any FileCipher
    /// The vault root, for the folder-relative decryption contexts and error labels.
    let rootURL: URL
    /// The label used for the root folder in `.indexUnreadable`.
    let rootName: String

    /// The index of `folder`: empty when absent.
    /// - Throws: `.indexUnreadable(folder:)` when it exists but can't be read or decoded; `.locked` when
    ///   the key disappeared while an encrypted-mode operation was decrypting it.
    func read(in folder: URL, mode: VaultOperationMode) throws -> [String: VaultIndexEntry] {
        let url = folder.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try Self.readSealedJSON(
            [String: VaultIndexEntry].self, at: url, contexts: contexts(for: folder), cipher: cipher, mode: mode,
            unreadable: .indexUnreadable(folder: label(for: folder)))
    }

    /// Writes `entries` as the index of `folder`: encrypted (context ".vault_map") in encrypted mode,
    /// plaintext JSON otherwise. In plaintext mode an empty index is not created where none exists.
    /// - Throws: `.locked` when the key is gone in encrypted mode (nothing is written), `.io` otherwise.
    func write(_ entries: [String: VaultIndexEntry], in folder: URL, mode: VaultOperationMode) throws {
        let url = folder.appendingPathComponent(Self.fileName)
        if entries.isEmpty, !mode.isEncrypted, !FileManager.default.fileExists(atPath: url.path) { return }
        try Self.writeSealedJSON(entries, to: url, context: Self.fileName, cipher: cipher, mode: mode)
    }

    /// Decodes the JSON file at `url`: plaintext JSON first (older builds, plaintext mode), then, with a key
    /// loaded, ciphertext sealed with the first of `contexts` that opens it.
    /// - Throws: `unreadable` when the file can't be read, opened or decoded; `.locked` in encrypted mode when
    ///   there is no key (or it disappeared while decrypting).
    static func readSealedJSON<T: Decodable>(
        _ type: T.Type, at url: URL, contexts: [String], cipher: any FileCipher, mode: VaultOperationMode,
        unreadable: VaultStoreError
    ) throws -> T {
        guard let data = try? Data(contentsOf: url) else { throw unreadable }
        if let plaintext = try? JSONDecoder().decode(T.self, from: data) { return plaintext }
        guard mode.keyLoaded else { throw mode.isEncrypted ? VaultStoreError.locked : unreadable }
        let decrypted: Data
        do {
            decrypted = try cipher.decrypt(data, contexts: contexts)
        } catch VaultCryptoError.noKeyLoaded where mode.isEncrypted {
            throw VaultStoreError.locked
        } catch {
            throw unreadable
        }
        guard let value = try? JSONDecoder().decode(T.self, from: decrypted) else { throw unreadable }
        return value
    }

    /// Writes `value` as JSON to `url` (atomic, complete file protection): sealed with `context` in encrypted
    /// mode, plaintext otherwise. Never falls back to plaintext in encrypted mode.
    /// - Throws: `.locked` when the key is gone in encrypted mode (nothing is written), `.io` otherwise.
    static func writeSealedJSON<T: Encodable>(
        _ value: T, to url: URL, context: String, cipher: any FileCipher, mode: VaultOperationMode
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json: Data
        do {
            json = try encoder.encode(value)
        } catch {
            // coverage-exempt-begin: JSONEncoder can't fail for these plain Codable types
            throw VaultStoreError.io(error.localizedDescription)
            // coverage-exempt-end
        }
        let data: Data
        if mode.isEncrypted {
            do {
                data = try cipher.encrypt(json, context: context)
            } catch {
                throw VaultStoreError.from(error)
            }
        } else {
            data = json
        }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw VaultStoreError.io(error.localizedDescription)
        }
    }

    /// The folder's path relative to the vault root ("" for the root itself).
    func relativePath(of folder: URL) -> String {
        Self.relativePath(of: folder, root: rootURL)
    }

    /// The path of `url` relative to `root` ("" for the root, the last component when outside it).
    static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == rootPath { return "" }
        if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count + 1)) }
        // coverage-exempt-begin: defensive; folders always come from the vault root
        return url.lastPathComponent
        // coverage-exempt-end
    }

    private func label(for folder: URL) -> String {
        let relative = relativePath(of: folder)
        return relative.isEmpty ? rootName : relative
    }

    /// Decryption contexts in the order the spec gives: ".vault_map", the folder-relative path
    /// (also in the legacy "<folder>/.vault_map" form), then "".
    private func contexts(for folder: URL) -> [String] {
        let relative = relativePath(of: folder)
        var contexts = [Self.fileName]
        if !relative.isEmpty {
            contexts.append(relative)
            contexts.append(relative + "/" + Self.fileName)
        }
        contexts.append("")
        return contexts
    }
}

extension VaultStoreError {
    /// Maps any error from the crypto layer or the file system to a store error.
    /// `VaultCryptoError.noKeyLoaded` becomes `.locked`; missing files become `.notFound`.
    static func from(_ error: any Error) -> VaultStoreError {
        if let storeError = error as? VaultStoreError { return storeError }
        if let cryptoError = error as? VaultCryptoError {
            return cryptoError == .noKeyLoaded ? .locked : .io(cryptoError.localizedDescription)
        }
        let nsError = error as NSError
        let missingCodes = [NSFileNoSuchFileError, NSFileReadNoSuchFileError]
        if nsError.domain == NSCocoaErrorDomain, missingCodes.contains(nsError.code) { return .notFound }
        return .io(nsError.localizedDescription)
    }
}
