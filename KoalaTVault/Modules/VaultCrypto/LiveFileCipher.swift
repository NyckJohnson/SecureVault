import CryptoKit
import Foundation

/// The live cipher: AES-256-GCM for small data (indexes) and the SVC5 format for files, all with the
/// master key from the injected key store. Each operation captures the key once through `withKey`,
/// so a wipe during a long file operation doesn't change the key halfway.
///
/// Errors are always `VaultCryptoError`: `.noKeyLoaded` without a key; otherwise any failure while
/// encrypting (including file-system errors) is `.encryptionFailed` and any failure while reading or
/// decrypting is `.decryptionFailed`.
struct LiveFileCipher: FileCipher {
    private let keyStore: any MasterKeyStoring

    /// A cipher using the master key held by `keyStore`.
    init(keyStore: any MasterKeyStoring) {
        self.keyStore = keyStore
    }

    // MARK: Small data

    func encrypt(_ data: Data, context: String) throws -> Data {
        try keyStore.withKey { key in
            guard let combined = try? AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined else {
                throw VaultCryptoError.encryptionFailed // coverage-exempt: AES-GCM seal with a valid key and nonce does not fail
            }
            return combined
        }
    }

    func decrypt(_ data: Data, contexts: [String]) throws -> Data {
        try keyStore.withKey { key in
            for context in contexts {
                // A failure here only means "not this context"; the next one is tried.
                if let plaintext = try? SVC5Format.open(data, key: key, aad: Data(context.utf8)) {
                    return plaintext
                }
            }
            throw VaultCryptoError.decryptionFailed
        }
    }

    // MARK: Files

    func encryptFile(at source: URL, to destination: URL) throws {
        try keyStore.withKey { masterKey in
            try Self.mapErrors(to: .encryptionFailed) {
                let totalSize = try Self.fileSize(of: source)
                guard totalSize <= SVC5Format.maxTotalSize else { throw VaultCryptoError.encryptionFailed }
                let header = SVC5Format.Header(
                    chunkSize: SVC5Format.writeChunkSize, totalSize: totalSize, fileID: SVC5Format.randomFileID())
                let fileKey = SVC5Format.fileKey(master: masterKey, fileID: header.fileID)
                let staging = try StagingFile(for: destination)
                defer { staging.discard() }
                try Self.writeEncrypted(from: source, to: staging.file, header: header, key: fileKey)
                try staging.commit(to: destination)
            }
        }
    }

    func decryptFile(at source: URL, to destination: URL) throws {
        try keyStore.withKey { masterKey in
            try Self.mapErrors(to: .decryptionFailed) {
                let staging = try StagingFile(for: destination)
                defer { staging.discard() }
                try Self.writeDecrypted(from: source, to: staging.file, masterKey: masterKey)
                try staging.commit(to: destination)
            }
        }
    }

