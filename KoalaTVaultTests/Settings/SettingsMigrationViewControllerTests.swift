import Testing
import UIKit

@testable import KoalaTVault

/// Contract for the view (the code-writer must match it):
/// ```
/// @MainActor protocol BackgroundTimeProviding: AnyObject {
///     func beginBackgroundTask(withName taskName: String?, expirationHandler handler: (() -> Void)?) -> UIBackgroundTaskIdentifier
///     func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
/// }   // declared in Views/MigrationViewController.swift; `UIApplication` conforms in the same file
/// MigrationViewController(migrator: any LockMigrating, waitsForNewRun: Bool = false,
///     sleep: @escaping @Sendable (Duration) async throws -> Void = MigrationViewModel.liveSleep,
///     backgroundTime: any BackgroundTimeProviding = UIApplication.shared,
///     onFinish: @escaping @MainActor (Bool) -> Void)
/// ```
/// Identifiers follow the journey tests: `migration.titleLabel`, `migration.statusLabel`, `migration.progressBar`.
@MainActor
@Suite struct SettingsMigrationViewControllerTests {
    private struct Rig {
        let host: SettingsViewHost
        let migrator: SettingsScriptedMigrator
        let sleeper: SettingsManualSleeper
        let background: SettingsFakeBackgroundTime
        let finished: SettingsRecorder<Bool>
    }

    private func makeRig(phase: MigrationPhase = .idle) -> Rig {
        let migrator = SettingsScriptedMigrator(phase: phase)
        let sleeper = SettingsManualSleeper()
        let background = SettingsFakeBackgroundTime()
        let finished = SettingsRecorder<Bool>()
        let controller = MigrationViewController(
            migrator: migrator, sleep: { try await sleeper.sleep($0) }, backgroundTime: background,
            onFinish: { finished.record($0) })
        let host = SettingsViewHost.presenting(controller)
        return Rig(host: host, migrator: migrator, sleeper: sleeper, background: background, finished: finished)
    }

    private func label(_ id: String, _ rig: Rig) -> String? { (rig.host.element(id) as? UILabel)?.text }

    private func status(_ rig: Rig) -> String? { label("migration.statusLabel", rig) }

    // MARK: - Content

    @Test("An encrypt migration is titled Encrypting Files and starts at Preparing…")
    func encryptContent() async {
        let rig = makeRig()
        #expect(label("migration.titleLabel", rig) == "Encrypting Files")
        #expect(status(rig) == "Preparing…")
        #expect((rig.host.element("migration.progressBar") as? UIProgressView)?.progress == 0)
    }

