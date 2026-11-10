import Foundation
import Testing

@testable import KoalaTVault

// Assumed: `ImportLimit(store: any VaultStoring, proUnlock: any ProUnlocking)` with
// `func checkAllowed(adding count: Int) async throws`.
@MainActor
@Suite struct ImportLimitTests {
    private func limit(fileCount: Int, isPro: Bool) throws -> (ImportLimit, DiskBackedVaultStore) {
        let store = try DiskBackedVaultStore(extraFileCount: fileCount)
        return (ImportLimit(store: store, proUnlock: MockProUnlocking(isUnlocked: isPro)), store)
    }

    @Test("A Pro user always passes, however many files the vault holds")
    func proAlwaysPasses() async throws {
        let (limit, store) = try limit(fileCount: 5_000, isPro: true)
        defer { store.cleanup() }
        try await limit.checkAllowed(adding: 1_000)
    }

    @Test("A free user passes when the total is exactly 100")
    func freeExactlyAtLimitPasses() async throws {
        let (limit, store) = try limit(fileCount: 99, isPro: false)
        defer { store.cleanup() }
        try await limit.checkAllowed(adding: 1)
    }

    @Test("A free user adding nothing to a vault of 100 files passes")
    func freeAddingZeroAtLimitPasses() async throws {
        let (limit, store) = try limit(fileCount: 100, isPro: false)
        defer { store.cleanup() }
        try await limit.checkAllowed(adding: 0)
    }

    @Test(
        "A free user passing 100 files throws fileLimitReached with limit 100",
        arguments: [(99, 2), (100, 1), (0, 101)])
    func freeOverLimitThrows(existing: Int, adding: Int) async throws {
        let (limit, store) = try limit(fileCount: existing, isPro: false)
        defer { store.cleanup() }
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            try await limit.checkAllowed(adding: adding)
        }
    }

    @Test("A free user adding 100 files to an empty vault passes")
    func freeHundredIntoEmptyPasses() async throws {
        let (limit, store) = try limit(fileCount: 0, isPro: false)
        defer { store.cleanup() }
        try await limit.checkAllowed(adding: 100)
    }

    @Test("Files already on disk count toward the limit")
    func filesOnDiskCount() async throws {
        let store = try DiskBackedVaultStore(extraFileCount: 99)
        defer { store.cleanup() }
        try store.seed("a.txt", content: "a")
        let limit = ImportLimit(store: store, proUnlock: MockProUnlocking(isUnlocked: false))
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            try await limit.checkAllowed(adding: 1)
        }
    }

    @Test("An error from the store's countFiles is rethrown for a free user")
    func countFilesErrorIsRethrownForFree() async throws {
        let (limit, store) = try limit(fileCount: 0, isPro: false)
        defer { store.cleanup() }
        store.failCountFiles(with: VaultStoreError.io("count failed"))
        await #expect(throws: VaultStoreError.io("count failed")) {
            try await limit.checkAllowed(adding: 1)
        }
    }

    @Test("A Pro user passes even when counting files would fail")
    func proPassesWhenCountingFails() async throws {
        let (limit, store) = try limit(fileCount: 0, isPro: true)
        defer { store.cleanup() }
        store.failCountFiles(with: VaultStoreError.io("count failed"))
        try await limit.checkAllowed(adding: 1)
    }
}
