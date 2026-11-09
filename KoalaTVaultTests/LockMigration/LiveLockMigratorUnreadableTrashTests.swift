import Foundation
import Testing

@testable import KoalaTVault

// Feature device-fixes: Retry publishes `.running` before redoing a step, and unreadable trash stops the run in
// `.unreadableTrash` until the user clears it (or skips).

@MainActor
private final class TrashPhaseRecorder {
    private(set) var phases: [MigrationPhase] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<MigrationPhase>) {
        task = Task { [weak self] in
            for await phase in stream { self?.phases.append(phase) }
        }
    }

    func stop() async {
        try? await Task.sleep(for: .milliseconds(50))
        task?.cancel()
    }

    var runningCount: Int {
        phases.filter {
            if case .running = $0 { return true }
            return false
        }.count
    }
}

private func isRunningPhase(_ phase: MigrationPhase) -> Bool {
    if case .running = phase { return true }
    return false
}

@MainActor private func encryptHarness(lockMode: LockMode = .password) -> MigrationHarness {
    MigrationHarness(files: MigrationHarness.sampleFiles(encrypted: false), lockMode: lockMode)
}

@MainActor private func decryptHarness() -> MigrationHarness {
    MigrationHarness(files: MigrationHarness.sampleFiles(encrypted: true), lockMode: .password)
}

/// Where a run would publish `.failed`, for both kinds of migration.
enum TrashFailurePoint: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case listing
    case decryptRescan
    case finishDecryption
    case removeKeys
    case failedFiles

    var testDescription: String { rawValue }

    var isDecryptOnly: Bool { self != .listing && self != .failedFiles }
}

struct TrashScenario: CustomTestStringConvertible, Sendable {
    let kind: MigrationKind
    let point: TrashFailurePoint
    var testDescription: String { "\(kind.rawValue) / \(point.rawValue)" }

    static let all: [TrashScenario] = {
        var result: [TrashScenario] = []
        for point in TrashFailurePoint.allCases {
            result.append(TrashScenario(kind: .decrypt, point: point))
            if !point.isDecryptOnly { result.append(TrashScenario(kind: .encrypt, point: point)) }
        }
        return result
    }()

    @MainActor func harness() -> MigrationHarness {
        kind == .encrypt ? encryptHarness() : decryptHarness()
    }

    /// Makes the run hit the failure point.
    @MainActor func inject(_ harness: MigrationHarness) {
        switch point {
        case .listing: harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        case .decryptRescan: harness.store.setListingFailure(.io("rescan"), fromListing: 2)
        case .finishDecryption: harness.store.setFailure(.io("index"), forStep: .finishDecryption)
        case .removeKeys: harness.lock.setFailure(.keychain(-25_300), forStep: .removeKeysAfterDecryption)
        case .failedFiles: harness.store.setFailure(.io("bad file"), for: "b.pdf")
        }
    }

    /// Removes the failure again so that a continued run can finish.
    @MainActor func heal(_ harness: MigrationHarness) {
        switch point {
        case .listing: harness.store.setFailure(nil, forStep: .itemsToMigrate)
        case .decryptRescan: harness.store.setListingFailure(nil)
        case .finishDecryption: harness.store.setFailure(nil, forStep: .finishDecryption)
        case .removeKeys: harness.lock.setFailure(nil, forStep: .removeKeysAfterDecryption)
        case .failedFiles: harness.store.setFailure(nil, for: "b.pdf")
        }
    }

    var expectedFailed: MigrationPhase {
        .failed(names: point == .failedFiles ? ["b.pdf"] : [])
    }

    var target: LockMode? { kind == .encrypt ? .password : nil }

    @MainActor func run(_ harness: MigrationHarness) async {
        await harness.migrator.start(kind, target: target)
    }
}

// MARK: - Retry publishes running

