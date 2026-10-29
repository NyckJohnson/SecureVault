import Foundation
import Testing

@testable import KoalaTVault

@MainActor private let allNames = MigrationHarness.names

@MainActor private func encryptHarness(
    lockMode: LockMode = .password,
    unlocked: Bool = true,
    uiTestFailFileName: String? = nil
) -> MigrationHarness {
    MigrationHarness(
        files: MigrationHarness.sampleFiles(encrypted: false), lockMode: lockMode, unlocked: unlocked,
        uiTestFailFileName: uiTestFailFileName)
}

@MainActor private func decryptHarness(
    lockMode: LockMode = .password,
    uiTestFailFileName: String? = nil
) -> MigrationHarness {
    MigrationHarness(
        files: MigrationHarness.sampleFiles(encrypted: true), lockMode: lockMode,
        uiTestFailFileName: uiTestFailFileName)
}

// MARK: - Step failures

@MainActor
@Suite struct LiveLockMigratorStepFailureTests {
    @Test("An encrypt whose finishEncryption fails with the key loaded still completes and clears the pending record")
    func finishEncryptionFailureStillCompletes() async {
        let harness = encryptHarness(lockMode: .password)
        harness.store.setFailure(.io("index write"), forStep: .finishEncryption)
        await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.migrator.pending == nil)
        #expect(harness.preferences.pendingMigration == nil)
        #expect(harness.lock.lockMode == .passwordAndBiometrics)
    }

    @Test("A listing failure reports failed with no names and keeps the pending record")
    func listFailureReportsEmptyNames() async {
        let harness = encryptHarness()
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        #expect(harness.migrator.phase == .failed(names: []))
        #expect(harness.migrator.pending == PendingMigration(kind: .encrypt, targetLockMode: .password))
        #expect(harness.log.events.filter { $0.hasPrefix("enc:") }.isEmpty)
    }

    @Test("Retry after a listing failure lists again and migrates every file")
    func retryAfterListFailure() async {
        let harness = encryptHarness()
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .password)
        harness.store.setFailure(nil, forStep: .itemsToMigrate)
        await harness.migrator.retryFailed()
        #expect(harness.log.count(of: "list:enc") == 2)
        #expect(harness.migrator.phase == .completed(fully: true))
        for name in allNames {
            #expect(harness.store.isEncrypted(name) == true)
        }
        #expect(harness.migrator.pending == nil)
    }

    @Test("Skip after a listing failure completes not fully, clears pending and keeps the target lock mode")
    func skipAfterListFailure() async {
        let harness = encryptHarness(lockMode: .password)
        harness.store.setFailure(.io("unreadable"), forStep: .itemsToMigrate)
        await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .completed(fully: false))
        #expect(harness.migrator.pending == nil)
        #expect(harness.preferences.pendingMigration == nil)
        #expect(harness.lock.lockMode == .passwordAndBiometrics)
    }

    @Test("A removeKeysAfterDecryption failure reports failed with no names and keeps the pending record")
    func removeKeysFailureReportsEmptyNames() async {
        let harness = decryptHarness()
        harness.lock.setFailure(.keychain(-25_300), forStep: .removeKeysAfterDecryption)
        await harness.migrator.start(.decrypt, target: nil)
        #expect(harness.migrator.phase == .failed(names: []))
        #expect(harness.migrator.pending == PendingMigration(kind: .decrypt, targetLockMode: nil))
        #expect(harness.lock.lockMode == .password)
        for name in allNames {
            #expect(harness.store.isEncrypted(name) == false)
        }
    }

    @Test("Retry after a removeKeys failure redoes that step only and completes the decrypt")
    func retryAfterRemoveKeysFailure() async {
        let harness = decryptHarness()
        harness.lock.setFailure(.keychain(-25_300), forStep: .removeKeysAfterDecryption)
        await harness.migrator.start(.decrypt, target: nil)
        harness.lock.setFailure(nil, forStep: .removeKeysAfterDecryption)
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.log.count(of: "removeKeys") == 2)
        for name in allNames {
            #expect(harness.log.count(of: "dec:\(name)") == 1)
        }
        #expect(harness.lock.lockMode == .none)
        #expect(harness.lock.state == .open)
        #expect(harness.migrator.pending == nil)
        #expect(harness.preferences.pendingMigration == nil)
    }

    @Test("Skip after a removeKeys failure completes not fully and keeps the lock")
    func skipAfterRemoveKeysFailure() async {
        let harness = decryptHarness()
        harness.lock.setFailure(.keychain(-25_300), forStep: .removeKeysAfterDecryption)
        await harness.migrator.start(.decrypt, target: nil)
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .completed(fully: false))
        #expect(harness.migrator.pending == nil)
        #expect(harness.lock.lockMode == .password)
    }

    @Test("Files still encrypted after a decrypt report failed with no names and keep the pending record")
    func stillEncryptedReportsEmptyNames() async {
        let harness = decryptHarness()
        harness.store.setFailure(.stillEncrypted(count: 1), forStep: .finishDecryption)
        await harness.migrator.start(.decrypt, target: nil)
        #expect(harness.migrator.phase == .failed(names: []))
        #expect(harness.migrator.pending == PendingMigration(kind: .decrypt, targetLockMode: nil))
        #expect(harness.log.events.contains("removeKeys") == false)
        #expect(harness.lock.lockMode == .password)
    }

    @Test("Retry after stillEncrypted lists again, migrates the leftover and completes the decrypt")
    func retryAfterStillEncrypted() async {
        let harness = decryptHarness()
        harness.store.setFailure(.stillEncrypted(count: 1), forStep: .finishDecryption)
        await harness.migrator.start(.decrypt, target: nil)
        let listingsBefore = harness.log.count(of: "list:dec")
        harness.store.add(FakeMigrationStore.file("left.txt", encrypted: true))
        harness.store.setFailure(nil, forStep: .finishDecryption)
        await harness.migrator.retryFailed()
        #expect(harness.log.count(of: "list:dec") == listingsBefore + 1)
        #expect(harness.store.isEncrypted("left.txt") == false)
        #expect(harness.log.count(of: "dec:left.txt") == 1)
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.lock.lockMode == .none)
        #expect(harness.migrator.pending == nil)
    }

    @Test("Skip after stillEncrypted completes not fully and keeps the lock and keys")
    func skipAfterStillEncrypted() async {
        let harness = decryptHarness()
        harness.store.setFailure(.stillEncrypted(count: 2), forStep: .finishDecryption)
        await harness.migrator.start(.decrypt, target: nil)
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .completed(fully: false))
        #expect(harness.migrator.pending == nil)
        #expect(harness.preferences.pendingMigration == nil)
        #expect(harness.lock.lockMode == .password)
        #expect(harness.lock.state == .unlocked)
        #expect(harness.log.events.contains("removeKeys") == false)
    }

    @Test("Skip after an encrypt still completes when switching to the target lock mode fails")
    func skipCompletesWhenSwitchModeFails() async {
        let harness = encryptHarness(lockMode: .password)
        harness.store.setFailure(.io("bad"), for: "b.pdf")
        await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
        harness.lock.setFailure(.keychain(-25_300), forStep: .switchMode)
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .completed(fully: false))
        #expect(harness.migrator.pending == nil)
        #expect(harness.preferences.pendingMigration == nil)
    }
}

