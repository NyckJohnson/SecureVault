import Foundation
import os

/// A transfer that reports every file done (or the chosen failures) without touching either store; records
/// every call.
final class MockVaultTransferring: VaultTransferring {
    /// A recorded call: the item ids, the two roots' names, and whether originals are removed.
    struct Call: Equatable, Sendable {
        let itemIDs: [String]
        let source: String
        let target: String
        let removingOriginals: Bool
    }

    private struct State: Sendable {
        var calls: [Call] = []
        var errorToThrow: VaultTransferError?
        var failingIDs: Set<String> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Every call so far, in order.
    var calls: [Call] { state.withLock { $0.calls } }

    /// When set, `transfer` throws this error before reporting any progress.
    var errorToThrow: VaultTransferError? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    /// Ids of the items that fail.
    var failingIDs: Set<String> {
        get { state.withLock { $0.failingIDs } }
        set { state.withLock { $0.failingIDs = newValue } }
    }

    func transfer(
        _ items: [VaultItem],
        from source: any VaultStoring,
        to target: any VaultStoring,
        removingOriginals: Bool,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TransferResult {
        let call = Call(
            itemIDs: items.map(\.id), source: source.root.name, target: target.root.name,
            removingOriginals: removingOriginals)
        let (error, failing) = state.withLock { state in
            state.calls.append(call)
            return (state.errorToThrow, state.failingIDs)
        }
        if let error { throw error }
        for done in items.indices {
            progress(done + 1, items.count)
        }
        let failed = items.filter { failing.contains($0.id) }.count
        return TransferResult(done: items.count - failed, failed: failed)
    }
}