@MainActor
@Suite struct MigratorRetryRunningTests {
    @Test("A listing failure repeated after Retry publishes running and then failed again")
    func repeatedListingFailureIsPublished() async {
        let harness = encryptHarness()
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        let recorder = TrashPhaseRecorder(harness.migrator.phaseUpdates())
        await harness.migrator.start(.encrypt, target: .password)
        await harness.migrator.retryFailed()
        await recorder.stop()
        let afterFirstFailed = recorder.phases.drop { $0 != .failed(names: []) }.dropFirst()
        #expect(afterFirstFailed.contains(where: isRunningPhase))
        #expect(recorder.phases.filter { $0 == .failed(names: []) }.count == 2)
        #expect(recorder.phases.last == .failed(names: []))
        #expect(harness.migrator.phase == .failed(names: []))
    }

    @Test("A finishDecryption failure repeated after Retry publishes running and then failed again")
    func repeatedFinishDecryptionFailureIsPublished() async {
        let harness = decryptHarness()
        harness.store.setFailure(.io("index"), forStep: .finishDecryption)
        let recorder = TrashPhaseRecorder(harness.migrator.phaseUpdates())
        await harness.migrator.start(.decrypt, target: nil)
        await harness.migrator.retryFailed()
        await recorder.stop()
        let afterFirstFailed = recorder.phases.drop { $0 != .failed(names: []) }.dropFirst()
        #expect(afterFirstFailed.contains(where: isRunningPhase))
        #expect(recorder.phases.filter { $0 == .failed(names: []) }.count == 2)
        #expect(harness.migrator.phase == .failed(names: []))
    }

    @Test("A removeKeysAfterDecryption failure repeated after Retry publishes running and then failed again")
    func repeatedRemoveKeysFailureIsPublished() async {
        let harness = decryptHarness()
        harness.lock.setFailure(.keychain(-25_300), forStep: .removeKeysAfterDecryption)
        let recorder = TrashPhaseRecorder(harness.migrator.phaseUpdates())
        await harness.migrator.start(.decrypt, target: nil)
        await harness.migrator.retryFailed()
        await recorder.stop()
        let afterFirstFailed = recorder.phases.drop { $0 != .failed(names: []) }.dropFirst()
        #expect(afterFirstFailed.contains(where: isRunningPhase))
        #expect(recorder.phases.filter { $0 == .failed(names: []) }.count == 2)
        #expect(harness.migrator.phase == .failed(names: []))
        #expect(harness.log.count(of: "removeKeys") == 2)
    }

    @Test("A third Retry publishes running and failed again each time")
    func everyRepeatedFailureIsPublished() async {
        let harness = encryptHarness()
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        let recorder = TrashPhaseRecorder(harness.migrator.phaseUpdates())
        await harness.migrator.start(.encrypt, target: .password)
        await harness.migrator.retryFailed()
        await harness.migrator.retryFailed()
        await recorder.stop()
        #expect(recorder.phases.filter { $0 == .failed(names: []) }.count == 3)
        #expect(recorder.runningCount >= 2)
    }
}

// MARK: - Detecting unreadable trash

@MainActor
@Suite struct MigratorTrashDetectionTests {
    @Test("Where the run would fail, unreadable trash publishes unreadableTrash instead", arguments: TrashScenario.all)
    func unreadableTrashReplacesFailed(scenario: TrashScenario) async {
        let harness = scenario.harness()
        harness.store.hasUnreadableTrashFlag = true
        scenario.inject(harness)
        await scenario.run(harness)
        #expect(harness.migrator.phase == .unreadableTrash)
        #expect(harness.migrator.pending != nil)
        #expect(harness.preferences.pendingMigration != nil)
        #expect(harness.log.events.contains("hasUnreadableTrash"))
    }

    @Test("Without unreadable trash the run still publishes failed", arguments: TrashScenario.all)
    func withoutUnreadableTrashStillFailed(scenario: TrashScenario) async {
        let harness = scenario.harness()
        harness.store.hasUnreadableTrashFlag = false
        scenario.inject(harness)
        await scenario.run(harness)
        #expect(harness.migrator.phase == scenario.expectedFailed)
        #expect(harness.migrator.pending != nil)
    }

    @Test("unreadableTrash is published to subscribers and never followed by completed")
    func unreadableTrashIsPublished() async {
        let harness = encryptHarness()
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        let recorder = TrashPhaseRecorder(harness.migrator.phaseUpdates())
        await harness.migrator.start(.encrypt, target: .password)
        await recorder.stop()
        #expect(recorder.phases.last == .unreadableTrash)
        #expect(!recorder.phases.contains(.failed(names: [])))
    }

