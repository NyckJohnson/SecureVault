import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct LiveLockMigratorUnreadableTrashTests {
    private func unreadableHarness() async -> MigrationHarness {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        harness.store.unreadableTrash = true
        await harness.run()
        return harness
    }

    @Test("Where the run would publish failed it asks about unreadable trash first; true → unreadableTrash")
    func failedFilesWithUnreadableTrash() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        harness.store.unreadableTrash = true
        let recorder = harness.recorder()
        await harness.run()
        await recorder.wait { $0 == .unreadableTrash }
        await recorder.finish()
        #expect(harness.migrator.phase == .unreadableTrash)
        #expect(harness.log.count(of: "hasUnreadableTrash") >= 1)
        #expect(!recorder.phases.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("A listing failure with unreadable trash also ends in unreadableTrash")
    func listingFailureWithUnreadableTrash() async {
        let harness = MigrationHarness()
        harness.store.setListingFailure(.io("cannot list"))
        harness.store.unreadableTrash = true
        await harness.run()
        #expect(harness.migrator.phase == .unreadableTrash)
    }

    @Test("Failed files without unreadable trash still end failed, after asking")
    func failedWithoutUnreadableTrash() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        #expect(harness.migrator.phase == .failed(names: ["c.mov"]))
        #expect(harness.log.count(of: "hasUnreadableTrash") >= 1)
    }

    @Test("A retry that fails again with unreadable trash ends in unreadableTrash")
    func retryEndsInUnreadableTrash() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        #expect(harness.migrator.phase == .failed(names: ["c.mov"]))
        harness.store.unreadableTrash = true
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .unreadableTrash)
    }

    @Test("Clearing publishes running, clears the store's trash, lists again and completes")
    func clearFlow() async {
        let harness = await unreadableHarness()
        harness.store.setFailure(nil, for: "c.mov")
        let recorder = harness.recorder()
        await harness.migrator.clearUnreadableTrash()
        await recorder.wait { $0 == .completed(fully: true) }
        await recorder.finish()
        #expect(recorder.phases.first.map { if case .running = $0 { true } else { false } } == true)
        #expect(recorder.phases.last == .completed(fully: true))
        #expect(harness.log.count(of: "clearUnreadableTrash") == 1)
        #expect(harness.log.count(of: "list") == 2)
        let events = harness.log.events
        let clear = events.firstIndex(of: "clearUnreadableTrash")
        let relist = events.lastIndex(of: "list")
        #expect(clear != nil && relist != nil)
        if let clear, let relist { #expect(clear < relist) }
        #expect(harness.store.isEncrypted("c.mov") == true)
    }

    @Test("After clearing, files that still fail end the run failed with their names")
    func clearThenStillFailing() async {
        let harness = await unreadableHarness()
        await harness.migrator.clearUnreadableTrash()
        #expect(harness.migrator.phase == .failed(names: ["c.mov"]))
    }

    @Test("A clearing failure ends the run failed with no names")
    func clearingFailure() async {
        let harness = await unreadableHarness()
        harness.store.setClearFailure(.io("cannot clear"))
        await harness.migrator.clearUnreadableTrash()
        #expect(harness.migrator.phase == .failed(names: []))
    }

    @Test("A clearing failure caused by a lock ends the run idle, not failed")
    func clearingLocked() async {
        let harness = await unreadableHarness()
        harness.store.setClearFailure(.locked)
        let recorder = harness.recorder()
        await harness.migrator.clearUnreadableTrash()
        await recorder.finish()
        #expect(harness.migrator.phase == .idle)
        #expect(!recorder.phases.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("Clearing does nothing unless the phase is unreadableTrash")
    func clearOnlyFromUnreadableTrash() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        await harness.migrator.clearUnreadableTrash()
        #expect(harness.migrator.phase == .failed(names: ["c.mov"]))
        #expect(harness.log.count(of: "clearUnreadableTrash") == 0)
    }

    @Test("Skip from unreadableTrash ends completed(fully: false)")
    func skipFromUnreadableTrash() async {
        let harness = await unreadableHarness()
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .completed(fully: false))
    }

    @Test("Retry does nothing from unreadableTrash")
    func retryDoesNothingFromUnreadableTrash() async {
        let harness = await unreadableHarness()
        let attempts = harness.log.count(of: "enc:c.mov")
        harness.store.setFailure(nil, for: "c.mov")
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .unreadableTrash)
        #expect(harness.log.count(of: "enc:c.mov") == attempts)
    }
}
