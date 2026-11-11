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
        phase: MigrationPhase = .idle,
        waitsForNewRun: Bool = false
    ) -> Rig {
        let migrator = SettingsScriptedMigrator(phase: phase)
        let sleeper = SettingsManualSleeper()
        let finished = SettingsRecorder<Bool>()
        let viewModel = MigrationViewModel(
            migrator: migrator, waitsForNewRun: waitsForNewRun,
            sleep: { try await sleeper.sleep($0) }, onFinish: { finished.record($0) })
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

    @Test("The title is Encrypting Files")
    func encryptTitle() {
        #expect(makeRig().viewModel.title == "Encrypting Files")
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

    // MARK: - Background time

    @Test("Background time is wanted while the migration is running")
    func wantsBackgroundTimeWhileRunning() async {
        let rig = makeRig(phase: .running(done: 1, total: 4))
        #expect(rig.viewModel.wantsBackgroundTime)
        let task = await startRunning(rig)
        rig.migrator.send(.running(done: 2, total: 4))
        await SettingsTestSupport.waitUntil { rig.viewModel.statusText == "50% complete" }
        #expect(rig.viewModel.wantsBackgroundTime)
        task.cancel()
    }

    @Test(
        "Background time is not wanted once the migration failed or completed",
        arguments: [MigrationPhase.failed(names: ["a.jpg"]), .completed(fully: true)]
    )
    func noBackgroundTimeAfterStopping(phase: MigrationPhase) async {
        let rig = makeRig(phase: .running(done: 1, total: 4))
        let task = await startRunning(rig)
        rig.migrator.send(phase)
        await SettingsTestSupport.waitUntil { !rig.viewModel.wantsBackgroundTime }
        #expect(!rig.viewModel.wantsBackgroundTime)
        task.cancel()
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
        #expect(rig.viewModel.failureMessage == "These files couldn't be encrypted: a.jpg, b.png")
        task.cancel()
    }

    @Test("A single failed file is listed without a separator")
    func singleFailureText() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.failed(names: ["only.mov"]))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureMessage != nil }
        #expect(rig.viewModel.failureMessage == "These files couldn't be encrypted: only.mov")
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

    @Test("Nothing finishes while the migration is running or failed")
    func noFinishBeforeCompletion() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.running(done: 1, total: 4))
        rig.migrator.send(.failed(names: ["a.jpg"]))
        await SettingsTestSupport.settle()
        #expect(rig.sleeper.requestedDurations.isEmpty)
        #expect(rig.finished.values.isEmpty)
        task.cancel()
    }

    @Test("A failure with no file names shows the generic message, with Retry and Skip available")
    func failureWithoutNames() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.failed(names: []))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle != nil }
        #expect(rig.viewModel.failureTitle == "Some Files Failed")
        #expect(rig.viewModel.failureMessage == "Some files couldn't be encrypted.")
        task.cancel()
    }

    @Test("A failure with no file names can still be retried or skipped")
    func failureWithoutNamesRetrySkip() async {
        let rig = makeRig()
        rig.migrator.phaseAfterRetry = .running(done: 0, total: 1)
        let task = await startRunning(rig)
        rig.migrator.send(.failed(names: []))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle != nil }
        await rig.viewModel.retry()
        await rig.viewModel.skip()
        #expect(rig.migrator.calls.contains(.retryFailed))
        #expect(rig.migrator.calls.contains(.skipFailed))
        task.cancel()
    }

    // MARK: - The vault closing

    @Test("Going idle after a run started dismisses at once, reporting not fully")
    func idleAfterRunDismissesAtOnce() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.running(done: 1, total: 4))
        await SettingsTestSupport.waitUntil { rig.viewModel.statusText == "25% complete" }
        rig.migrator.send(.idle)
        await SettingsTestSupport.waitUntil { !rig.finished.values.isEmpty }
        #expect(rig.finished.values == [false])
        #expect(rig.sleeper.requestedDurations.isEmpty)
        task.cancel()
    }

    @Test("Idle before any run started does not dismiss")
    func idleBeforeRunDoesNotDismiss() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.idle)
        await SettingsTestSupport.settle()
        #expect(rig.finished.values.isEmpty)
        task.cancel()
    }

    // MARK: - Running twice

    @Test("A second run while the first is following the migration does nothing")
    func secondRunWhileFollowingDoesNothing() async {
        let rig = makeRig()
        let first = await startRunning(rig)
        let viewModel = rig.viewModel
        let second = Task { await viewModel.run() }
        await SettingsTestSupport.settle()
        #expect(rig.migrator.calls.filter { $0 == .phaseUpdates }.count == 1)
        rig.migrator.send(.completed(fully: true))
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { !rig.finished.values.isEmpty }
        await SettingsTestSupport.settle()
        #expect(rig.finished.values == [true])
        #expect(rig.sleeper.requestedDurations.count == 1)
        first.cancel()
        second.cancel()
    }

    @Test("A second run after the migration finished does not finish again")
    func secondRunAfterFinishDoesNotFinishAgain() async {
        let rig = makeRig(phase: .completed(fully: true))
        let viewModel = rig.viewModel
        let first = Task { await viewModel.run() }
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { !rig.finished.values.isEmpty }
        let second = Task { await viewModel.run() }
        await SettingsTestSupport.settle()
        #expect(rig.sleeper.pendingCount == 0)
        #expect(rig.sleeper.requestedDurations.count == 1)
        #expect(rig.finished.values == [true])
        first.cancel()
        second.cancel()
    }

    // MARK: - Waiting for a new run

    @Test("When waiting for a new run, an old completed phase is ignored and the new run's ends the screen")
    func waitsForNewRunIgnoresOldCompletion() async {
        let rig = makeRig(phase: .completed(fully: true), waitsForNewRun: true)
        let task = await startRunning(rig)
        await SettingsTestSupport.settle()
        #expect(rig.sleeper.requestedDurations.isEmpty)
        #expect(rig.finished.values.isEmpty)
        #expect(rig.viewModel.statusText == "Preparing…")
        rig.migrator.send(.running(done: 1, total: 2))
        await SettingsTestSupport.waitUntil { rig.viewModel.statusText == "50% complete" }
        rig.migrator.send(.completed(fully: false))
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { !rig.finished.values.isEmpty }
        #expect(rig.finished.values == [false])
        task.cancel()
    }

    @Test("When waiting for a new run, a phase already running is shown at once")
    func waitsForNewRunShowsRunningPhase() {
        let rig = makeRig(phase: .running(done: 1, total: 4), waitsForNewRun: true)
        #expect(rig.viewModel.statusText == "25% complete")
    }

    @Test("The live sleep waits for the duration it is given")
    func liveSleepReturns() async throws {
        try await MigrationViewModel.liveSleep(.milliseconds(1))
    }

    @Test("Without a stand-in sleep, a resumed completed migration reports its end once after the real wait")
    func defaultSleepReportsEnd() async {
        let migrator = SettingsScriptedMigrator(phase: .completed(fully: true))
        let finished = SettingsRecorder<Bool>()
        let viewModel = MigrationViewModel(
            migrator: migrator, onFinish: { finished.record($0) })
        let task = Task { await viewModel.run() }
        #expect(finished.values.isEmpty)
        await SettingsTestSupport.waitUntil { !finished.values.isEmpty }
        await task.value
        #expect(finished.values == [true])
    }

    @Test("Without a stand-in sleep, cancelling during the real wait means the end is never reported")
    func defaultSleepCancelled() async {
        let migrator = SettingsScriptedMigrator(phase: .completed(fully: true))
        let finished = SettingsRecorder<Bool>()
        let viewModel = MigrationViewModel(
            migrator: migrator, onFinish: { finished.record($0) })
        let task = Task { await viewModel.run() }
        for _ in 0..<20 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(finished.values.isEmpty)
    }
}

