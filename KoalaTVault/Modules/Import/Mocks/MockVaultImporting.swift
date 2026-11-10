import Foundation
import os

/// An importer that counts what it is given against a free limit; records every call.
final class MockVaultImporting: VaultImporting {
    /// A recorded call.
    enum Call: Equatable, Sendable {
        case checkAllowed(adding: Int)
        case importItems([URL], into: String)
        case importPhotos(count: Int, into: String)
    }

    private struct State: Sendable {
        var fileCount: Int
        var isPro: Bool
        var calls: [Call] = []
        var errorToThrow: ImportError?
    }

    private let state: OSAllocatedUnfairLock<State>

    /// An importer for a vault already holding `fileCount` files.
    init(fileCount: Int = 12, isPro: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(fileCount: fileCount, isPro: isPro))
    }

    /// Every call so far, in order.
    var calls: [Call] { state.withLock { $0.calls } }

    /// When set, the import calls throw this error (after the limit check).
    var errorToThrow: ImportError? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    func checkAllowed(adding count: Int) async throws {
        try state.withLock { state in
            state.calls.append(.checkAllowed(adding: count))
            try Self.check(adding: count, state)
        }
    }

    func importItems(
        _ urls: [URL],
        into directory: VaultDirectory,
        progress: @Sendable (Double) -> Void
    ) async throws -> ImportResult {
        try state.withLock { state in
            state.calls.append(.importItems(urls, into: directory.name))
            try Self.check(adding: urls.count, state)
            if let error = state.errorToThrow { throw error }
            state.fileCount += urls.count
        }
        progress(0)
        progress(1)
        return ImportResult(imported: urls.count, skippedDuplicates: 0, failed: 0)
    }

    func importPhotos(_ assets: [PhotoImportSource], into directory: VaultDirectory) async throws -> PhotoImportResult {
        try state.withLock { state in
            state.calls.append(.importPhotos(count: assets.count, into: directory.name))
            try Self.check(adding: assets.count, state)
            if let error = state.errorToThrow { throw error }
            state.fileCount += assets.count
        }
        return PhotoImportResult(importedAssetIDs: assets.compactMap(\.assetID), failed: 0)
    }

    private static func check(adding count: Int, _ state: State) throws {
        if !state.isPro && state.fileCount + count > ProUnlock.freeFileLimit {
            throw ImportError.fileLimitReached(limit: ProUnlock.freeFileLimit)
        }
    }
}
