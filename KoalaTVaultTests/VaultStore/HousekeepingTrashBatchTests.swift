import Foundation
import Testing
import os

@testable import KoalaTVault

/// Large-trash housekeeping (feature multiple-vaults-duress-password, device retest 2026-11-13): `hasUnreadableTrash`
/// checks the top-level trash items, and `hasUnencryptedFiles` the trash's files, in batches of at most 256, each its
/// own store step, so another store operation can run between batches.
///
/// The tests assume one `streamInfo` call per checked trash file (as the folder checks of `HousekeepingBatchTests` do).
@Suite struct HousekeepingTrashBatchTests {
    // MARK: - Helpers

    /// Runs `hook` with the 1-based number of each `streamInfo` call. The cipher's one-shot hook re-installs itself at
    /// every call, so this sees the n-th check exactly.
    private func onEveryStreamInfo(of failing: SelectiveFailingCipher, _ body: @escaping @Sendable (Int) -> Void) {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        @Sendable func hook(_ url: URL) {
            failing.onFirstStreamInfo = hook
            let number = calls.withLock { count -> Int in
                count += 1
                return count
            }
            body(number)
        }
        failing.onFirstStreamInfo = hook
    }

    /// A vault whose trash holds `count` healthy encrypted-form top-level files, each with its own trash entry.
    private func vaultWithTrash(count: Int) async throws -> VaultStoreFixture {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        let item = try await vault.add("seed.txt", "seed")
        try await vault.store.moveToTrash(item)
        let entries = try #require(vault.trashEntries())
        let (seedKey, seedEntry) = try #require(entries.first)
        let seedFile = vault.trashURL.appendingPathComponent(seedKey)
        var all = entries
        for index in 1..<max(count, 1) {
            let key = VaultStoreFixture.newDiskName()
            try FileManager.default.copyItem(at: seedFile, to: vault.trashURL.appendingPathComponent(key))
            var entry = seedEntry
            entry["originalName"] = String(format: "seed%04d.txt", index)
            all[key] = entry
        }
        let json = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        try (VaultStoreFixture.sealedPrefix + Data(".trash_map:".utf8) + json).write(to: vault.trashMapURL)
        return vault
    }

    private struct ListingOutcome<T: Sendable>: Sendable {
        let listingReturnedByCheckpoint: Bool
        let listingReturnedBeforeEnd: Bool
        let result: T
    }

    /// Runs `operation` and, once its first file check is in progress, asks for a listing; the file check number
    /// `waitAtCall` waits (bounded) for that listing to have returned. Returns whether it had, and the operation's result.
    private func runWithListing<T: Sendable>(
        _ vault: VaultStoreFixture, waitAtCall: Int, _ operation: @escaping @Sendable (LiveVaultStore) async throws -> T
    ) async throws -> ListingOutcome<T> {
        let failing = try #require(vault.failing)
        let gate = HousekeepingGate()
        let listingReturned = OSAllocatedUnfairLock(initialState: false)
        let sawListingReturned = OSAllocatedUnfairLock(initialState: false)
        onEveryStreamInfo(of: failing) { number in
            if number == 1 { gate.pass() }
            guard number == waitAtCall else { return }
            for _ in 0..<600 {
                if listingReturned.withLock({ $0 }) { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            sawListingReturned.withLock { $0 = listingReturned.withLock { $0 } }
        }
        let store = vault.store
        let root = vault.root
        let aboutToList = Signal()

        let check = Task { try await operation(store) }
        #expect(await gate.waitUntilEntered())
        let listing = Task {
            aboutToList.raise()
            let items = try await store.contents(of: root, sortedBy: .name, .ascending)
            listingReturned.withLock { $0 = true }
            return items
        }
        #expect(await aboutToList.waitUntilRaised())
        gate.release()
        _ = try await listing.value
        let result = try await check.value
        return ListingOutcome(
            listingReturnedByCheckpoint: sawListingReturned.withLock { $0 },
            listingReturnedBeforeEnd: listingReturned.withLock { $0 },
            result: result)
    }

    // MARK: - hasUnreadableTrash

    @Test("A listing asked for during hasUnreadableTrash's first batch runs before the 300th trash item is checked")
    func listingRunsBetweenUnreadableTrashBatches() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }

        let outcome = try await runWithListing(vault, waitAtCall: 300) { await $0.hasUnreadableTrash() }

        #expect(outcome.listingReturnedByCheckpoint)
        #expect(outcome.listingReturnedBeforeEnd)
        #expect(outcome.result == false)
    }