    func streamInfo(of url: URL) throws -> StreamInfo {
        try Self.mapErrors(to: .decryptionFailed) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try SVC5Format.Header(parsing: SVC5Format.read(SVC5Format.headerSize, from: handle))
            return StreamInfo(totalSize: header.totalSize, chunkSize: header.chunkSize)
        }
    }

    func decryptChunk(_ index: Int, of url: URL, info: StreamInfo) throws -> Data {
        try keyStore.withKey { masterKey in
            try Self.mapErrors(to: .decryptionFailed) {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let header = try SVC5Format.Header(parsing: SVC5Format.read(SVC5Format.headerSize, from: handle))
                // Stale sizes from the caller would compute a wrong offset; refuse them outright.
                guard header.chunkSize == info.chunkSize, header.totalSize == info.totalSize,
                    index >= 0, index < header.chunkCount
                else {
                    throw VaultCryptoError.decryptionFailed
                }
                try handle.seek(toOffset: UInt64(header.recordOffset(of: index)))
                guard let combined = try SVC5Format.readRecord(from: handle, header: header) else {
                    throw VaultCryptoError.decryptionFailed
                }
                let fileKey = SVC5Format.fileKey(master: masterKey, fileID: header.fileID)
                return try SVC5Format.open(combined, key: fileKey, aad: header.chunkAAD(index: index))
            }
        }
    }

    // MARK: Helpers

    /// Runs `body`, passing `VaultCryptoError`s through and turning any other error into `failure`.
    private static func mapErrors<T>(to failure: VaultCryptoError, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as VaultCryptoError {
            throw error
        } catch {
            throw failure
        }
    }

    private static func fileSize(of url: URL) throws -> Int {
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
            throw VaultCryptoError.encryptionFailed // coverage-exempt: attributesOfItem always yields an Int size for a regular file
        }
        return size
    }

    /// Writes the header and every chunk of `source` to `output`. The source must yield exactly
    /// `header.totalSize` bytes (the size is authenticated in every chunk), else `.encryptionFailed`.
    private static func writeEncrypted(
        from source: URL, to output: URL, header: SVC5Format.Header, key: SymmetricKey
    ) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        try writer.write(contentsOf: header.bytes)
        var bytesRead = 0
        var index = 0
        var moreChunks = true
        while moreChunks {
            moreChunks = try autoreleasepool { () throws -> Bool in
                let chunk = try SVC5Format.read(header.chunkSize, from: input)
                if chunk.isEmpty { return false }
                // Seeking readers need every chunk but the last to be full, so data after a short
                // chunk (or beyond the recorded size) means the source changed under us.
                guard bytesRead % header.chunkSize == 0, bytesRead + chunk.count <= header.totalSize else {
                    throw VaultCryptoError.encryptionFailed // coverage-exempt: needs the source file to grow mid-read, a race a unit test can't stage
                }
                try writer.write(contentsOf: SVC5Format.sealRecord(chunk, key: key, aad: header.chunkAAD(index: index)))
                bytesRead += chunk.count
                index += 1
                return true
            }
        }
        // A short read (the file shrank) leaves fewer bytes than the header promises.
        guard bytesRead == header.totalSize else { throw VaultCryptoError.encryptionFailed }
        try writer.synchronize()
    }

    /// Decrypts the SVC5 file at `source` into `output`, verifying every chunk, the record framing and
    /// the total size; any mismatch is `.decryptionFailed`.
    private static func writeDecrypted(from source: URL, to output: URL, masterKey: SymmetricKey) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = try SVC5Format.Header(parsing: SVC5Format.read(SVC5Format.headerSize, from: input))
        let fileKey = SVC5Format.fileKey(master: masterKey, fileID: header.fileID)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        var bytesWritten = 0
        var index = 0
        var moreChunks = true
        while moreChunks {
            moreChunks = try autoreleasepool { () throws -> Bool in
                guard let combined = try SVC5Format.readRecord(from: input, header: header) else { return false }
                let plaintext = try SVC5Format.open(combined, key: fileKey, aad: header.chunkAAD(index: index))
                guard bytesWritten + plaintext.count <= header.totalSize else {
                    throw VaultCryptoError.decryptionFailed
                }
                try writer.write(contentsOf: plaintext)
                bytesWritten += plaintext.count
                index += 1
                return true
            }
        }
        guard bytesWritten == header.totalSize else { throw VaultCryptoError.decryptionFailed }
        try writer.synchronize()
    }
}

/// An empty file with `.complete` protection on the same volume as a destination, so the final
/// move into place is an atomic rename and a failure never touches the destination.
private struct StagingFile {
    let directory: URL
    let file: URL

    init(for destination: URL) throws {
        let fileManager = FileManager.default
        directory = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination.deletingLastPathComponent(), create: true)
        file = directory.appendingPathComponent(UUID().uuidString)
        guard
            fileManager.createFile(
                atPath: file.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        else {
            discard() // coverage-exempt: createFile failure in the system replacement directory can't be provoked
            throw CocoaError(.fileWriteUnknown) // coverage-exempt: createFile failure can't be provoked
        }
    }

    /// Atomically moves the staged file to `destination`, replacing it if it exists.
    func commit(to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: file)
        } else {
            try fileManager.moveItem(at: file, to: destination)
        }
    }

    /// Removes the staging directory and anything left in it.
    func discard() {
        // Best effort: the directory is a temporary-items folder the system also cleans up.
        try? FileManager.default.removeItem(at: directory)
    }
}
