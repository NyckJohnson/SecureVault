import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct LiveLockMigratorCancelTests {
    private func isFailed(_ phase: MigrationPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    @Test("Cancel stops the run after the file in progress, which is not counted; the phase is idle")
    func cancelStopsAfterFileInProgress() async {
        let harness = MigrationHarness()
        let recorder = harness.recorder()
        harness.gate.arm(at: "migrate:b.pdf")
        let task = Task { await harness.run() }
        #expect(await waitForCondition { harness.gate.hasReached("migrate:b.pdf") })
        harness.migrator.cancel()
        harness.gate.release()
        await task.value
        await recorder.finish()
        #expect(harness.migrator.phase == .idle)
        #expect(recorder.phases.last == .idle)
        #expect(!recorder.phases.contains(.running(done: 2, total: 4)))
        #expect(harness.log.count(of: "enc:c.mov") == 0)
        #expect(harness.log.count(of: "enc:Old.txt") == 0)
        #expect(harness.log.count(of: "finishEncryption") == 0)
    }

    @Test("A file in progress that fails during cancel does not turn the phase into failed")
    func cancelWithFailingFileInProgress() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "b.pdf")
        let recorder = harness.recorder()
        harness.gate.arm(at: "migrate:b.pdf")
        let task = Task { await harness.run() }
        #expect(await waitForCondition { harness.gate.hasReached("migrate:b.pdf") })
        harness.migrator.cancel()
        harness.gate.release()
        await task.value
        await recorder.finish()
        #expect(harness.migrator.phase == .idle)
        #expect(!recorder.phases.contains(where: isFailed))
    }

    @Test("Cancel while idle leaves the phase idle")
    func cancelWhileIdle() {
        let harness = MigrationHarness()
        harness.migrator.cancel()
        #expect(harness.migrator.phase == .idle)
    }

    @Test("Cancel while failed returns the phase to idle")
    func cancelWhileFailed() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        harness.migrator.cancel()
        #expect(harness.migrator.phase == .idle)
    }

    @Test("After a cancel, opening the vault again encrypts what is left")
    func runAgainAfterCancel() async {
        let harness = MigrationHarness()
        harness.gate.arm(at: "migrate:a.jpg")
        let task = Task { await harness.run() }
        #expect(await waitForCondition { harness.gate.hasReached("migrate:a.jpg") })
        harness.migrator.cancel()
        harness.gate.release()
        await task.value
        #expect(harness.migrator.phase == .idle)
        await harness.run()
        #expect(harness.migrator.phase == .completed(fully: true))
        for name in MigrationHarness.names { #expect(harness.store.isEncrypted(name) == true) }
    }

    @Test("A locked error from a file ends the run as cancel does: idle, no further files, not failed")
    func lockedDuringFile() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.locked, for: "b.pdf")
        let recorder = harness.recorder()
        await harness.run()
        await recorder.finish()
        #expect(harness.migrator.phase == .idle)
        #expect(!recorder.phases.contains(where: isFailed))
        #expect(harness.log.count(of: "enc:c.mov") == 0)
        #expect(harness.log.count(of: "finishEncryption") == 0)
    }

    @Test("A locked error from the listing ends the run idle")
    func lockedDuringListing() async {
        let harness = MigrationHarness()
        harness.store.setListingFailure(.locked)
        await harness.run()
        #expect(harness.migrator.phase == .idle)
    }

    @Test("A locked error from finishEncryption ends the run idle, not failed")
    func lockedDuringFinish() async {
        let harness = MigrationHarness()
        harness.store.setFinishFailure(.locked)
        await harness.run()
        #expect(harness.migrator.phase == .idle)
    }

    @Test("UITEST_FAIL_MIGRATION_FILE makes the named file fail")
    func uiTestFailFile() async {
        let harness = MigrationHarness(uiTestFailFileName: "b.pdf")
        await harness.run()
        #expect(harness.migrator.phase == .failed(names: ["b.pdf"]))
        #expect(harness.store.isEncrypted("b.pdf") == false)
        #expect(harness.store.isEncrypted("a.jpg") == true)
        #expect(harness.store.isEncrypted("c.mov") == true)
    }

    @Test("The UI-test failing file fails again on every retry")
    func uiTestFailFileFailsOnRetry() async {
        let harness = MigrationHarness(uiTestFailFileName: "b.pdf")
        await harness.run()
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .failed(names: ["b.pdf"]))
        #expect(harness.store.isEncrypted("b.pdf") == false)
    }

    @Test("Without UITEST_FAIL_MIGRATION_FILE no file fails")
    func noUITestFailFile() async {
        let harness = MigrationHarness()
        await harness.run()
        #expect(harness.migrator.phase == .completed(fully: true))
    }
}