// MARK: - No resume while failures await

@MainActor
@Suite struct LiveLockMigratorNoResumeWhileFailedTests {
    @Test("resumeIfPending does nothing while failed files await Retry or Skip")
    func noResumeAfterFileFailure() async {
        let harness = encryptHarness()
        harness.store.setFailure(.io("bad"), for: "b.pdf")
        await harness.migrator.start(.encrypt, target: .password)
        let mark = harness.log.events.count
        await harness.migrator.resumeIfPending()
        #expect(harness.log.events.count == mark)
        #expect(harness.migrator.phase == .failed(names: ["b.pdf"]))
        #expect(harness.migrator.pending == PendingMigration(kind: .encrypt, targetLockMode: .password))
    }

    @Test("resumeIfPending does nothing while a failed step with no names awaits Retry or Skip")
    func noResumeAfterStepFailure() async {
        let harness = decryptHarness()
        harness.store.setFailure(.stillEncrypted(count: 1), forStep: .finishDecryption)
        await harness.migrator.start(.decrypt, target: nil)
        let mark = harness.log.events.count
        await harness.migrator.resumeIfPending()
        #expect(harness.log.events.count == mark)
        #expect(harness.migrator.phase == .failed(names: []))
        #expect(harness.migrator.pending != nil)
    }
}

