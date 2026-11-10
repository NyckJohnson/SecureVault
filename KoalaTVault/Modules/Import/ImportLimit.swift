import Foundation

/// The free tier's file limit, checked before anything is imported.
struct ImportLimit: Sendable {
    private let store: any VaultStoring
    private let proUnlock: any ProUnlocking

    init(store: any VaultStoring, proUnlock: any ProUnlocking) {
        self.store = store
        self.proUnlock = proUnlock
    }

    /// Passes for Pro. For a free user, throws `ImportError.fileLimitReached` when adding `count` files
    /// would take the vault past the limit; reaching the limit exactly passes. Also rethrows the store's
    /// error if the vault's files can't be counted.
    func checkAllowed(adding count: Int) async throws {
        guard !proUnlock.isUnlockedNow else { return }
        let existing = try await store.countFiles()
        guard existing + count <= ProUnlock.freeFileLimit else {
            throw ImportError.fileLimitReached(limit: ProUnlock.freeFileLimit)
        }
    }
}
