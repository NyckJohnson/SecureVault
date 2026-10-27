import Foundation
import os

/// A cipher that tags data with its context instead of encrypting it, and copies files; records every call.
final class MockFileCipher: FileCipher {
    /// A recorded call.
    enum Call: Equatable, Sendable {
        case encrypt(context: String)
        case decrypt(contexts: [String])
        case encryptFile(source: URL, destination: URL)
        case decryptFile(source: URL, destination: URL)
        case streamInfo(URL)
        case decryptChunk(Int, URL)
    }

    /// The chunk size the mock reports for every file (1 MiB, as SVC5 writes).
    static let chunkSize = 1_048_576

    private struct State: Sendable {
        var calls: [Call] = []
        var errorToThrow: VaultCryptoError?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Every call so far, in order.
    var calls: [Call] { state.withLock { $0.calls } }

    /// When set, every call throws this error.
    var errorToThrow: VaultCryptoError? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    func encrypt(_ data: Data, context: String) throws -> Data {
        try record(.encrypt(context: context))
        return Self.tag(context) + data
    }

    func decrypt(_ data: Data, contexts: [String]) throws -> Data {
        try record(.decrypt(contexts: contexts))
        for context in contexts {
            let tag = Self.tag(context)
            if data.starts(with: tag) { return data.dropFirst(tag.count) }
        }
        throw VaultCryptoError.decryptionFailed
    }

    func encryptFile(at source: URL, to destination: URL) throws {
        try record(.encryptFile(source: source, destination: destination))
        try Self.copy(source, to: destination)
    }

    func decryptFile(at source: URL, to destination: URL) throws {
        try record(.decryptFile(source: source, destination: destination))
        try Self.copy(source, to: destination)
    }

    func streamInfo(of url: URL) throws -> StreamInfo {
        try record(.streamInfo(url))
        let size = try Self.size(of: url)
        return StreamInfo(totalSize: size, chunkSize: Self.chunkSize)
    }

    func decryptChunk(_ index: Int, of url: URL, info: StreamInfo) throws -> Data {
        try record(.decryptChunk(index, url))
        let start = index * info.chunkSize
        guard index >= 0, start < info.totalSize || (index == 0 && info.totalSize == 0) else {
            throw VaultCryptoError.decryptionFailed
        }
        guard let data = try? Data(contentsOf: url) else { throw VaultCryptoError.decryptionFailed }
        return data.subdata(in: start..<min(start + info.chunkSize, data.count))
    }

    private func record(_ call: Call) throws {
        try state.withLock { state in
            state.calls.append(call)
            if let error = state.errorToThrow { throw error }
        }
    }

    private static func tag(_ context: String) -> Data {
        Data("mock-sealed:\(context):".utf8)
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        do {
            let data = try Data(contentsOf: source)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw VaultCryptoError.decryptionFailed
        }
    }

    private static func size(of url: URL) throws -> Int {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize else {
            throw VaultCryptoError.decryptionFailed
        }
        return size
    }
}
