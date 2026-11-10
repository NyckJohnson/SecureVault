import Foundation
import os

@testable import KoalaTVault

/// A test cipher whose files carry a real-looking SVC5 header, so the store can tell an encrypted file from a
/// plaintext one (the shared `MockFileCipher` reports stream info for any file).
///
/// A sealed file is a 32-byte header, `"SVC5" | chunkSize UInt32 LE | plaintext size UInt64 LE | 16 id bytes`,
/// followed by the plaintext itself (nothing is really encrypted). Small data goes through the wrapped mock, so
/// its calls and `errorToThrow` still apply to every method.
final class HeaderAwareTestCipher: FileCipher {
    static let headerSize = 32
    static let magic = Data("SVC5".utf8)

    private let mock: MockFileCipher
    private let truncatesCopies = OSAllocatedUnfairLock(initialState: false)

    init(wrapping mock: MockFileCipher) { self.mock = mock }

    /// When true, every file this cipher encrypts loses its last byte (header intact): an incomplete copy.
    var truncatesNewCopies: Bool {
        get { truncatesCopies.withLock { $0 } }
        set { truncatesCopies.withLock { $0 = newValue } }
    }

    private let declaredSizes = OSAllocatedUnfairLock<Int?>(initialState: nil)

    /// When set, every file this cipher encrypts records this total size in its header, whatever its content holds.
    var declaredSizeForNewCopies: Int? {
        get { declaredSizes.withLock { $0 } }
        set { declaredSizes.withLock { $0 = newValue } }
    }

    /// `content` as a sealed file would hold it.
    /// - Parameter declaredSize: the total size the header records; the content's own size when nil.
    static func sealed(_ content: Data, truncatedBy missing: Int = 0, declaredSize: Int? = nil) -> Data {
        var header = magic
        withUnsafeBytes(of: UInt32(MockFileCipher.chunkSize).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(declaredSize ?? content.count).littleEndian) { header.append(contentsOf: $0) }
        header.append(Data(repeating: 0x07, count: 16))
        return header + content.dropLast(missing)
    }

    /// Whether the bytes start with an SVC5 header.
    static func isSealed(_ data: Data) -> Bool {
        data.count >= headerSize && data.starts(with: magic)
    }

    func encrypt(_ data: Data, context: String) throws -> Data {
        try mock.encrypt(data, context: context)
    }

    func decrypt(_ data: Data, contexts: [String]) throws -> Data {
        try mock.decrypt(data, contexts: contexts)
    }

    func encryptFile(at source: URL, to destination: URL) throws {
        try mock.encryptFile(at: source, to: destination)
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let content = try Data(contentsOf: source)
        try Self.sealed(
            content, truncatedBy: truncatesNewCopies ? 1 : 0, declaredSize: declaredSizeForNewCopies
        ).write(to: destination, options: .atomic)
    }

    func decryptFile(at source: URL, to destination: URL) throws {
        try mock.decryptFile(at: source, to: destination)
        let info = try streamInfo(of: source)
        let data = try Data(contentsOf: source)
        guard data.count - Self.headerSize >= info.totalSize else { throw VaultCryptoError.decryptionFailed }
        try data.dropFirst(Self.headerSize).prefix(info.totalSize).write(to: destination, options: .atomic)
    }

    func streamInfo(of url: URL) throws -> StreamInfo {
        _ = try mock.streamInfo(of: url)
        guard let data = try? Data(contentsOf: url), Self.isSealed(data) else {
            throw VaultCryptoError.decryptionFailed
        }
        let sizeBytes = data.subdata(in: 8..<16)
        let size = sizeBytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        return StreamInfo(totalSize: Int(size), chunkSize: MockFileCipher.chunkSize)
    }

    func decryptChunk(_ index: Int, of url: URL, info: StreamInfo) throws -> Data {
        _ = try mock.decryptChunk(index, of: url, info: info)
        guard let data = try? Data(contentsOf: url), Self.isSealed(data) else {
            throw VaultCryptoError.decryptionFailed
        }
        let payload = data.dropFirst(Self.headerSize)
        let start = index * info.chunkSize
        let end = min(start + info.chunkSize, info.totalSize)
        guard index >= 0, start < end || (index == 0 && info.totalSize == 0), payload.count >= end else {
            throw VaultCryptoError.decryptionFailed
        }
        return Data(payload.dropFirst(start).prefix(end - start))
    }
}