    @Test("Running progress shows N% complete and moves the progress bar")
    func runningProgress() async {
        let rig = makeRig()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.running(done: 5, total: 10))
        await SettingsTestSupport.waitUntil { self.status(rig) == "50% complete" }
        #expect(status(rig) == "50% complete")
        #expect((rig.host.element("migration.progressBar") as? UIProgressView)?.progress == 0.5)
    }

    // MARK: - Failure alert

    @Test("Failed files show the Some Files Failed alert naming them, with Retry and Skip")
    func failureAlert() async throws {
        let rig = makeRig()
        rig.migrator.send(.failed(names: ["a.txt", "b.txt"]))
        let alert = try #require(await rig.host.alert())
        #expect(alert.title == "Some Files Failed")
        #expect(alert.message == "These files couldn't be encrypted: a.txt, b.txt")
        #expect(alert.actionTitles == ["Retry", "Skip"])
    }

    @Test("Retry in the failure alert asks the migrator to retry")
    func retryForwarded() async throws {
        let rig = makeRig()
        rig.migrator.send(.failed(names: ["a.txt"]))
        try #require(await rig.host.alert()).fire("Retry")
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.retryFailed) }
        #expect(rig.migrator.calls.contains(.retryFailed))
    }

    @Test("Skip in the failure alert asks the migrator to skip")
    func skipForwarded() async throws {
        let rig = makeRig()
        rig.migrator.send(.failed(names: ["a.txt"]))
        try #require(await rig.host.alert()).fire("Skip")
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.skipFailed) }
        #expect(rig.migrator.calls.contains(.skipFailed))
    }

    // MARK: - Finishing

    @Test("A full completion shows Complete, then dismisses and reports onFinish(true) once")
    func completesFully() async {
        let rig = makeRig()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.completed(fully: true))
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        #expect(status(rig) == "Complete")
        #expect(rig.finished.values.isEmpty)
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { rig.host.root.presentedViewController == nil }
        #expect(rig.finished.values == [true])
        #expect(rig.host.root.presentedViewController == nil)
    }

    @Test("An incomplete finish (Skip) dismisses and reports onFinish(false)")
    func completesPartially() async {
        let rig = makeRig()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.completed(fully: false))
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { !rig.finished.values.isEmpty }
        #expect(rig.finished.values == [false])
        await SettingsTestSupport.waitUntil { rig.host.root.presentedViewController == nil }
        #expect(rig.host.root.presentedViewController == nil)
    }

    @Test("The screen waits half a second after completing before it goes away")
    func waitsHalfSecond() async {
        let rig = makeRig()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.completed(fully: true))
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        #expect(rig.sleeper.requestedDurations == [.milliseconds(500)])
        rig.sleeper.advance()
    }

    @Test("Completion already reached when resuming still dismisses and reports")
    func alreadyCompleted() async {
        let rig = makeRig(phase: .completed(fully: true))
        await SettingsTestSupport.waitUntil { rig.sleeper.pendingCount == 1 }
        rig.sleeper.advance()
        await SettingsTestSupport.waitUntil { rig.host.root.presentedViewController == nil }
        #expect(rig.finished.values == [true])
    }

    // MARK: - Background time

    @Test("Background time is requested once while running, however many progress updates arrive")
    func backgroundWhileRunning() async {
        let rig = makeRig()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.running(done: 1, total: 10))
        await SettingsTestSupport.waitUntil { rig.background.begun.count == 1 }
        rig.migrator.send(.running(done: 2, total: 10))
        await SettingsTestSupport.waitUntil { self.status(rig) == "20% complete" }
        #expect(rig.background.begun.count == 1)
        #expect(rig.background.ended.isEmpty)
    }

    @Test("Background time is not requested before anything runs")
    func noBackgroundWhenIdle() async {
        let rig = makeRig()
        await SettingsTestSupport.settle()
        #expect(rig.background.begun.isEmpty)
    }

    @Test("A failure ends the background task, and running again begins a new one")
    func failureEndsThenRunningBeginsAgain() async {
        let rig = makeRig()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.running(done: 1, total: 10))
        await SettingsTestSupport.waitUntil { rig.background.begun.count == 1 }
        rig.migrator.send(.failed(names: ["a"]))
        await SettingsTestSupport.waitUntil { rig.background.ended.count == 1 }
        rig.migrator.send(.running(done: 2, total: 10))
        await SettingsTestSupport.waitUntil { rig.background.begun.count == 2 }
        #expect(rig.background.begun.count == 2)
        #expect(rig.background.openCount == 1)
    }

    @Test("Completing ends the background task")
    func completionEndsBackground() async {
        let rig = makeRig()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.running(done: 9, total: 10))
        await SettingsTestSupport.waitUntil { rig.background.begun.count == 1 }
        rig.migrator.send(.completed(fully: true))
        await SettingsTestSupport.waitUntil { rig.background.openCount == 0 }
        #expect(rig.background.openCount == 0)
        rig.sleeper.advance()
    }

    @Test("When the system expires the background task, the task is ended")
    func expirationEndsBackground() async throws {
        let rig = makeRig()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.running(done: 1, total: 10))
        await SettingsTestSupport.waitUntil { rig.background.begun.count == 1 }
        let expire = try #require(rig.background.expirationHandlers.first)
        expire()
        await SettingsTestSupport.waitUntil { rig.background.ended.count == 1 }
        #expect(rig.background.ended == rig.background.begun)
    }
}

