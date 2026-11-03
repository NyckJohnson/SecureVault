import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct MigrationViewModelTests {
    private struct Rig {
        let viewModel: MigrationViewModel
        let migrator: SettingsScriptedMigrator
        let sleeper: SettingsManualSleeper
        let finished: SettingsRecorder<Bool>
    }

    private func makeRig(
        kind: MigrationKind = .encrypt,
        phase: MigrationPhase = .idle
    ) -> Rig {
        let migrator = SettingsScriptedMigrator(phase: phase)
        let sleeper = SettingsManualSleeper()
        let finished = SettingsRecorder<Bool>()
        let viewModel = MigrationViewModel(
            kind: kind, migrator: migrator, sleep: { try await sleeper.sleep($0) },
            onFinish: { finished.record($0) })
        return Rig(viewModel: viewModel, migrator: migrator, sleeper: sleeper, finished: finished)
    }

    /// Starts observing and waits until the view model has subscribed to the phases.
    private func startRunning(_ rig: Rig) async -> Task<Void, Never> {
        let viewModel = rig.viewModel
        let task = Task { await viewModel.run() }
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        return task
    }

    // MARK: - Titles and status

    @Test("The title is Encrypting Files for an encrypt migration")
    func encryptTitle() {
        #expect(makeRig(kind: .encrypt).viewModel.title == "Encrypting Files")
    }

    @Test("The title is Decrypting Files for a decrypt migration")
    func decryptTitle() {
        #expect(makeRig(kind: .decrypt).viewModel.title == "Decrypting Files")
    }

    @Test("Before any progress the status is Preparing…")
    func preparingStatus() {
        #expect(makeRig().viewModel.statusText == "Preparing…")
    }

    @Test(
        "A running phase shows the percentage complete",
        arguments: [(1, 4, "25% complete"), (2, 4, "50% complete"), (3, 4, "75% complete"), (10, 10, "100% complete")]
    )
    func runningStatus(done: Int, total: Int, expected: String) async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.running(done: done, total: total))
        await SettingsTestSupport.waitUntil { rig.viewModel.statusText == expected }
        #expect(rig.viewModel.statusText == expected)
        task.cancel()
    }

    @Test("A paused phase shows Paused — unlock to continue")
    func pausedStatus() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.paused(done: 3, total: 10))
        await SettingsTestSupport.waitUntil { rig.viewModel.statusText == "Paused — unlock to continue" }
        #expect(rig.viewModel.statusText == "Paused — unlock to continue")
        task.cancel()
    }

    @Test("A completed phase shows Complete")
    func completeStatus() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.completed(fully: true))
        await SettingsTestSupport.waitUntil { rig.viewModel.statusText == "Complete" }
        #expect(rig.viewModel.statusText == "Complete")
        task.cancel()
    }

    @Test("The status reflects a phase the migration was already in when the screen appeared")
    func statusFromInitialPhase() {
        let rig = makeRig(phase: .running(done: 1, total: 2))
        #expect(rig.viewModel.statusText == "50% complete")
    }

    // MARK: - Failures

    @Test("No failure is shown while the migration is not failed")
    func noFailureByDefault() {
        let viewModel = makeRig().viewModel
        #expect(viewModel.failureTitle == nil)
        #expect(viewModel.failureMessage == nil)
    }

    @Test("Failed files show Some Files Failed listing the names")
    func failureText() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.failed(names: ["a.jpg", "b.png"]))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle != nil }
        #expect(rig.viewModel.failureTitle == "Some Files Failed")
        #expect(rig.viewModel.failureMessage == "These files couldn't be migrated: a.jpg, b.png")
        task.cancel()
    }

    @Test("A single failed file is listed without a separator")
    func singleFailureText() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.failed(names: ["only.mov"]))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureMessage != nil }
        #expect(rig.viewModel.failureMessage == "These files couldn't be migrated: only.mov")
        task.cancel()
    }

    @Test("The failure goes away when the migration moves on")
    func failureClears() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.failed(names: ["a.jpg"]))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle != nil }
        rig.migrator.send(.running(done: 1, total: 2))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle == nil }
        #expect(rig.viewModel.failureTitle == nil)
        #expect(rig.viewModel.failureMessage == nil)
        task.cancel()
    }

    @Test("Retry asks the migration to retry the failed files")
    func retryRetries() async {
        let rig = makeRig()
        await rig.viewModel.retry()
        #expect(rig.migrator.calls.contains(.retryFailed))
        #expect(!rig.migrator.calls.contains(.skipFailed))
    }

    @Test("Skip asks the migration to skip the failed files")
    func skipSkips() async {
        let rig = makeRig()
        await rig.viewModel.skip()
        #expect(rig.migrator.calls.contains(.skipFailed))
        #expect(!rig.migrator.calls.contains(.retryFailed))
    }

    @Test("Retry that succeeds finishes fully after the delay")
    func retryThenFinishFully() async {
        let rig = makeRig()
        rig.migrator.phaseAfterRetry = .completed(fully: true)
        let task = await startRunning(rig)
        rig.migrator.send(.failed(names: ["a.jpg"]))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle != nil }
        await rig.viewModel.retry()
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { !rig.finished.values.isEmpty }
        #expect(rig.finished.values == [true])
        task.cancel()
    }

    @Test("Skip finishes reporting that the migration did not complete fully")
    func skipThenFinishPartially() async {
        let rig = makeRig()
        rig.migrator.phaseAfterSkip = .completed(fully: false)
        let task = await startRunning(rig)
        rig.migrator.send(.failed(names: ["a.jpg"]))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle != nil }
        await rig.viewModel.skip()
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { !rig.finished.values.isEmpty }
        #expect(rig.finished.values == [false])
        task.cancel()
    }

    // MARK: - Finishing

    @Test(
        "Finishing waits 0.5 s, then reports whether the migration completed fully",
        arguments: [true, false]
    )
    func finishesAfterHalfSecond(fully: Bool) async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.completed(fully: fully))
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        #expect(rig.sleeper.requestedDurations == [.milliseconds(500)])
        #expect(rig.finished.values.isEmpty)
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { !rig.finished.values.isEmpty }
        #expect(rig.finished.values == [fully])
        task.cancel()
    }

    @Test("A migration that already completed when the screen appeared still finishes")
    func alreadyCompletedStillFinishes() async {
        let rig = makeRig(phase: .completed(fully: true))
        let viewModel = rig.viewModel
        let task = Task { await viewModel.run() }
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { !rig.finished.values.isEmpty }
        #expect(rig.finished.values == [true])
        task.cancel()
    }

    @Test("Paused, running, then completed finishes exactly once")
    func pausedRunningCompletedFinishesOnce() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.running(done: 1, total: 4))
        rig.migrator.send(.paused(done: 1, total: 4))
        rig.migrator.send(.running(done: 2, total: 4))
        rig.migrator.send(.completed(fully: true))
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { !rig.finished.values.isEmpty }
        await SettingsTestSupport.settle()
        #expect(rig.finished.values == [true])
        task.cancel()
    }

    @Test("Nothing finishes while the migration is running, paused or failed")
    func noFinishBeforeCompletion() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.running(done: 1, total: 4))
        rig.migrator.send(.paused(done: 1, total: 4))
        rig.migrator.send(.failed(names: ["a.jpg"]))
        await SettingsTestSupport.settle()
        #expect(rig.sleeper.requestedDurations.isEmpty)
        #expect(rig.finished.values.isEmpty)
        task.cancel()
    }

    @Test("The live sleep waits for the duration it is given")
    func liveSleepReturns() async throws {
        try await MigrationViewModel.liveSleep(.milliseconds(1))
    }
}