@MainActor
@Suite struct MigrationViewModelTrashTests {
    private struct Rig {
        let viewModel: MigrationViewModel
        let migrator: SettingsScriptedMigrator
    }

    private func makeRig(phase: MigrationPhase = .idle) -> Rig {
        let migrator = SettingsScriptedMigrator(phase: phase)
        let viewModel = MigrationViewModel(
            migrator: migrator, sleep: { _ in }, onFinish: { _ in })
        return Rig(viewModel: viewModel, migrator: migrator)
    }

    private func startRunning(_ rig: Rig) async -> Task<Void, Never> {
        let viewModel = rig.viewModel
        let task = Task { await viewModel.run() }
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        return task
    }

    @Test("Unreadable trash shows the Some Deleted Items Can't Be Read alert")
    func alertText() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.unreadableTrash)
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle != nil }
        #expect(rig.viewModel.failureTitle == "Some Deleted Items Can't Be Read")
        #expect(
            rig.viewModel.failureMessage
                == "They were encrypted with a key this vault no longer has, so they can never be restored "
                + "or opened. Clear them to continue.")
        task.cancel()
    }

    // Assumed property: `isUnreadableTrash` (published Bool), true while the unreadable-trash alert shows.
    @Test("The unreadable-trash alert is told apart from the failed-files alert")
    func alertKind() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.failed(names: ["a.jpg"]))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle != nil }
        #expect(!rig.viewModel.isUnreadableTrash)
        rig.migrator.send(.unreadableTrash)
        await SettingsTestSupport.waitUntil { rig.viewModel.isUnreadableTrash }
        #expect(rig.viewModel.isUnreadableTrash)
        task.cancel()
    }

    @Test("Background time is not wanted while the unreadable-trash alert shows")
    func noBackgroundTime() async {
        let rig = makeRig(phase: .running(done: 1, total: 4))
        #expect(rig.viewModel.wantsBackgroundTime)
        let task = await startRunning(rig)
        rig.migrator.send(.unreadableTrash)
        await SettingsTestSupport.waitUntil { !rig.viewModel.wantsBackgroundTime }
        #expect(!rig.viewModel.wantsBackgroundTime)
        task.cancel()
    }

    @Test("A screen that starts in the unreadable-trash phase shows the alert at once")
    func initialPhase() {
        let viewModel = makeRig(phase: .unreadableTrash).viewModel
        #expect(viewModel.failureTitle == "Some Deleted Items Can't Be Read")
        #expect(viewModel.isUnreadableTrash)
    }

    // Assumed method: `clearAndContinue() async`.
    @Test("Clear and Continue asks the migration to clear the unreadable trash")
    func clearAndContinue() async {
        let rig = makeRig(phase: .unreadableTrash)
        await rig.viewModel.clearAndContinue()
        #expect(rig.migrator.calls.contains(.clearUnreadableTrash))
        #expect(!rig.migrator.calls.contains(.skipFailed))
    }

    @Test("Skip on the unreadable-trash alert skips the failed files")
    func skipOnTrashAlert() async {
        let rig = makeRig(phase: .unreadableTrash)
        await rig.viewModel.skip()
        #expect(rig.migrator.calls.contains(.skipFailed))
        #expect(!rig.migrator.calls.contains(.clearUnreadableTrash))
    }

    @Test("Moving on to running clears the unreadable-trash alert")
    func runningClearsAlert() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.unreadableTrash)
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle != nil }
        rig.migrator.send(.running(done: 1, total: 4))
        await SettingsTestSupport.waitUntil { rig.viewModel.failureTitle == nil }
        #expect(rig.viewModel.failureTitle == nil)
        #expect(rig.viewModel.failureMessage == nil)
        #expect(!rig.viewModel.isUnreadableTrash)
        #expect(rig.viewModel.wantsBackgroundTime)
        task.cancel()
    }

    @Test("Reaching the unreadable-trash phase again shows the alert again")
    func alertReappears() async {
        let rig = makeRig()
        let task = await startRunning(rig)
        rig.migrator.send(.unreadableTrash)
        await SettingsTestSupport.waitUntil { rig.viewModel.isUnreadableTrash }
        rig.migrator.send(.running(done: 1, total: 4))
        await SettingsTestSupport.waitUntil { !rig.viewModel.isUnreadableTrash }
        rig.migrator.send(.unreadableTrash)
        await SettingsTestSupport.waitUntil { rig.viewModel.isUnreadableTrash }
        #expect(rig.viewModel.isUnreadableTrash)
        #expect(rig.viewModel.failureTitle == "Some Deleted Items Can't Be Read")
        task.cancel()
    }
}
