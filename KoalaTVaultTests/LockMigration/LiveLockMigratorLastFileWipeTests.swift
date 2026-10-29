import Foundation
import Testing

@testable import KoalaTVault

@MainActor private func encryptHarness() -> MigrationHarness {
    MigrationHarness(files: MigrationHarness.sampleFiles(encrypted: false), lockMode: .password)
}

@MainActor private func decryptHarness() -> MigrationHarness {
    MigrationHarness(files: MigrationHarness.sampleFiles(encrypted: true), lockMode: .password)
}

/// Starts a run, wipes the key while `file` migrates, lets that file finish, and waits for the run to stop.
@MainActor private func runWipingKey(
    during file: String, in harness: MigrationHarness, kind: MigrationKind, target: LockMode?
) async {
    harness.store.setFinishesInFlightFile(true)
    harness.gate.arm(at: "migrate:\(file)")
    let task = Task { await harness.migrator.start(kind, target: target) }
    #expect(await waitUntil { harness.gate.hasReached("migrate:\(file)") })
    harness.lock.wipeKey()
    harness.gate.release()
    await task.value
}

@MainActor
@Suite struct LiveLockMigratorLastFileWipeTests {
    @Test("Decrypt: key wiped during the last file, which still finishes, pauses before the re-scan")
    func decryptWipeDuringLastFilePausesBeforeRescan() async {
        let harness = decryptHarness()
        await runWipingKey(during: "Old.txt", in: harness, kind: .decrypt, target: nil)
        let total = MigrationHarness.names.count
        #expect(harness.migrator.phase == .paused(done: total, total: total))
        #expect(harness.log.count(of: "list:dec") == 1)
        #expect(harness.log.count(of: "finishDecryption") == 0)
        #expect(harness.log.count(of: "removeKeys") == 0)
        #expect(harness.migrator.pending == PendingMigration(kind: .decrypt, targetLockMode: nil))
        #expect(harness.preferences.pendingMigration == PendingMigration(kind: .decrypt, targetLockMode: nil))
        if case .failed = harness.migrator.phase { Issue.record("Run must not fail") }
    }

    @Test("Decrypt: resume after the last-file wipe re-scans, finishes, removes keys, and clears pending last")
    func decryptResumeAfterLastFileWipeCompletes() async throws {
        let harness = decryptHarness()
        await runWipingKey(during: "Old.txt", in: harness, kind: .decrypt, target: nil)
        harness.lock.restoreKey()
        await harness.migrator.resumeIfPending()
        #expect(harness.migrator.phase == .completed(fully: true))
        let rescan = try #require(harness.log.lastIndex(of: "list:dec"))
        let finish = try #require(harness.log.index(of: "finishDecryption"))
        let remove = try #require(harness.log.index(of: "removeKeys"))
        let cleared = try #require(harness.log.lastIndex(of: "pending=nil"))
        #expect(rescan < finish)
        #expect(finish < remove)
        #expect(remove < cleared)
        #expect(harness.lock.lockMode == .none)
        #expect(harness.migrator.pending == nil)
    }

    @Test("Encrypt: key wiped during the last file, which still finishes, pauses before any closing step")
    func encryptWipeDuringLastFilePausesBeforeClosingSteps() async {
        let harness = encryptHarness()
        await runWipingKey(during: "Old.txt", in: harness, kind: .encrypt, target: .passwordAndBiometrics)
        let total = MigrationHarness.names.count
        #expect(harness.migrator.phase == .paused(done: total, total: total))
        #expect(harness.log.count(of: "finishEncryption") == 0)
        #expect(harness.log.events(withPrefix: "switchMode").isEmpty)
        #expect(harness.log.count(of: "removeKeys") == 0)
        let expected = PendingMigration(kind: .encrypt, targetLockMode: .passwordAndBiometrics)
        #expect(harness.migrator.pending == expected)
        #expect(harness.preferences.pendingMigration == expected)
    }

    @Test("Encrypt: resume after the last-file wipe runs the closing steps and clears pending last")
    func encryptResumeAfterLastFileWipeCompletes() async throws {
        let harness = encryptHarness()
        await runWipingKey(during: "Old.txt", in: harness, kind: .encrypt, target: .passwordAndBiometrics)
        harness.lock.restoreKey()
        await harness.migrator.resumeIfPending()
        #expect(harness.migrator.phase == .completed(fully: true))
        let finish = try #require(harness.log.index(of: "finishEncryption"))
        let switched = try #require(harness.log.index(of: "switchMode:passwordAndBiometrics"))
        let cleared = try #require(harness.log.lastIndex(of: "pending=nil"))
        #expect(finish < switched)
        #expect(switched < cleared)
        #expect(harness.lock.lockMode == .passwordAndBiometrics)
        #expect(harness.migrator.pending == nil)
    }

    @Test("Decrypt: key wiped during the re-scan's last file pauses before finishDecryption")
    func decryptWipeDuringRescanLastFilePausesBeforeFinish() async throws {
        let harness = decryptHarness()
        harness.store.inject(FakeMigrationStore.file("late.txt", encrypted: true), atListing: 2)
        await runWipingKey(during: "late.txt", in: harness, kind: .decrypt, target: nil)
        let total = MigrationHarness.names.count + 1
        #expect(harness.migrator.phase == .paused(done: total, total: total))
        #expect(harness.log.count(of: "finishDecryption") == 0)
        #expect(harness.log.count(of: "removeKeys") == 0)
        #expect(harness.migrator.pending == PendingMigration(kind: .decrypt, targetLockMode: nil))
        harness.lock.restoreKey()
        await harness.migrator.resumeIfPending()
        #expect(harness.migrator.phase == .completed(fully: true))
        let finish = try #require(harness.log.index(of: "finishDecryption"))
        let remove = try #require(harness.log.index(of: "removeKeys"))
        let cleared = try #require(harness.log.lastIndex(of: "pending=nil"))
        #expect(finish < remove)
        #expect(remove < cleared)
        #expect(harness.migrator.pending == nil)
    }
}