    @Test("A retry that fails again with unreadable trash present ends in unreadableTrash")
    func retryFailureWithUnreadableTrash() async {
        let harness = encryptHarness()
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        #expect(harness.migrator.phase == .failed(names: []))
        harness.store.hasUnreadableTrashFlag = true
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .unreadableTrash)
    }
}

// MARK: - While unreadableTrash

@MainActor
@Suite struct MigratorWhileTrashTests {
    /// A run stopped in `.unreadableTrash`, with the cause healed so that any wrongly acting call would progress.
    private func stopped(_ kind: MigrationKind) async -> MigrationHarness {
        let scenario = TrashScenario(kind: kind, point: .listing)
        let harness = scenario.harness()
        harness.store.hasUnreadableTrashFlag = true
        scenario.inject(harness)
        await scenario.run(harness)
        scenario.heal(harness)
        return harness
    }

    @Test("start does nothing while unreadableTrash", arguments: [MigrationKind.encrypt, .decrypt])
    func startIgnored(kind: MigrationKind) async {
        let harness = await stopped(kind)
        let eventsBefore = harness.log.events
        await harness.migrator.start(kind, target: kind == .encrypt ? .password : nil)
        #expect(harness.migrator.phase == .unreadableTrash)
        #expect(harness.log.events == eventsBefore)
    }

    @Test("resumeIfPending does nothing while unreadableTrash", arguments: [MigrationKind.encrypt, .decrypt])
    func resumeIgnored(kind: MigrationKind) async {
        let harness = await stopped(kind)
        let eventsBefore = harness.log.events
        await harness.migrator.resumeIfPending()
        #expect(harness.migrator.phase == .unreadableTrash)
        #expect(harness.log.events == eventsBefore)
    }

    @Test("retryFailed does nothing while unreadableTrash", arguments: [MigrationKind.encrypt, .decrypt])
    func retryIgnored(kind: MigrationKind) async {
        let harness = await stopped(kind)
        let eventsBefore = harness.log.events
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .unreadableTrash)
        #expect(harness.log.events == eventsBefore)
    }

    @Test("Skip from unreadableTrash after a decrypt completes not fully and keeps the lock and keys")
    func skipDecrypt() async {
        let harness = await stopped(.decrypt)
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .completed(fully: false))
        #expect(harness.migrator.pending == nil)
        #expect(harness.preferences.pendingMigration == nil)
        #expect(harness.lock.lockMode == .password)
        #expect(harness.log.events.contains("removeKeys") == false)
    }

    @Test("Skip from unreadableTrash after an encrypt completes not fully and keeps the target lock mode")
    func skipEncrypt() async {
        let harness = encryptHarness(lockMode: .password)
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
        #expect(harness.migrator.phase == .unreadableTrash)
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .completed(fully: false))
        #expect(harness.migrator.pending == nil)
        #expect(harness.preferences.pendingMigration == nil)
        #expect(harness.lock.lockMode == .passwordAndBiometrics)
    }

    @Test("Skip from unreadableTrash does not clear the trash")
    func skipDoesNotClear() async {
        let harness = await stopped(.decrypt)
        await harness.migrator.skipFailed()
        #expect(harness.log.count(of: "clearUnreadableTrash") == 0)
    }
}

// MARK: - clearUnreadableTrash

@MainActor
@Suite struct MigratorClearTrashTests {
    @Test("clearUnreadableTrash from idle does nothing and never calls the store")
    func noOpFromIdle() async {
        let harness = encryptHarness()
        await harness.migrator.clearUnreadableTrash()
        #expect(harness.migrator.phase == .idle)
        #expect(harness.log.events.isEmpty)
    }

    @Test("clearUnreadableTrash from failed does nothing and never calls the store")
    func noOpFromFailed() async {
        let harness = encryptHarness()
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        let eventsBefore = harness.log.events
        await harness.migrator.clearUnreadableTrash()
        #expect(harness.migrator.phase == .failed(names: []))
        #expect(harness.log.events == eventsBefore)
        #expect(harness.log.count(of: "clearUnreadableTrash") == 0)
    }

