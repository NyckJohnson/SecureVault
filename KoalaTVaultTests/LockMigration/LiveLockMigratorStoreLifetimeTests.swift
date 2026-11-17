import Foundation
import Testing

@testable import KoalaTVault

/// The migrator holds the store only while a run exists (running, failed, unreadable trash).
@MainActor
@Suite struct LiveLockMigratorStoreLifetimeTests {
    private func makeStore(
        _ files: [VaultItem] = MigrationHarness.plaintextFiles(), gate: MigrationGate = MigrationGate()
    ) -> FakeLeftoverStore {
        FakeLeftoverStore(items: files, log: MigrationEventLog(), gate: gate)
    }

    @Test("The store is released when the run completes")
    func releasedAfterCompletion() async {
        let migrator = LiveLockMigrator()
        weak var weakStore: FakeLeftoverStore?
        do {
            let store = makeStore()
            weakStore = store
            await migrator.encryptLeftovers(in: store)
        }
        #expect(migrator.phase == .completed(fully: true))
        #expect(weakStore == nil)
    }

    @Test("The store is still held while the run is failed")
    func heldWhileFailed() async {
        let migrator = LiveLockMigrator()
        weak var weakStore: FakeLeftoverStore?
        do {
            let store = makeStore()
            store.setFailure(.io("bad"), for: "c.mov")
            weakStore = store
            await migrator.encryptLeftovers(in: store)
        }
        #expect(migrator.phase == .failed(names: ["c.mov"]))
        #expect(weakStore != nil)
    }

    @Test("The store is still held while the run awaits the unreadable-trash choice")
    func heldWhileUnreadableTrash() async {
        let migrator = LiveLockMigrator()
        weak var weakStore: FakeLeftoverStore?
        do {
            let store = makeStore()
            store.setFailure(.io("bad"), for: "c.mov")
            store.unreadableTrash = true
            weakStore = store
            await migrator.encryptLeftovers(in: store)
        }
        #expect(migrator.phase == .unreadableTrash)
        #expect(weakStore != nil)
    }

    @Test("Retry still works on the held store, and the store is released once the retry completes")
    func retryUsesHeldStoreThenReleases() async {
        let migrator = LiveLockMigrator()
        weak var weakStore: FakeLeftoverStore?
        do {
            let store = makeStore()
            store.setFailure(.io("bad"), for: "c.mov")
            weakStore = store
            await migrator.encryptLeftovers(in: store)
            store.setFailure(nil, for: "c.mov")
        }
        await migrator.retryFailed()
        #expect(migrator.phase == .completed(fully: true))
        #expect(weakStore == nil)
    }

    @Test("The store is released after skipFailed")
    func releasedAfterSkip() async {
        let migrator = LiveLockMigrator()
        weak var weakStore: FakeLeftoverStore?
        do {
            let store = makeStore()
            store.setFailure(.io("bad"), for: "c.mov")
            weakStore = store
            await migrator.encryptLeftovers(in: store)
        }
        await migrator.skipFailed()
        #expect(migrator.phase == .completed(fully: false))
        #expect(weakStore == nil)
    }

    @Test("The store is released after skipFailed from unreadableTrash")
    func releasedAfterSkipFromUnreadableTrash() async {
        let migrator = LiveLockMigrator()
        weak var weakStore: FakeLeftoverStore?
        do {
            let store = makeStore()
            store.setFailure(.io("bad"), for: "c.mov")
            store.unreadableTrash = true
            weakStore = store
            await migrator.encryptLeftovers(in: store)
        }
        await migrator.skipFailed()
        #expect(weakStore == nil)
    }

    @Test("The store is released after a cancel while a file is in progress")
    func releasedAfterCancel() async {
        let migrator = LiveLockMigrator()
        let gate = MigrationGate()
        weak var weakStore: FakeLeftoverStore?
        do {
            let store = makeStore(gate: gate)
            weakStore = store
            gate.arm(at: "migrate:b.pdf")
            let task = Task { await migrator.encryptLeftovers(in: store) }
            #expect(await waitForCondition { gate.hasReached("migrate:b.pdf") })
            migrator.cancel()
            gate.release()
            await task.value
        }
        #expect(migrator.phase == .idle)
        #expect(weakStore == nil)
    }

    @Test("The store is released after a cancel while failed")
    func releasedAfterCancelWhileFailed() async {
        let migrator = LiveLockMigrator()
        weak var weakStore: FakeLeftoverStore?
        do {
            let store = makeStore()
            store.setFailure(.io("bad"), for: "c.mov")
            weakStore = store
            await migrator.encryptLeftovers(in: store)
        }
        migrator.cancel()
        #expect(weakStore == nil)
    }
}
