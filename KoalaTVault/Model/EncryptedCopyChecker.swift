//
//  EncryptedCopyChecker.swift
//  KoalaTVault
//
//  Checks a migration runs on encrypted copies before it deletes a source, built on the
//  VaultCrypto contracts (moved out of the legacy CryptoService).
//

import Foundation

/// Verifies encrypted copies made by a lock migration.
nonisolated struct EncryptedCopyChecker: Sendable {
    let keyStore: any MasterKeyStoring
    let cipher: any FileCipher

    /// SVC5 layout sizes used to compute an encrypted file's exact length: the header, each
    /// chunk's length prefix, and the AES-GCM nonce plus tag added to each chunk.
    private enum EncryptedLayout {
        static let headerSize = 32
        static let lengthPrefixSize = 4
        static let gcmOverhead = 28
    }

    /// The exact on-disk length of an encrypted file with `info`'s sizes (every chunk but the
    /// last is full).
    private func expectedEncryptedLength(for info: StreamInfo) -> Int {
        let chunkCount = (info.totalSize + info.chunkSize - 1) / info.chunkSize
        guard chunkCount > 0 else { return EncryptedLayout.headerSize }
        let lastChunkSize = info.totalSize - (chunkCount - 1) * info.chunkSize
        let recordOverhead = EncryptedLayout.lengthPrefixSize + EncryptedLayout.gcmOverhead
        return EncryptedLayout.headerSize
            + (chunkCount - 1) * (info.chunkSize + recordOverhead)
            + lastChunkSize + recordOverhead
    }

    /// True when `url` holds a complete encrypted copy of a `plaintextSize`-byte file made with
    /// the loaded key: the header records that size, the file is exactly as long as the format
    /// gives for it, and the last chunk authenticates. False otherwise (including with no key).
    /// A migration checks this before it deletes a plaintext source.
    func isCompleteEncryptedCopy(at url: URL, plaintextSize: Int) -> Bool {
        guard keyStore.isKeyLoaded,
              let info = try? cipher.streamInfo(of: url), info.totalSize == plaintextSize,
              let length = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              length == expectedEncryptedLength(for: info) else {
            return false
        }
        let chunkCount = (plaintextSize + info.chunkSize - 1) / info.chunkSize
        guard chunkCount > 0 else { return true }
        return (try? cipher.decryptChunk(chunkCount - 1, of: url, info: info)) != nil
    }

    /// True when the encrypted file at `url` decrypts, chunk by chunk, to exactly the bytes of
    /// the plaintext file at `plainURL` (same length, same content). A damaged or different copy
    /// gives false. Throws `VaultCryptoError.noKeyLoaded` without the key, or a read error (e.g.
    /// files closed by data protection), so a caller never mistakes "couldn't check" for "different".
    func encryptedFile(at url: URL, hasSameContentAs plainURL: URL) throws -> Bool {
        guard keyStore.isKeyLoaded else { throw VaultCryptoError.noKeyLoaded }
        // Opened first so an unreadable file throws instead of counting as different.
        try Self.throwIfUnreadable(url)
        let plain = try FileHandle(forReadingFrom: plainURL)
        defer { try? plain.close() }
        guard let info = try? cipher.streamInfo(of: url),
              let length = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              length == expectedEncryptedLength(for: info) else {
            return false
        }
        let chunkCount = (info.totalSize + info.chunkSize - 1) / info.chunkSize
        for index in 0..<chunkCount {
            let matches: Bool = try autoreleasepool {
                let decrypted: Data
                do {
                    decrypted = try cipher.decryptChunk(index, of: url, info: info)
                } catch VaultCryptoError.noKeyLoaded {
                    throw VaultCryptoError.noKeyLoaded
                } catch {
                    // A read failure (not damage) must still throw.
                    try Self.throwIfUnreadable(url)
                    return false
                }
                let original = try plain.read(upToCount: decrypted.count) ?? Data()
                return original == decrypted
            }
            guard matches else { return false }
        }
        return try plain.read(upToCount: 1)?.isEmpty ?? true   // the plaintext must end here too
    }

    /// Throws the read error when the file at `url` can't be opened and read.
    private static func throwIfUnreadable(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = try handle.read(upToCount: 1)
    }
}