// MARK: - switchMode only when needed

@MainActor
@Suite struct LiveLockMigratorSwitchModeTests {
    @Test("Encrypt with a target that differs from the current lock mode switches to it once")
    func switchesWhenDifferent() async {
        let harness = encryptHarness(lockMode: .password)
        await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
        #expect(harness.log.events(withPrefix: "switchMode:") == ["switchMode:passwordAndBiometrics"])
        #expect(harness.lock.lockMode == .passwordAndBiometrics)
    }

    @Test("Encrypt with a target equal to the current lock mode never calls switchMode")
    func noSwitchWhenEqual() async {
        let harness = encryptHarness(lockMode: .password)
        await harness.migrator.start(.encrypt, target: .password)
        #expect(harness.log.events(withPrefix: "switchMode:").isEmpty)
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.lock.lockMode == .password)
    }

    @Test("Encrypt without a target never calls switchMode")
    func noSwitchWithoutTarget() async {
        let harness = encryptHarness(lockMode: .passwordAndBiometrics)
        await harness.migrator.start(.encrypt, target: nil)
        #expect(harness.log.events(withPrefix: "switchMode:").isEmpty)
    }

    @Test("A decrypt never calls switchMode")
    func decryptNeverSwitches() async {
        let harness = decryptHarness()
        await harness.migrator.start(.decrypt, target: nil)
        #expect(harness.log.events(withPrefix: "switchMode:").isEmpty)
    }
}

// MARK: - Key wiped during a closing step

@MainActor
@Suite struct LiveLockMigratorClosingStepPauseTests {
    @Test("A key wipe during finishDecryption pauses, and the next unlock's resume completes the decrypt")
    func wipeDuringFinishDecryption() async {
        let harness = decryptHarness()
        harness.gate.arm(at: "finishDecryption")
        let task = Task { await harness.migrator.start(.decrypt, target: nil) }
        #expect(await waitUntil { harness.gate.hasReached("finishDecryption") })
        harness.lock.wipeKey()
        harness.gate.release()
        await task.value
        guard case .paused = harness.migrator.phase else {
            Issue.record("Expected paused, got \(harness.migrator.phase)")
            return
        }
        #expect(harness.migrator.pending == PendingMigration(kind: .decrypt, targetLockMode: nil))
        #expect(harness.log.events.contains("removeKeys") == false)
        harness.lock.restoreKey()
        await harness.migrator.resumeIfPending()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.lock.lockMode == .none)
        #expect(harness.migrator.pending == nil)
        for name in allNames {
            #expect(harness.log.count(of: "dec:\(name)") == 1)
        }
    }

    @Test("A key wipe during removeKeysAfterDecryption pauses, and the next unlock's resume completes the decrypt")
    func wipeDuringRemoveKeys() async {
        let harness = decryptHarness()
        harness.gate.arm(at: "removeKeys:before")
        let task = Task { await harness.migrator.start(.decrypt, target: nil) }
        #expect(await waitUntil { harness.gate.hasReached("removeKeys:before") })
        harness.lock.wipeKey()
        harness.lock.setFailure(.notUnlocked, forStep: .removeKeysAfterDecryption)
        harness.gate.release()
        await task.value
        guard case .paused = harness.migrator.phase else {
            Issue.record("Expected paused, got \(harness.migrator.phase)")
            return
        }
        #expect(harness.migrator.pending == PendingMigration(kind: .decrypt, targetLockMode: nil))
        #expect(harness.lock.lockMode == .password)
        harness.lock.setFailure(nil, forStep: .removeKeysAfterDecryption)
        harness.lock.restoreKey()
        await harness.migrator.resumeIfPending()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.lock.lockMode == .none)
        #expect(harness.lock.state == .open)
        #expect(harness.migrator.pending == nil)
    }
}