/// Views of the migration screen's unreadable-trash alert (spec: MigrationViewModel, unreadable trash).
@MainActor
@Suite struct SettingsMigrationUnreadableTrashTests {
    private static let title = "Some Deleted Items Can't Be Read"
    private static let message =
        "They were encrypted with a key this vault no longer has, so they can never be restored or opened. "
        + "Clear them to continue."

    private struct Rig {
        let host: SettingsViewHost
        let migrator: SettingsScriptedMigrator
    }

    private func makeRig() -> Rig {
        let migrator = SettingsScriptedMigrator()
        let controller = MigrationViewController(
            migrator: migrator, sleep: { _ in }, backgroundTime: SettingsFakeBackgroundTime(),
            onFinish: { _ in })
        return Rig(host: SettingsViewHost.presenting(controller), migrator: migrator)
    }

    private func reachUnreadableTrash(_ rig: Rig) async {
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.unreadableTrash)
    }

    @Test("Unreadable trash shows the alert with the spec's title and message")
    func alertWording() async throws {
        let rig = makeRig()
        await reachUnreadableTrash(rig)
        let alert = try #require(await rig.host.alert())
        #expect(alert.title == Self.title)
        #expect(alert.message == Self.message)
    }

    @Test("The unreadable-trash alert offers exactly Clear and Continue and Skip, with no Retry")
    func alertActions() async throws {
        let rig = makeRig()
        await reachUnreadableTrash(rig)
        let alert = try #require(await rig.host.alert())
        #expect(alert.actionTitles == ["Clear and Continue", "Skip"])
    }

    @Test("Clear and Continue asks the migrator to clear the unreadable trash")
    func clearForwarded() async throws {
        let rig = makeRig()
        await reachUnreadableTrash(rig)
        try #require(await rig.host.alert()).fire("Clear and Continue")
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.clearUnreadableTrash) }
        #expect(rig.migrator.calls.contains(.clearUnreadableTrash))
        #expect(!rig.migrator.calls.contains(.skipFailed))
    }

    @Test("Skip in the unreadable-trash alert asks the migrator to skip")
    func skipForwarded() async throws {
        let rig = makeRig()
        await reachUnreadableTrash(rig)
        try #require(await rig.host.alert()).fire("Skip")
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.skipFailed) }
        #expect(rig.migrator.calls.contains(.skipFailed))
        #expect(!rig.migrator.calls.contains(.clearUnreadableTrash))
    }

    @Test("Going from unreadable trash back to running takes the alert away")
    func runningDismissesAlert() async throws {
        let rig = makeRig()
        await reachUnreadableTrash(rig)
        _ = try #require(await rig.host.alert())
        rig.migrator.send(.running(done: 1, total: 10))
        await SettingsTestSupport.waitUntil { !(rig.host.topmost is UIAlertController) }
        #expect(!(rig.host.topmost is UIAlertController))
    }

    @Test("Reaching unreadable trash again shows the alert again")
    func reappears() async throws {
        let rig = makeRig()
        await reachUnreadableTrash(rig)
        _ = try #require(await rig.host.alert())
        rig.migrator.send(.running(done: 1, total: 10))
        await SettingsTestSupport.waitUntil { !(rig.host.topmost is UIAlertController) }
        rig.migrator.send(.unreadableTrash)
        let again = try #require(await rig.host.alert())
        #expect(again.title == Self.title)
        #expect(again.actionTitles == ["Clear and Continue", "Skip"])
    }

    @Test("The failed-files alert still offers Retry and Skip")
    func failedFilesUnchanged() async throws {
        let rig = makeRig()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.failed(names: ["a.txt"]))
        let alert = try #require(await rig.host.alert())
        #expect(alert.title == "Some Files Failed")
        #expect(alert.actionTitles == ["Retry", "Skip"])
    }
}