    @Test("clearUnreadableTrash from completed does nothing and never calls the store")
    func noOpFromCompleted() async {
        let harness = encryptHarness()
        await harness.migrator.start(.encrypt, target: .password)
        #expect(harness.migrator.phase == .completed(fully: true))
        let eventsBefore = harness.log.events
        await harness.migrator.clearUnreadableTrash()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.log.events == eventsBefore)
    }

    @Test("clearUnreadableTrash from paused does nothing and never calls the store")
    func noOpFromPaused() async {
        let harness = encryptHarness()
        harness.gate.arm(at: "migrate:c.mov")
        let task = Task { await harness.migrator.start(.encrypt, target: .password) }
        _ = await waitUntil { harness.gate.hasReached("migrate:c.mov") }
        harness.lock.wipeKey()
        harness.gate.release()
        await task.value
        guard case .paused = harness.migrator.phase else {
            Issue.record("Expected paused, got \(harness.migrator.phase)")
            return
        }
        await harness.migrator.clearUnreadableTrash()
        guard case .paused = harness.migrator.phase else {
            Issue.record("Expected paused, got \(harness.migrator.phase)")
            return
        }
        #expect(harness.log.count(of: "clearUnreadableTrash") == 0)
    }

    @Test("Clearing publishes running, clears once, and an encrypt then completes fully with the target applied")
    func clearThenEncryptCompletes() async {
        let harness = encryptHarness(lockMode: .password)
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
        #expect(harness.migrator.phase == .unreadableTrash)
        harness.store.setFailure(nil, forStep: .itemsToMigrate)
        let recorder = TrashPhaseRecorder(harness.migrator.phaseUpdates())
        await harness.migrator.clearUnreadableTrash()
        await recorder.stop()
        let afterStop = recorder.phases.drop { $0 != .unreadableTrash }.dropFirst()
        #expect(afterStop.contains(where: isRunningPhase) || recorder.runningCount > 0)
        #expect(harness.log.count(of: "clearUnreadableTrash") == 1)
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.migrator.pending == nil)
        #expect(harness.preferences.pendingMigration == nil)
        #expect(harness.lock.lockMode == .passwordAndBiometrics)
        for name in MigrationHarness.names {
            #expect(harness.store.isEncrypted(name) == true)
        }
    }

    @Test("Clearing runs before the fresh listing")
    func clearBeforeListing() async {
        let harness = encryptHarness()
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        harness.store.setFailure(nil, forStep: .itemsToMigrate)
        await harness.migrator.clearUnreadableTrash()
        let clearIndex = harness.log.index(of: "clearUnreadableTrash")
        let lastListing = harness.log.lastIndex(of: "list:enc")
        #expect(clearIndex != nil)
        #expect(lastListing != nil)
        if let clearIndex, let lastListing { #expect(clearIndex < lastListing) }
    }

    @Test("After clearing, a decrypt re-lists, re-scans, runs the closing steps and completes fully")
    func clearThenDecryptCompletes() async {
        let harness = decryptHarness()
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("bad file"), for: "b.pdf")
        await harness.migrator.start(.decrypt, target: nil)
        #expect(harness.migrator.phase == .unreadableTrash)
        harness.store.setFailure(nil, for: "b.pdf")
        await harness.migrator.clearUnreadableTrash()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.log.count(of: "clearUnreadableTrash") == 1)
        #expect(harness.migrator.pending == nil)
        #expect(harness.preferences.pendingMigration == nil)
        #expect(harness.lock.lockMode == .none)
        for name in MigrationHarness.names {
            #expect(harness.store.isEncrypted(name) == false)
        }
        // Files migrated before the stop are not migrated again; the failed one is retried once.
        #expect(harness.log.count(of: "dec:a.jpg") == 1)
        #expect(harness.log.count(of: "dec:c.mov") == 1)
        #expect(harness.log.count(of: "dec:b.pdf") == 2)
        // The re-scan (a further listing after the fresh one) and the closing steps ran.
        #expect(harness.log.count(of: "list:dec") >= 3)
        #expect(harness.log.count(of: "finishDecryption") == 1)
        #expect(harness.log.count(of: "removeKeys") == 1)
        if let finish = harness.log.index(of: "finishDecryption"), let remove = harness.log.index(of: "removeKeys") {
            #expect(finish < remove)
        }
    }

    @Test("Clearing after an unreadable-trash stop at finishDecryption continues to the closing steps")
    func clearThenDecryptClosingStep() async {
        let harness = decryptHarness()
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("index"), forStep: .finishDecryption)
        await harness.migrator.start(.decrypt, target: nil)
        #expect(harness.migrator.phase == .unreadableTrash)
        harness.store.setFailure(nil, forStep: .finishDecryption)
        await harness.migrator.clearUnreadableTrash()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.lock.lockMode == .none)
        #expect(harness.migrator.pending == nil)
        #expect(harness.log.count(of: "dec:a.jpg") == 1)
    }

    @Test("A failure while clearing (not a lock) reports failed with no names and keeps the pending record")
    func clearingFailureReportsFailed() async {
        let harness = encryptHarness()
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        harness.store.setFailure(nil, forStep: .itemsToMigrate)
        harness.store.setClearFailure(.io("cannot clear"))
        await harness.migrator.clearUnreadableTrash()
        #expect(harness.migrator.phase == .failed(names: []))
        #expect(harness.migrator.pending == PendingMigration(kind: .encrypt, targetLockMode: .password))
        #expect(harness.log.count(of: "clearUnreadableTrash") == 1)
    }

    @Test("A lock during clearing pauses the migration")
    func lockDuringClearingPauses() async {
        let harness = encryptHarness()
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        harness.store.setFailure(nil, forStep: .itemsToMigrate)
        harness.gate.arm(at: "clearUnreadableTrash")
        let task = Task { await harness.migrator.clearUnreadableTrash() }
        #expect(await waitUntil { harness.gate.hasReached("clearUnreadableTrash") })
        harness.lock.wipeKey()
        harness.gate.release()
        await task.value
        guard case .paused = harness.migrator.phase else {
            Issue.record("Expected paused, got \(harness.migrator.phase)")
            return
        }
        #expect(harness.migrator.pending != nil)
        // After the next unlock a fresh listing is made and the run completes.
        let listingsBefore = harness.log.count(of: "list:enc")
        harness.lock.restoreKey()
        await harness.migrator.resumeIfPending()
        #expect(harness.log.count(of: "list:enc") > listingsBefore)
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.migrator.pending == nil)
    }

    @Test("After a lock during clearing, resuming with the trash still unreadable returns to unreadableTrash")
    func resumeAfterLockStillUnreadable() async {
        let harness = encryptHarness()
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        harness.gate.arm(at: "clearUnreadableTrash")
        harness.store.setClearFailure(.io("cannot clear"))
        let task = Task { await harness.migrator.clearUnreadableTrash() }
        #expect(await waitUntil { harness.gate.hasReached("clearUnreadableTrash") })
        harness.lock.wipeKey()
        harness.gate.release()
        await task.value
        guard case .paused = harness.migrator.phase else {
            Issue.record("Expected paused, got \(harness.migrator.phase)")
            return
        }
        let listingsBefore = harness.log.count(of: "list:enc")
        harness.lock.restoreKey()
        await harness.migrator.resumeIfPending()
        #expect(harness.log.count(of: "list:enc") > listingsBefore)
        #expect(harness.migrator.phase == .unreadableTrash)
        #expect(harness.migrator.pending != nil)
    }

    @Test("Clear pressed after the key is gone pauses, never calls the store, and resume reaches unreadableTrash again")
    func clearWithKeyGonePauses() async {
        let harness = encryptHarness()
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        #expect(harness.migrator.phase == .unreadableTrash)
        harness.lock.wipeKey()
        await harness.migrator.clearUnreadableTrash()
        guard case .paused = harness.migrator.phase else {
            Issue.record("Expected paused, got \(harness.migrator.phase)")
            return
        }
        #expect(harness.log.count(of: "clearUnreadableTrash") == 0)
        #expect(harness.migrator.pending != nil)
        #expect(harness.preferences.pendingMigration != nil)
        harness.lock.restoreKey()
        await harness.migrator.resumeIfPending()
        #expect(harness.migrator.phase == .unreadableTrash)
        #expect(harness.migrator.pending != nil)
    }
}

