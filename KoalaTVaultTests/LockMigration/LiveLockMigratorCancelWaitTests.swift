import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct LiveLockMigratorCancelWaitTests {
    /// Starts a run, holds its file `b.pdf` in progress and cancels the run.
    private func cancelledRunWithFileInProgress(
        _ harness: MigrationHarness
    ) async -> Task<Void, Never> {
        harness.gate.arm(at: "migrate:b.pdf")
        let task = Task { await harness.run() }
        #expect(await waitForCondition { harness.gate.hasReached("migrate:b.pdf") })
        harness.migrator.cancel()
        return task
    }

    private func secondStore() -> (store: FakeLeftoverStore, log: MigrationEventLog) {
        let log = MigrationEventLog()
        return (FakeLeftoverStore(items: MigrationHarness.plaintextFiles(), log: log, gate: MigrationGate()), log)
    }

    @Test("A call made while a cancelled run's file is in progress waits for it, then runs")
    func callWaitsForCancelledRunner() async {
        let harness = MigrationHarness()
        let first = await cancelledRunWithFileInProgress(harness)
        let (store, log) = secondStore()
        let second = Task { await harness.migrator.encryptLeftovers(in: store) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.events.isEmpty)
        harness.gate.release()
        await first.value
        await second.value
        #expect(harness.migrator.phase == .completed(fully: true))
        for name in MigrationHarness.names { #expect(store.isEncrypted(name) == true) }
        #expect(log.count(of: "finishEncryption") == 1)
    }

    @Test("A call for the same store waits for the cancelled file too, then completes the run")
    func sameStoreWaitsForCancelledRunner() async {
        let harness = MigrationHarness()
        let first = await cancelledRunWithFileInProgress(harness)
        let second = Task { await harness.run() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.log.count(of: "enc:c.mov") == 0)
        harness.gate.release()
        await first.value
        await second.value
        #expect(harness.migrator.phase == .completed(fully: true))
        for name in MigrationHarness.names { #expect(harness.store.isEncrypted(name) == true) }
    }

    @Test("A second cancel during the wait drops the waiting call: it never touches its store, phase idle")
    func secondCancelDropsWaitingCall() async {
        let harness = MigrationHarness()
        let first = await cancelledRunWithFileInProgress(harness)
        let (store, log) = secondStore()
        let second = Task { await harness.migrator.encryptLeftovers(in: store) }
        try? await Task.sleep(for: .milliseconds(100))
        harness.migrator.cancel()
        harness.gate.release()
        await first.value
        await second.value
        #expect(log.events.isEmpty)
        #expect(harness.migrator.phase == .idle)
    }

    @Test("A non-encrypted store after a completed run sets the phase to idle and makes no store calls")
    func nonEncryptedStoreAfterCompletedRun() async {
        let harness = MigrationHarness()
        await harness.run()
        #expect(harness.migrator.phase == .completed(fully: true))
        let log = MigrationEventLog()
        let plain = FakeLeftoverStore(
            items: MigrationHarness.plaintextFiles(), isEncrypted: false, log: log, gate: MigrationGate())
        await harness.migrator.encryptLeftovers(in: plain)
        #expect(harness.migrator.phase == .idle)
        #expect(log.events.isEmpty)
    }

    @Test("A non-encrypted store while a run exists leaves it as it is: still failed, skip and retry still work")
    func nonEncryptedStoreWhileFailedLeavesRunAlone() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        #expect(harness.migrator.phase == .failed(names: ["c.mov"]))
        let log = MigrationEventLog()
        let plain = FakeLeftoverStore(
            items: MigrationHarness.plaintextFiles(), isEncrypted: false, log: log, gate: MigrationGate())
        await harness.migrator.encryptLeftovers(in: plain)
        #expect(harness.migrator.phase == .failed(names: ["c.mov"]))
        #expect(log.events.isEmpty)
        harness.store.setFailure(nil, for: "c.mov")
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.store.isEncrypted("c.mov") == true)
    }

    @Test("Skip still works after a non-encrypted store was offered while failed")
    func skipAfterNonEncryptedStoreWhileFailed() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        let plain = FakeLeftoverStore(
            items: MigrationHarness.plaintextFiles(), isEncrypted: false, log: MigrationEventLog(),
            gate: MigrationGate())
        await harness.migrator.encryptLeftovers(in: plain)
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .completed(fully: false))
    }
}