    @Test("hasUnreadableTrash checks every top-level trash item across batches and answers false when all are readable")
    func unreadableTrashChecksAllItems() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)

        #expect(await vault.store.hasUnreadableTrash() == false)

        #expect(failing.streamInfoURLs.count >= 600)
    }

    @Test("hasUnreadableTrash finds an unreadable item that is in a later batch")
    func unreadableTrashFindsItemInLaterBatch() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        // The last 300 names (sorted) are unreadable, the rest healthy: the store finds one whatever its order.
        let files = try FileManager.default.contentsOfDirectory(atPath: vault.trashURL.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        for name in files.suffix(300) {
            try HeaderAwareTestCipher.sealed(Data("zz".utf8), declaredSize: 4096)
                .write(to: vault.trashURL.appendingPathComponent(name))
        }

        #expect(await vault.store.hasUnreadableTrash())
    }

    @Test("hasUnreadableTrash stops at the first unreadable item and checks no further batch")
    func unreadableTrashStopsAtFirstUnreadable() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let files = try FileManager.default.contentsOfDirectory(atPath: vault.trashURL.path)
            .filter { !$0.hasPrefix(".") }
        for name in files {
            try HeaderAwareTestCipher.sealed(Data("zz".utf8), declaredSize: 4096)
                .write(to: vault.trashURL.appendingPathComponent(name))
        }

        #expect(await vault.store.hasUnreadableTrash())

        let checked = failing.streamInfoURLs.count
        #expect(checked >= 1)
        #expect(checked <= 256)
    }

    @Test("hasUnreadableTrash answers false and checks no further batch when cancelled between batches")
    func unreadableTrashStopsWhenCancelledBetweenBatches() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let gate = HousekeepingGate()
        failing.onFirstStreamInfo = { _ in gate.pass() }
        let store = vault.store

        let check = Task { await store.hasUnreadableTrash() }
        #expect(await gate.waitUntilEntered())
        check.cancel()
        gate.release()
        let result = await check.value

        #expect(result == false)
        #expect(failing.streamInfoURLs.count <= 256)
    }

    @Test("hasUnreadableTrash answers false and checks no further batch when the vault locks between batches")
    func unreadableTrashStopsWhenLockedBetweenBatches() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let keys = vault.keys
        onEveryStreamInfo(of: failing) { number in
            if number == 256 { keys.wipeKey() }
        }

        let result = await vault.store.hasUnreadableTrash()

        #expect(result == false)
        #expect(failing.streamInfoURLs.count <= 256)
    }

    @Test("hasUnreadableTrash answers false and stops after the batch when the trash becomes a symlink")
    func unreadableTrashStopsWhenTrashReplacedBetweenBatches() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let trashURL = vault.trashURL
        let movedURL = trashURL.deletingLastPathComponent()
            .appendingPathComponent("moved-trash-\(UUID().uuidString)")
        onEveryStreamInfo(of: failing) { number in
            guard number == 256 else { return }
            let fileManager = FileManager.default
            // Every file still to be checked is unreadable, so a check that goes on would answer true.
            let names = (try? fileManager.contentsOfDirectory(atPath: trashURL.path)) ?? []
            for name in names where !name.hasPrefix(".") {
                try? HeaderAwareTestCipher.sealed(Data("zz".utf8), declaredSize: 4096)
                    .write(to: trashURL.appendingPathComponent(name))
            }
            // The real folder moves aside and a symlink to it takes the `.trash` path.
            try? fileManager.moveItem(at: trashURL, to: movedURL)
            try? fileManager.createSymbolicLink(at: trashURL, withDestinationURL: movedURL)
        }

        let result = await vault.store.hasUnreadableTrash()

        #expect(result == false)
        #expect(failing.streamInfoURLs.count <= 256)
    }

    // MARK: - hasUnencryptedFiles (the trash part)

    @Test("A listing asked for during hasUnencryptedFiles's first trash batch runs before the 300th file is checked")
    func listingRunsBetweenTrashFileBatches() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }

        let outcome = try await runWithListing(vault, waitAtCall: 300) { try await $0.hasUnencryptedFiles() }

        #expect(outcome.listingReturnedByCheckpoint)
        #expect(outcome.listingReturnedBeforeEnd)
        #expect(outcome.result == false)
    }

    @Test("hasUnencryptedFiles checks every trash file across batches and answers false when all are encrypted")
    func unencryptedChecksAllTrashFiles() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)

        #expect(try await vault.store.hasUnencryptedFiles() == false)

        #expect(failing.streamInfoURLs.count >= 600)
    }

    @Test("hasUnencryptedFiles finds a plaintext trash file in a later batch")
    func unencryptedFindsPlaintextInLaterBatch() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        let files = try FileManager.default.contentsOfDirectory(atPath: vault.trashURL.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        // The last 300 names (sorted) are plaintext, the rest encrypted: the store finds one whatever its order.
        for name in files.suffix(300) {
            try Data("plain".utf8).write(to: vault.trashURL.appendingPathComponent(name))
        }

        #expect(try await vault.store.hasUnencryptedFiles())
    }

    @Test("hasUnencryptedFiles stops at the first plaintext trash file")
    func unencryptedStopsAtFirstPlaintextTrashFile() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let files = try FileManager.default.contentsOfDirectory(atPath: vault.trashURL.path)
            .filter { !$0.hasPrefix(".") }
        for name in files { try Data("plain".utf8).write(to: vault.trashURL.appendingPathComponent(name)) }

        #expect(try await vault.store.hasUnencryptedFiles())

        #expect(failing.streamInfoURLs.count <= 256)
    }

    @Test("hasUnencryptedFiles throws CancellationError when cancelled between trash batches")
    func unencryptedTrashThrowsWhenCancelledBetweenBatches() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let gate = HousekeepingGate()
        failing.onFirstStreamInfo = { _ in gate.pass() }
        let store = vault.store

        let check = Task { try await store.hasUnencryptedFiles() }
        #expect(await gate.waitUntilEntered())
        check.cancel()
        gate.release()
        let error = await caught { _ = try await check.value }

        #expect(error is CancellationError)
    }

    @Test("hasUnencryptedFiles throws locked when the vault locks between trash batches")
    func unencryptedTrashThrowsLockedBetweenBatches() async throws {
        let vault = try await vaultWithTrash(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let keys = vault.keys
        // The key goes at the last file check of the first batch, so `.locked` can only come from the check
        // before the second batch.
        onEveryStreamInfo(of: failing) { number in
            if number == 256 { keys.wipeKey() }
        }

        let error = await caught { _ = try await vault.store.hasUnencryptedFiles() }

        #expect(error as? VaultStoreError == .locked)
    }
}