// MARK: - Retry after a clearing failure, and calls during a clear

@MainActor
@Suite struct MigratorClearFollowUpTests {
    /// A run whose clearing failed: `.failed(names: [])`, the trash still unreadable, the listing still failing.
    private func afterClearingFailure() async -> MigrationHarness {
        let harness = encryptHarness()
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        harness.store.setClearFailure(.io("cannot clear"))
        await harness.migrator.clearUnreadableTrash()
        return harness
    }

    @Test("Retry after a clearing failure publishes running, ends in unreadableTrash while the trash is unreadable")
    func retryAfterClearingFailureStillUnreadable() async {
        let harness = await afterClearingFailure()
        #expect(harness.migrator.phase == .failed(names: []))
        let recorder = TrashPhaseRecorder(harness.migrator.phaseUpdates())
        await harness.migrator.retryFailed()
        await recorder.stop()
        let running = recorder.phases.firstIndex(where: isRunningPhase)
        let stopped = recorder.phases.firstIndex(of: .unreadableTrash)
        #expect(running != nil)
        #expect(stopped != nil)
        if let running, let stopped { #expect(running < stopped) }
        #expect(harness.migrator.phase == .unreadableTrash)
    }

    @Test("Once healed, clearing from unreadableTrash after a Retry completes fully")
    func healedAfterRetryCompletes() async {
        let harness = await afterClearingFailure()
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .unreadableTrash)
        harness.store.setClearFailure(nil)
        harness.store.setFailure(nil, forStep: .itemsToMigrate)
        await harness.migrator.clearUnreadableTrash()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.migrator.pending == nil)
    }

    @Test("Retry after a clearing failure completes fully once everything is healed")
    func retryHealedCompletes() async {
        let harness = await afterClearingFailure()
        harness.store.setClearFailure(nil)
        harness.store.setFailure(nil, forStep: .itemsToMigrate)
        harness.store.hasUnreadableTrashFlag = false
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.migrator.pending == nil)
    }

    @Test("While a clear is in flight, other calls do nothing and the store clears exactly once")
    func callsDuringClearAreIgnored() async {
        let harness = encryptHarness()
        harness.store.hasUnreadableTrashFlag = true
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        harness.store.setFailure(nil, forStep: .itemsToMigrate)
        harness.gate.arm(at: "clearUnreadableTrash")
        let task = Task { await harness.migrator.clearUnreadableTrash() }
        #expect(await waitUntil { harness.gate.hasReached("clearUnreadableTrash") })
        let eventsBefore = harness.log.events
        await harness.migrator.clearUnreadableTrash()
        await harness.migrator.retryFailed()
        await harness.migrator.skipFailed()
        await harness.migrator.start(.encrypt, target: .password)
        await harness.migrator.resumeIfPending()
        #expect(harness.log.events == eventsBefore)
        #expect(harness.migrator.pending != nil)
        #expect(isRunningPhase(harness.migrator.phase))
        harness.gate.release()
        await task.value
        #expect(harness.log.count(of: "clearUnreadableTrash") == 1)
        #expect(harness.migrator.phase == .completed(fully: true))
    }
}

// MARK: - Key wiped while asking about the trash

@MainActor
@Suite struct MigratorTrashProbeWipeTests {
    @Test("A key wiped while hasUnreadableTrash is awaited at a failure point pauses instead of failing")
    func wipeDuringTrashQueryPauses() async {
        let harness = encryptHarness()
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        harness.gate.arm(at: "hasUnreadableTrash")
        let task = Task { await harness.migrator.start(.encrypt, target: .password) }
        #expect(await waitUntil { harness.gate.hasReached("hasUnreadableTrash") })
        harness.lock.wipeKey()
        harness.gate.release()
        await task.value
        guard case .paused = harness.migrator.phase else {
            Issue.record("Expected paused, got \(harness.migrator.phase)")
            return
        }
        #expect(harness.migrator.pending != nil)
        #expect(harness.preferences.pendingMigration != nil)
    }
}
