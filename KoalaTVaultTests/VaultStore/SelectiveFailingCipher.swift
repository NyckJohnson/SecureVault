import Foundation
import os

@testable import KoalaTVault

/// A `FileCipher` decorator that forwards to a wrapped cipher until told to fail one method, so a test can break
/// the index or map seal (`encrypt`) while file encryption (`encryptFile`) still works, or the other way round.
///
/// Every failure is off by default. Errors can be any `Error`, such as `VaultCryptoError.noKeyLoaded` or a
/// `CocoaError(.fileNoSuchFile)`.
final class SelectiveFailingCipher: FileCipher {
    private struct State: Sendable {
        var encryptError: (any Error)?
        var encryptContexts: Set<String>?
        var encryptReturnsEmptyObject = false
        var decryptError: (any Error)?
        var encryptFileError: (any Error)?
        var decryptFileError: (any Error)?
        var streamInfoError: (any Error)?
        var decryptChunkError: (any Error)?
        var streamInfoURLs: [URL] = []
        var decryptChunkCalls: [ChunkCall] = []
        var onFirstStreamInfo: (@Sendable (URL) -> Void)?
        var decryptChunkErrorFor: (@Sendable (URL) -> (any Error)?)?
        var decryptErrorFor: (@Sendable (Data) -> (any Error)?)?
    }

    /// One recorded `decryptChunk` call.
    struct ChunkCall: Sendable, Equatable {
        let index: Int
        let url: URL
    }

    private let inner: any FileCipher
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(wrapping inner: any FileCipher) { self.inner = inner }

    /// When set, `encrypt(_:context:)` (index and map seals) throws this error.
    var encryptError: (any Error)? {
        get { state.withLock { $0.encryptError } }
        set { state.withLock { $0.encryptError = newValue } }
    }

    /// When set, `encryptError` only applies to these contexts (e.g. ".vault_map", ".trash_map"); nil means all.
    var encryptFailureContexts: Set<String>? {
        get { state.withLock { $0.encryptContexts } }
        set { state.withLock { $0.encryptContexts = newValue } }
    }

    /// When true, `encrypt(_:context:)` seals `{}` instead of the data it was given (an index that lost its entries).
    var encryptSealsEmptyObject: Bool {
        get { state.withLock { $0.encryptReturnsEmptyObject } }
        set { state.withLock { $0.encryptReturnsEmptyObject = newValue } }
    }

    /// When set, `decrypt(_:contexts:)` throws this error.
    var decryptError: (any Error)? {
        get { state.withLock { $0.decryptError } }
        set { state.withLock { $0.decryptError = newValue } }
    }

    /// When set, `encryptFile(at:to:)` throws this error without writing.
    var encryptFileError: (any Error)? {
        get { state.withLock { $0.encryptFileError } }
        set { state.withLock { $0.encryptFileError = newValue } }
    }

    /// When set, `decryptFile(at:to:)` throws this error without writing.
    var decryptFileError: (any Error)? {
        get { state.withLock { $0.decryptFileError } }
        set { state.withLock { $0.decryptFileError = newValue } }
    }

    /// When set, `streamInfo(of:)` throws this error.
    var streamInfoError: (any Error)? {
        get { state.withLock { $0.streamInfoError } }
        set { state.withLock { $0.streamInfoError = newValue } }
    }

    /// When set, `decryptChunk(_:of:info:)` throws this error.
    var decryptChunkError: (any Error)? {
        get { state.withLock { $0.decryptChunkError } }
        set { state.withLock { $0.decryptChunkError = newValue } }
    }

    /// Runs once, at the first `streamInfo(of:)` call after it is set, before the call is forwarded.
    var onFirstStreamInfo: (@Sendable (URL) -> Void)? {
        get { state.withLock { $0.onFirstStreamInfo } }
        set { state.withLock { $0.onFirstStreamInfo = newValue } }
    }

    /// When set, `decryptChunk` throws the error this returns for the file's URL (nil: no failure for that file).
    var decryptChunkErrorFor: (@Sendable (URL) -> (any Error)?)? {
        get { state.withLock { $0.decryptChunkErrorFor } }
        set { state.withLock { $0.decryptChunkErrorFor = newValue } }
    }

    /// When set, `decrypt(_:contexts:)` throws the error this returns for the data (nil: no failure for that data).
    var decryptErrorFor: (@Sendable (Data) -> (any Error)?)? {
        get { state.withLock { $0.decryptErrorFor } }
        set { state.withLock { $0.decryptErrorFor = newValue } }
    }

    /// Every URL passed to `streamInfo(of:)`, in call order (recorded even when the call is made to fail).
    var streamInfoURLs: [URL] { state.withLock { $0.streamInfoURLs } }

    /// Every `decryptChunk` call, in call order (recorded even when the call is made to fail).
    var decryptChunkCalls: [ChunkCall] { state.withLock { $0.decryptChunkCalls } }

    /// Fails `streamInfo` and `decryptChunk` with `.noKeyLoaded`, as a key that vanished mid-operation would.
    func loseKeyForStreaming() {
        streamInfoError = VaultCryptoError.noKeyLoaded
        decryptChunkError = VaultCryptoError.noKeyLoaded
    }

    func encrypt(_ data: Data, context: String) throws -> Data {
        let snapshot = state.withLock { $0 }
        if let error = snapshot.encryptError, snapshot.encryptContexts?.contains(context) ?? true { throw error }
        return try inner.encrypt(snapshot.encryptReturnsEmptyObject ? Data("{}".utf8) : data, context: context)
    }

    func decrypt(_ data: Data, contexts: [String]) throws -> Data {
        if let error = decryptError { throw error }
        if let error = decryptErrorFor?(data) { throw error }
        return try inner.decrypt(data, contexts: contexts)
    }

    func encryptFile(at source: URL, to destination: URL) throws {
        if let error = encryptFileError { throw error }
        try inner.encryptFile(at: source, to: destination)
    }

    func decryptFile(at source: URL, to destination: URL) throws {
        if let error = decryptFileError { throw error }
        try inner.decryptFile(at: source, to: destination)
    }

    func streamInfo(of url: URL) throws -> StreamInfo {
        state.withLock { $0.streamInfoURLs.append(url) }
        let hook = state.withLock { state -> (@Sendable (URL) -> Void)? in
            defer { state.onFirstStreamInfo = nil }
            return state.onFirstStreamInfo
        }
        hook?(url)
        if let error = streamInfoError { throw error }
        return try inner.streamInfo(of: url)
    }

    func decryptChunk(_ index: Int, of url: URL, info: StreamInfo) throws -> Data {
        state.withLock { $0.decryptChunkCalls.append(ChunkCall(index: index, url: url)) }
        if let error = decryptChunkError { throw error }
        if let error = decryptChunkErrorFor?(url) { throw error }
        return try inner.decryptChunk(index, of: url, info: info)
    }
}

/// Makes `url` read-only (no write permission) or fully inaccessible, and gives back what restores it.
/// Call the returned closure (usually in a `defer`) before the fixture's `cleanUp()` removes the folder.
func restrict(_ url: URL, to permissions: Int = 0o555) throws -> () -> Void {
    let manager = FileManager.default
    let original = (try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o755
    try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    return { try? manager.setAttributes([.posixPermissions: original], ofItemAtPath: url.path) }
}
