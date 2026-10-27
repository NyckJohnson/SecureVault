import CryptoKit
import Foundation

/// The SVC5 vault file format, byte-compatible with the files earlier app versions wrote.
///
/// Layout: a 32-byte header — "SVC5" | chunkSize UInt32 LE | plaintext size UInt64 LE | fileID (16 random
/// bytes) — then one record per chunk: [length UInt32 LE | AES-GCM combined (nonce 12 | ciphertext | tag 16)].
/// Each file has its own key, HKDF-SHA256(master key, salt fileID, info "file-key"), and each chunk is
/// authenticated with the whole header plus its index (UInt64 LE), so chunks can't be reordered, moved
/// between files, or paired with an edited header. Every chunk but the last holds exactly `chunkSize`
/// plaintext bytes, which lets a reader seek straight to any chunk.
enum SVC5Format {
    /// The four magic bytes every SVC5 file starts with.
    static let magic = Data("SVC5".utf8)
    /// Length of the header in bytes.
    static let headerSize = 32
    /// Length of the random file ID in bytes.
    static let fileIDSize = 16
    /// AES-GCM bytes added to each chunk: 12-byte nonce plus 16-byte tag.
    static let gcmOverhead = 28
    /// Bytes of the length prefix before each record.
    static let lengthPrefixSize = 4
    /// The chunk size written by this app (1 MiB).
    static let writeChunkSize = 1_048_576
    /// The largest chunk size a header may declare (16 MiB).
    static let maxChunkSize = 16 * 1_048_576
    /// The largest plaintext a file may hold (2 TiB); keeps all offset math far below `Int.max`.
    static let maxTotalSize = 1 << 41

    /// A parsed (or newly made) SVC5 header.
    struct Header {
        /// The plaintext bytes per chunk (every chunk but the last is full).
        let chunkSize: Int
        /// The total plaintext size of the file.
        let totalSize: Int
        /// The file's random ID; the salt of its file key.
        let fileID: Data
        /// The exact 32 header bytes, part of every chunk's AAD.
        let bytes: Data

        /// A header for a new file; sizes must already be in range.
        init(chunkSize: Int, totalSize: Int, fileID: Data) {
            self.chunkSize = chunkSize
            self.totalSize = totalSize
            self.fileID = fileID
            var bytes = SVC5Format.magic
            bytes.append(SVC5Format.littleEndian(UInt32(chunkSize)))
            bytes.append(SVC5Format.littleEndian(UInt64(totalSize)))
            bytes.append(fileID)
            self.bytes = bytes
        }

        /// Parses and validates `data` as a header.
        /// - Throws: `VaultCryptoError.decryptionFailed` when it is short, has the wrong magic, a chunk size
        ///   outside 1 byte…16 MiB, or a total size over 2 TiB.
        init(parsing data: Data) throws {
            let data = Data(data)  // rebase indices to 0
            guard data.count == SVC5Format.headerSize, data.prefix(4) == SVC5Format.magic else {
                throw VaultCryptoError.decryptionFailed
            }
            let chunkSize = SVC5Format.readLittleEndian(data, at: 4, count: 4)
            let totalSize = SVC5Format.readLittleEndian(data, at: 8, count: 8)
            guard (1...UInt64(SVC5Format.maxChunkSize)).contains(chunkSize),
                totalSize <= UInt64(SVC5Format.maxTotalSize)
            else {
                throw VaultCryptoError.decryptionFailed
            }
            self.chunkSize = Int(chunkSize)
            self.totalSize = Int(totalSize)
            self.fileID = data.subdata(in: 16..<32)
            self.bytes = data
        }

        /// The number of chunks the body holds (0 for an empty file).
        var chunkCount: Int { (totalSize + chunkSize - 1) / chunkSize }

        /// The valid lengths of a record's AES-GCM combined part: 1…chunkSize plaintext bytes plus overhead.
        var recordLengths: ClosedRange<Int> {
            (SVC5Format.gcmOverhead + 1)...(chunkSize + SVC5Format.gcmOverhead)
        }

        /// The byte offset of chunk `index`'s length prefix (valid because all earlier chunks are full).
        func recordOffset(of index: Int) -> Int {
            SVC5Format.headerSize + index * (SVC5Format.lengthPrefixSize + chunkSize + SVC5Format.gcmOverhead)
        }

        /// The AAD of chunk `index`: the header bytes plus the index as UInt64 LE.
        func chunkAAD(index: Int) -> Data {
            bytes + SVC5Format.littleEndian(UInt64(index))
        }
    }

    /// A fresh random file ID from the system CSPRNG.
    static func randomFileID() -> Data {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    /// The per-file key: HKDF-SHA256 of the master key, salted with the file ID, info "file-key".
    static func fileKey(master: SymmetricKey, fileID: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master, salt: fileID, info: Data("file-key".utf8), outputByteCount: 32)
    }

    /// Seals one chunk into a record: [length UInt32 LE | AES-GCM combined].
    /// - Throws: `VaultCryptoError.encryptionFailed` if sealing fails.
    static func sealRecord(_ chunk: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard let combined = try? AES.GCM.seal(chunk, using: key, authenticating: aad).combined else {
            throw VaultCryptoError.encryptionFailed // coverage-exempt: AES-GCM seal with a valid key and nonce does not fail
        }
        return littleEndian(UInt32(combined.count)) + combined
    }

    /// Opens an AES-GCM combined blob.
    /// - Throws: `VaultCryptoError.decryptionFailed` on a malformed blob or failed authentication.
    static func open(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw VaultCryptoError.decryptionFailed
        }
    }

    /// Reads one record at the handle's position and returns its combined part.
    /// - Returns: nil at a clean end of file (no bytes left).
    /// - Throws: `VaultCryptoError.decryptionFailed` for a partial prefix, an out-of-range length or a
    ///   truncated record; file errors as thrown by `FileHandle`.
    static func readRecord(from handle: FileHandle, header: Header) throws -> Data? {
        let prefix = try read(lengthPrefixSize, from: handle)
        if prefix.isEmpty { return nil }
        guard prefix.count == lengthPrefixSize else { throw VaultCryptoError.decryptionFailed }
        let length = Int(readLittleEndian(prefix, at: 0, count: lengthPrefixSize))
        guard header.recordLengths.contains(length) else { throw VaultCryptoError.decryptionFailed }
        let combined = try read(length, from: handle)
        guard combined.count == length else { throw VaultCryptoError.decryptionFailed }
        return combined
    }

    /// Reads up to `count` bytes, looping over short reads; fewer bytes only at end of file.
    static func read(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            guard let piece = try handle.read(upToCount: count - data.count), !piece.isEmpty else { break }
            data.append(piece)
        }
        return data
    }

    /// `value` as 4 little-endian bytes.
    static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// `value` as 8 little-endian bytes.
    static func littleEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// The little-endian unsigned integer of `count` (≤ 8) bytes at `offset` of `data`.
    static func readLittleEndian(_ data: Data, at offset: Int, count: Int) -> UInt64 {
        var result: UInt64 = 0
        for position in 0..<count {
            result |= UInt64(data[data.startIndex + offset + position]) << UInt64(8 * position)
        }
        return result
    }
}
