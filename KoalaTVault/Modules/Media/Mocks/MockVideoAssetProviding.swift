import AVFoundation
import Foundation
import os

/// Returns an asset for the item's disk URL; records every call.
final class MockVideoAssetProviding: VideoAssetProviding {
    private struct State: Sendable {
        var requestedIDs: [String] = []
        var errorToThrow: VaultCryptoError?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// The ids of the items assets were requested for, in order.
    var requestedIDs: [String] { state.withLock { $0.requestedIDs } }

    /// When set, `asset(for:)` throws this error.
    var errorToThrow: VaultCryptoError? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    func asset(for item: VaultItem) throws -> AVURLAsset {
        try state.withLock { state in
            state.requestedIDs.append(item.id)
            if let error = state.errorToThrow { throw error }
        }
        return AVURLAsset(url: item.diskURL)
    }
}