// MARK: - New runs and locked resume

/// Collects the published phases until cancelled.
@MainActor
private final class PhaseRecorder {
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
}

@MainActor private func pauseEncryptByWipe(_ harness: MigrationHarness) async {
    harness.gate.arm(at: "migrate:c.mov")
    let task = Task { await harness.migrator.start(.encrypt, target: .password) }
    _ = await waitUntil { harness.gate.hasReached("migrate:c.mov") }
    harness.lock.wipeKey()
    harness.gate.release()
    await task.value
}

@MainActor
@Suite struct LiveLockMigratorNewRunTests {
    @Test("resumeIfPending while locked after an in-memory pause publishes paused and never running")
    func lockedResumeAfterPauseSkipsRunning() async {
        let harness = encryptHarness()
        await pauseEncryptByWipe(harness)
        let recorder = PhaseRecorder(harness.migrator.phaseUpdates())
        await harness.migrator.resumeIfPending()
        await recorder.stop()
        let sawRunning = recorder.phases.contains {
            if case .running = $0 { return true }
            return false
        }
        #expect(sawRunning == false)
        guard case .paused = harness.migrator.phase else {
            Issue.record("Expected paused, got \(harness.migrator.phase)")
            return
        }
    }

    @Test("start while paused does nothing: the run and the pending record are unchanged")
    func startWhilePausedIgnored() async {
        let harness = encryptHarness()
        await pauseEncryptByWipe(harness)
        let phaseBefore = harness.migrator.phase
        let mark = harness.log.events.count
        harness.lock.restoreKey()
        await harness.migrator.start(.decrypt, target: nil)
        await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
        #expect(harness.migrator.phase == phaseBefore)
        #expect(harness.migrator.pending == PendingMigration(kind: .encrypt, targetLockMode: .password))
        #expect(harness.preferences.pendingMigration == PendingMigration(kind: .encrypt, targetLockMode: .password))
        #expect(harness.log.events.count == mark)
    }

    @Test("start while failed does nothing: the run and the pending record are unchanged")
    func startWhileFailedIgnored() async {
        let harness = encryptHarness()
        harness.store.setFailure(.io("bad"), for: "b.pdf")
        await harness.migrator.start(.encrypt, target: .password)
        let mark = harness.log.events.count
        await harness.migrator.start(.decrypt, target: nil)
        await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
        #expect(harness.migrator.phase == .failed(names: ["b.pdf"]))
        #expect(harness.migrator.pending == PendingMigration(kind: .encrypt, targetLockMode: .password))
        #expect(harness.preferences.pendingMigration == PendingMigration(kind: .encrypt, targetLockMode: .password))
        #expect(harness.log.events.count == mark)
    }

    @Test("start from completed begins a new migration")
    func startFromCompletedRuns() async {
        let harness = encryptHarness()
        await harness.migrator.start(.encrypt, target: .password)
        #expect(harness.migrator.phase == .completed(fully: true))
        await harness.migrator.start(.decrypt, target: nil)
        #expect(harness.log.events.contains("pending=decrypt:-"))
        for name in allNames {
            #expect(harness.log.count(of: "dec-done:\(name)") == 1)
            #expect(harness.store.isEncrypted(name) == false)
        }
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.lock.lockMode == .none)
        #expect(harness.migrator.pending == nil)
    }
}
