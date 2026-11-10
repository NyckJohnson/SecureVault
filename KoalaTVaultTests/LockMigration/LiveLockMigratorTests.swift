import Foundation
import Testing

@testable import KoalaTVault

// feature multiple-vaults-duress-password: rebuilt in LockMigration unit 1: this file uses API the feature removed; compiled out until LockMigration unit 1 replaces it.
#if false
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

    // MARK: - Encrypt

    @MainActor
    @Suite struct LiveLockMigratorEncryptTests {
        @Test("Starting an encrypt migration writes the pending record before the first file is touched")
        func pendingRecordWrittenFirst() async throws {
            let harness = encryptHarness()
            await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
            let written = try #require(harness.log.index(of: "pending=encrypt:passwordAndBiometrics"))
            let firstFile = try #require(harness.log.events.firstIndex { $0.hasPrefix("enc:") })
            #expect(written < firstFile)
        }

        @Test("The pending record is visible while the migration is running")
        func pendingVisibleWhileRunning() async throws {
            let harness = encryptHarness()
            harness.gate.arm(at: "migrate:a.jpg")
            let task = Task { await harness.migrator.start(.encrypt, target: .password) }
            #expect(await waitUntil { harness.gate.hasReached("migrate:a.jpg") })
            #expect(harness.migrator.pending == PendingMigration(kind: .encrypt, targetLockMode: .password))
            #expect(harness.preferences.pendingMigration == PendingMigration(kind: .encrypt, targetLockMode: .password))
            harness.gate.release()
            await task.value
        }

        @Test("Encrypting lists the plaintext files and encrypts every one, trash included")
        func encryptsEveryPlaintextFile() async {
            let harness = encryptHarness()
            await harness.migrator.start(.encrypt, target: .password)
            #expect(harness.log.events.contains("list:enc"))
            for name in allNames {
                #expect(harness.store.isEncrypted(name) == true)
            }
            #expect(harness.store.isEncrypted("Old.txt") == true)
        }

        @Test("Files are migrated one at a time in the listed order")
        func filesMigratedSequentially() async {
            let harness = encryptHarness()
            await harness.migrator.start(.encrypt, target: .password)
            let fileEvents = harness.log.events.filter { $0.hasPrefix("enc") }
            let expected = allNames.flatMap { ["enc:\($0)", "enc-done:\($0)"] }
            #expect(fileEvents == expected)
        }

        @Test("Already-encrypted files are left alone")
        func skipsEncryptedFiles() async {
            // swiftlint:disable trailing_comma
            let files = [
                FakeMigrationStore.file("plain.txt", encrypted: false),
                FakeMigrationStore.file("secret.txt", encrypted: true),
            ]
            // swiftlint:enable trailing_comma
            let harness = MigrationHarness(files: files)
            await harness.migrator.start(.encrypt, target: .password)
            #expect(harness.log.count(of: "enc:plain.txt") == 1)
            #expect(harness.log.count(of: "enc:secret.txt") == 0)
        }

        @Test("A completed encrypt migration clears the pending record and ends fully completed")
        func encryptCompletes() async {
            let harness = encryptHarness()
            await harness.migrator.start(.encrypt, target: .password)
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.migrator.pending == nil)
            #expect(harness.preferences.pendingMigration == nil)
        }

        @Test("With a target the lock mode equals the target when encryption completes")
        func lockModeEqualsTarget() async {
            let harness = encryptHarness(lockMode: .password)
            await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
            #expect(harness.lock.lockMode == .passwordAndBiometrics)
        }

        @Test("Without a target the lock mode is left as it was")
        func noTargetLeavesLockMode() async {
            let harness = encryptHarness(lockMode: .password)
            await harness.migrator.start(.encrypt, target: nil)
            #expect(harness.lock.lockMode == .password)
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.preferences.pendingMigration == nil)
        }

        @Test("The encrypt migration ends with finishEncryption, then clears the pending record last")
        func encryptEndsWithFinishEncryption() async throws {
            let harness = encryptHarness()
            await harness.migrator.start(.encrypt, target: .password)
            let lastFile = try #require(harness.log.lastIndex(of: "enc-done:Old.txt"))
            let finish = try #require(harness.log.index(of: "finishEncryption"))
            let cleared = try #require(harness.log.lastIndex(of: "pending=nil"))
            #expect(lastFile < finish)
            #expect(finish < cleared)
            #expect(cleared == harness.log.events.count - 1)
        }

        @Test("Encrypting an empty vault completes straight away and clears the pending record")
        func emptyVaultEncrypt() async {
            let harness = MigrationHarness(files: [])
            await harness.migrator.start(.encrypt, target: .password)
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.migrator.pending == nil)
            #expect(harness.log.events.filter { $0.hasPrefix("enc:") }.isEmpty)
        }
    }

    // MARK: - Decrypt

    @MainActor
    @Suite struct LiveLockMigratorDecryptTests {
        @Test("Starting a decrypt migration records a pending decrypt without a target, even if one is passed")
        func decryptPendingRecord() async throws {
            let harness = decryptHarness()
            await harness.migrator.start(.decrypt, target: .password)
            let written = try #require(harness.log.index(of: "pending=decrypt:-"))
            let firstFile = try #require(harness.log.events.firstIndex { $0.hasPrefix("dec:") })
            #expect(written < firstFile)
        }

        @Test("Decrypting lists the encrypted files and decrypts every one, trash included")
        func decryptsEveryEncryptedFile() async {
            let harness = decryptHarness()
            await harness.migrator.start(.decrypt, target: nil)
            #expect(harness.log.events.contains("list:dec"))
            for name in allNames {
                #expect(harness.store.isEncrypted(name) == false)
            }
        }

        @Test("The lock mode stays as it was while the decrypt migration is running")
        func lockModeUnchangedWhileRunning() async {
            let harness = decryptHarness(lockMode: .passwordAndBiometrics)
            harness.gate.arm(at: "migrate:c.mov")
            let task = Task { await harness.migrator.start(.decrypt, target: nil) }
            #expect(await waitUntil { harness.gate.hasReached("migrate:c.mov") })
            #expect(harness.lock.lockMode == .passwordAndBiometrics)
            harness.gate.release()
            await task.value
        }

        @Test("Decrypting re-scans, then finishes decryption, then removes the keys, then clears the pending record")
        func decryptOrdering() async throws {
            let harness = decryptHarness()
            await harness.migrator.start(.decrypt, target: nil)
            let lastFile = try #require(harness.log.lastIndex(of: "dec-done:Old.txt"))
            let rescan = try #require(harness.log.events.indices.last { harness.log.events[$0] == "list:dec" })
            let finish = try #require(harness.log.index(of: "finishDecryption"))
            let removeKeys = try #require(harness.log.index(of: "removeKeys"))
            let cleared = try #require(harness.log.lastIndex(of: "pending=nil"))
            #expect(lastFile < rescan)
            #expect(rescan < finish)
            #expect(finish < removeKeys)
            #expect(removeKeys < cleared)
            #expect(cleared == harness.log.events.count - 1)
        }

        @Test("Encrypted files that appear during the migration are found by the re-scan and decrypted")
        func rescanMigratesNewFiles() async throws {
            let harness = decryptHarness()
            harness.store.inject(FakeMigrationStore.file("late.png", encrypted: true), atListing: 2)
            await harness.migrator.start(.decrypt, target: nil)
            #expect(harness.store.isEncrypted("late.png") == false)
            let late = try #require(harness.log.index(of: "dec-done:late.png"))
            let finish = try #require(harness.log.index(of: "finishDecryption"))
            #expect(late < finish)
            #expect(harness.migrator.phase == .completed(fully: true))
        }

        @Test("A completed decrypt migration leaves no lock and no pending record")
        func decryptCompletes() async {
            let harness = decryptHarness()
            await harness.migrator.start(.decrypt, target: nil)
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.migrator.pending == nil)
            #expect(harness.preferences.pendingMigration == nil)
            #expect(harness.lock.lockMode == .none)
            #expect(harness.lock.state == .open)
        }

        @Test("Decrypting an empty vault still finishes decryption and removes the keys")
        func emptyVaultDecrypt() async {
            let harness = MigrationHarness(files: [])
            await harness.migrator.start(.decrypt, target: nil)
            #expect(harness.log.events.contains("finishDecryption"))
            #expect(harness.log.events.contains("removeKeys"))
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.migrator.pending == nil)
        }
    }

    // MARK: - One runner

    @MainActor
    @Suite struct LiveLockMigratorOneRunnerTests {
        @Test("A second start while a migration is running does nothing")
        func secondStartIgnored() async {
            let harness = encryptHarness()
            harness.gate.arm(at: "migrate:b.pdf")
            let task = Task { await harness.migrator.start(.encrypt, target: .password) }
            #expect(await waitUntil { harness.gate.hasReached("migrate:b.pdf") })
            let listingsBefore = harness.log.count(of: "list:enc")
            await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
            await harness.migrator.start(.decrypt, target: nil)
            #expect(harness.log.count(of: "list:enc") == listingsBefore)
            #expect(harness.log.count(of: "list:dec") == 0)
            #expect(harness.migrator.pending == PendingMigration(kind: .encrypt, targetLockMode: .password))
            harness.gate.release()
            await task.value
            for name in allNames {
                #expect(harness.log.count(of: "enc-done:\(name)") == 1)
            }
            #expect(harness.lock.lockMode == .password)
        }

        @Test("resumeIfPending while a migration is running does nothing")
        func resumeWhileRunningIgnored() async {
            let harness = encryptHarness()
            harness.gate.arm(at: "migrate:b.pdf")
            let task = Task { await harness.migrator.start(.encrypt, target: .password) }
            #expect(await waitUntil { harness.gate.hasReached("migrate:b.pdf") })
            await harness.migrator.resumeIfPending()
            harness.gate.release()
            await task.value
            for name in allNames {
                #expect(harness.log.count(of: "enc:\(name)") == 1)
            }
            #expect(harness.migrator.phase == .completed(fully: true))
        }
    }

    // MARK: - Key wiped

    @MainActor
    @Suite struct LiveLockMigratorPauseTests {
        private func wipeDuringFile(_ harness: MigrationHarness, kind: MigrationKind, file: String) async -> Task<
            Void, Never
        > {
            harness.gate.arm(at: "migrate:\(file)")
            let task = Task { await harness.migrator.start(kind, target: kind == .encrypt ? .password : nil) }
            _ = await waitUntil { harness.gate.hasReached("migrate:\(file)") }
            harness.lock.wipeKey()
            harness.gate.release()
            return task
        }

        @Test("A key wipe while a file is in progress pauses the migration without counting that file as failed")
        func wipeFailsInFlightFileButPauses() async {
            let harness = encryptHarness()
            let task = await wipeDuringFile(harness, kind: .encrypt, file: "c.mov")
            await task.value
            #expect(harness.migrator.phase == .paused(done: 2, total: 4))
            #expect(harness.store.isEncrypted("c.mov") == false)
            #expect(harness.migrator.pending == PendingMigration(kind: .encrypt, targetLockMode: .password))
        }

        @Test("A key wipe where the file in progress still finishes also pauses and does not fail")
        func wipeWithInFlightFileFinishing() async {
            let harness = encryptHarness()
            harness.store.setFinishesInFlightFile(true)
            let task = await wipeDuringFile(harness, kind: .encrypt, file: "c.mov")
            await task.value
            guard case .paused = harness.migrator.phase else {
                Issue.record("Expected paused, got \(harness.migrator.phase)")
                return
            }
            #expect(harness.migrator.pending != nil)
            #expect(harness.store.isEncrypted("Old.txt") == false)
        }

        @Test("After the next unlock, resumeIfPending continues from the remaining files only")
        func resumeContinuesFromRemainingFiles() async {
            let harness = encryptHarness()
            let task = await wipeDuringFile(harness, kind: .encrypt, file: "c.mov")
            await task.value
            harness.lock.restoreKey()
            await harness.migrator.resumeIfPending()
            #expect(harness.migrator.phase == .completed(fully: true))
            for name in allNames {
                #expect(harness.store.isEncrypted(name) == true)
            }
            #expect(harness.log.count(of: "enc-done:a.jpg") == 1)
            #expect(harness.log.count(of: "enc-done:b.pdf") == 1)
            #expect(harness.log.count(of: "enc-done:c.mov") == 1)
            #expect(harness.log.count(of: "enc:a.jpg") == 1)
            #expect(harness.log.count(of: "enc:b.pdf") == 1)
            #expect(harness.migrator.pending == nil)
        }

        @Test("A file that finished while the key was wiped is not migrated again on resume")
        func finishedInFlightFileNotRepeated() async {
            let harness = encryptHarness()
            harness.store.setFinishesInFlightFile(true)
            let task = await wipeDuringFile(harness, kind: .encrypt, file: "c.mov")
            await task.value
            harness.lock.restoreKey()
            await harness.migrator.resumeIfPending()
            #expect(harness.migrator.phase == .completed(fully: true))
            for name in allNames {
                #expect(harness.log.count(of: "enc-done:\(name)") == 1)
            }
        }

        @Test("A decrypt migration pauses on a key wipe and finishes after unlock without failing")
        func decryptPausesAndResumes() async {
            let harness = decryptHarness()
            let task = await wipeDuringFile(harness, kind: .decrypt, file: "b.pdf")
            await task.value
            #expect(harness.migrator.phase == .paused(done: 1, total: 4))
            #expect(harness.log.events.contains("finishDecryption") == false)
            #expect(harness.log.events.contains("removeKeys") == false)
            harness.lock.restoreKey()
            await harness.migrator.resumeIfPending()
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.lock.lockMode == .none)
            #expect(harness.migrator.pending == nil)
        }
    }

    // MARK: - resumeIfPending

    @MainActor
    @Suite struct LiveLockMigratorResumeTests {
        private static let pendingEncrypt = PendingMigration(kind: .encrypt, targetLockMode: .passwordAndBiometrics)
        private static let pendingDecrypt = PendingMigration(kind: .decrypt, targetLockMode: nil)

        @Test("With nothing pending, resumeIfPending changes nothing")
        func nothingPending() async {
            let harness = encryptHarness()
            await harness.migrator.resumeIfPending()
            #expect(harness.migrator.phase == .idle)
            #expect(harness.migrator.pending == nil)
            #expect(harness.log.events.isEmpty)
        }

        @Test("A pending migration with a loaded key is continued and completed")
        func pendingWithKeyContinues() async {
            let harness = MigrationHarness(
                files: MigrationHarness.sampleFiles(encrypted: false), lockMode: .password,
                pending: Self.pendingEncrypt, unlocked: true)
            await harness.migrator.resumeIfPending()
            #expect(harness.migrator.phase == .completed(fully: true))
            for name in allNames {
                #expect(harness.store.isEncrypted(name) == true)
            }
            #expect(harness.lock.lockMode == .passwordAndBiometrics)
            #expect(harness.preferences.pendingMigration == nil)
        }

        @Test("A pending decrypt with a loaded key is continued and completed")
        func pendingDecryptContinues() async {
            let harness = MigrationHarness(
                files: MigrationHarness.sampleFiles(encrypted: true), lockMode: .password,
                pending: Self.pendingDecrypt, unlocked: true)
            await harness.migrator.resumeIfPending()
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.lock.lockMode == .none)
            #expect(harness.preferences.pendingMigration == nil)
        }

        @Test("A pending migration while locked pauses without touching any file")
        func pendingWhileLockedPauses() async {
            let harness = MigrationHarness(
                files: MigrationHarness.sampleFiles(encrypted: false), lockMode: .password,
                pending: Self.pendingEncrypt, unlocked: false)
            await harness.migrator.resumeIfPending()
            guard case .paused = harness.migrator.phase else {
                Issue.record("Expected paused, got \(harness.migrator.phase)")
                return
            }
            #expect(harness.log.events.filter { $0.hasPrefix("enc") || $0.hasPrefix("dec") }.isEmpty)
            #expect(harness.preferences.pendingMigration == Self.pendingEncrypt)
        }

        @Test("A migrator created over a persisted pending record reports it")
        func pendingLoadedFromPreferences() {
            let harness = MigrationHarness(
                files: MigrationHarness.sampleFiles(encrypted: false), pending: Self.pendingEncrypt)
            #expect(harness.migrator.pending == Self.pendingEncrypt)
            #expect(harness.migrator.phase == .idle)
        }

        @Test("A pending migration paused by a lock continues after the unlock")
        func lockedThenUnlockedContinues() async {
            let harness = MigrationHarness(
                files: MigrationHarness.sampleFiles(encrypted: false), lockMode: .password,
                pending: Self.pendingEncrypt, unlocked: false)
            await harness.migrator.resumeIfPending()
            harness.lock.restoreKey()
            await harness.migrator.resumeIfPending()
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.preferences.pendingMigration == nil)
        }
    }

    // MARK: - Killed at any point

    @MainActor
    @Suite struct LiveLockMigratorKillTests {
        private func killThenRelaunch(
            _ harness: MigrationHarness, kind: MigrationKind, killedAt point: String
        ) async {
            harness.gate.arm(at: point)
            let target: LockMode? = kind == .encrypt ? .passwordAndBiometrics : nil
            let original = harness.migrator
            // The killed migrator never gets to continue: its task is abandoned at the gate.
            Task { await original.start(kind, target: target) }
            _ = await waitUntil { harness.gate.hasReached(point) }
            #expect(harness.gate.hasReached(point))
            harness.relaunch()
            await harness.migrator.resumeIfPending()
        }

        @Test(
            "An encrypt migration killed at any point is completed by resumeIfPending after relaunch",
            arguments: ["list:1", "migrate:a.jpg", "migrate:b.pdf", "migrate:Old.txt", "finishEncryption"])
        func encryptKilled(point: String) async {
            let harness = encryptHarness(lockMode: .password)
            await killThenRelaunch(harness, kind: .encrypt, killedAt: point)
            #expect(harness.migrator.phase == .completed(fully: true))
            for name in allNames {
                #expect(harness.store.isEncrypted(name) == true)
            }
            #expect(harness.preferences.pendingMigration == nil)
            #expect(harness.lock.lockMode == .passwordAndBiometrics)
        }

        @Test("Files already encrypted before an encrypt kill are not migrated again")
        func encryptKillDoesNotRepeatFinishedFiles() async {
            let harness = encryptHarness()
            await killThenRelaunch(harness, kind: .encrypt, killedAt: "migrate:c.mov")
            #expect(harness.log.count(of: "enc-done:a.jpg") == 1)
            #expect(harness.log.count(of: "enc-done:b.pdf") == 1)
            #expect(harness.log.count(of: "enc-done:c.mov") == 1)
            #expect(harness.log.count(of: "enc-done:Old.txt") == 1)
        }

        // swiftlint:disable trailing_comma
        @Test(
            "A decrypt migration killed at any point is completed by resumeIfPending after relaunch",
            arguments: [
                "list:1",
                "migrate:a.jpg",
                "migrate:Old.txt",
                "list:2",
                "finishDecryption",
                "removeKeys:before",
                "removeKeys:after",
            ])
        // swiftlint:enable trailing_comma
        func decryptKilled(point: String) async {
            let harness = decryptHarness(lockMode: .password)
            await killThenRelaunch(harness, kind: .decrypt, killedAt: point)
            #expect(harness.migrator.phase == .completed(fully: true))
            for name in allNames {
                #expect(harness.store.isEncrypted(name) == false)
            }
            #expect(harness.preferences.pendingMigration == nil)
            #expect(harness.lock.lockMode == .none)
            #expect(harness.lock.state == .open)
        }
    }

    // MARK: - Failures

    @MainActor
    @Suite struct LiveLockMigratorFailureTests {
        @Test("A failing file is collected, the other files are still migrated, and the failure is reported at the end")
        func failedFileCollected() async {
            let harness = encryptHarness()
            harness.store.setFailure(.io("disk full"), for: "b.pdf")
            await harness.migrator.start(.encrypt, target: .password)
            #expect(harness.migrator.phase == .failed(names: ["b.pdf"]))
            #expect(harness.store.isEncrypted("a.jpg") == true)
            #expect(harness.store.isEncrypted("b.pdf") == false)
            #expect(harness.store.isEncrypted("c.mov") == true)
            #expect(harness.store.isEncrypted("Old.txt") == true)
        }

        @Test("The failed names are the files' display names, trashed files included, in listed order")
        func failedNamesAreDisplayNames() async {
            let harness = encryptHarness()
            harness.store.setFailure(.io("bad"), for: "Old.txt")
            harness.store.setFailure(.io("bad"), for: "a.jpg")
            await harness.migrator.start(.encrypt, target: .password)
            #expect(harness.migrator.phase == .failed(names: ["a.jpg", "Old.txt"]))
        }

        @Test("While failures await a decision the pending record is kept")
        func pendingKeptWhileFailed() async {
            let harness = encryptHarness()
            harness.store.setFailure(.io("bad"), for: "b.pdf")
            await harness.migrator.start(.encrypt, target: .password)
            #expect(harness.migrator.pending == PendingMigration(kind: .encrypt, targetLockMode: .password))
            #expect(harness.preferences.pendingMigration != nil)
        }

        @Test("A decrypt migration with a failed file does not remove the keys")
        func failedDecryptKeepsKeys() async {
            let harness = decryptHarness()
            harness.store.setFailure(.io("bad"), for: "c.mov")
            await harness.migrator.start(.decrypt, target: nil)
            #expect(harness.migrator.phase == .failed(names: ["c.mov"]))
            #expect(harness.log.events.contains("removeKeys") == false)
            #expect(harness.lock.lockMode == .password)
        }

        @Test("retryFailed migrates only the failed files again and completes")
        func retryOnlyFailedFiles() async {
            let harness = encryptHarness()
            harness.store.setFailure(.io("bad"), for: "b.pdf")
            await harness.migrator.start(.encrypt, target: .password)
            harness.store.setFailure(nil, for: "b.pdf")
            let mark = harness.log.events.count
            await harness.migrator.retryFailed()
            let retried = harness.log.events.dropFirst(mark).filter { $0.hasPrefix("enc:") }
            #expect(retried == ["enc:b.pdf"])
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.store.isEncrypted("b.pdf") == true)
            #expect(harness.migrator.pending == nil)
            #expect(harness.preferences.pendingMigration == nil)
            #expect(harness.lock.lockMode == .password)
        }

        @Test("retryFailed that fails again reports the still-failing files")
        func retryFailsAgain() async {
            let harness = encryptHarness()
            harness.store.setFailure(.io("bad"), for: "a.jpg")
            harness.store.setFailure(.io("bad"), for: "b.pdf")
            await harness.migrator.start(.encrypt, target: .password)
            harness.store.setFailure(nil, for: "a.jpg")
            await harness.migrator.retryFailed()
            #expect(harness.migrator.phase == .failed(names: ["b.pdf"]))
            #expect(harness.migrator.pending != nil)
        }

        @Test("A decrypt migration completes after retryFailed: finish decryption, remove keys, clear pending")
        func decryptRetryCompletes() async throws {
            let harness = decryptHarness()
            harness.store.setFailure(.io("bad"), for: "c.mov")
            await harness.migrator.start(.decrypt, target: nil)
            harness.store.setFailure(nil, for: "c.mov")
            await harness.migrator.retryFailed()
            #expect(harness.migrator.phase == .completed(fully: true))
            let finish = try #require(harness.log.index(of: "finishDecryption"))
            let removeKeys = try #require(harness.log.index(of: "removeKeys"))
            let cleared = try #require(harness.log.lastIndex(of: "pending=nil"))
            #expect(finish < removeKeys)
            #expect(removeKeys < cleared)
            #expect(harness.lock.lockMode == .none)
        }

        @Test("skipFailed after an encrypt completes not fully, clears pending and keeps the target lock mode")
        func skipFailedEncrypt() async {
            let harness = encryptHarness(lockMode: .password)
            harness.store.setFailure(.io("bad"), for: "b.pdf")
            await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
            await harness.migrator.skipFailed()
            #expect(harness.migrator.phase == .completed(fully: false))
            #expect(harness.migrator.pending == nil)
            #expect(harness.preferences.pendingMigration == nil)
            #expect(harness.lock.lockMode == .passwordAndBiometrics)
            #expect(harness.store.isEncrypted("b.pdf") == false)
        }

        @Test("skipFailed after a decrypt completes not fully, clears pending and keeps the lock and keys")
        func skipFailedDecrypt() async {
            let harness = decryptHarness(lockMode: .password)
            harness.store.setFailure(.io("bad"), for: "b.pdf")
            await harness.migrator.start(.decrypt, target: nil)
            await harness.migrator.skipFailed()
            #expect(harness.migrator.phase == .completed(fully: false))
            #expect(harness.migrator.pending == nil)
            #expect(harness.preferences.pendingMigration == nil)
            #expect(harness.lock.lockMode == .password)
            #expect(harness.log.events.contains("removeKeys") == false)
        }
    }

    // MARK: - UI-test failure hook

    @MainActor
    @Suite struct LiveLockMigratorUITestHookTests {
        @Test(
            "The injected failing file name makes that file fail and the rest migrate",
            arguments: [MigrationKind.encrypt, MigrationKind.decrypt])
        func hookFailsNamedFile(kind: MigrationKind) async {
            let encrypting = kind == .encrypt
            let harness =
                encrypting
                ? encryptHarness(uiTestFailFileName: "b.pdf") : decryptHarness(uiTestFailFileName: "b.pdf")
            await harness.migrator.start(kind, target: encrypting ? .password : nil)
            #expect(harness.migrator.phase == .failed(names: ["b.pdf"]))
            #expect(harness.store.isEncrypted("b.pdf") == !encrypting)
            #expect(harness.store.isEncrypted("a.jpg") == encrypting)
            #expect(harness.store.isEncrypted("c.mov") == encrypting)
        }

        @Test("Without the hook no file fails")
        func noHookNoFailure() async {
            let harness = encryptHarness(uiTestFailFileName: nil)
            await harness.migrator.start(.encrypt, target: .password)
            #expect(harness.migrator.phase == .completed(fully: true))
        }

        @Test("A hook naming a file that is not in the vault changes nothing")
        func hookForMissingFile() async {
            let harness = encryptHarness(uiTestFailFileName: "nope.txt")
            await harness.migrator.start(.encrypt, target: .password)
            #expect(harness.migrator.phase == .completed(fully: true))
        }
    }
#endif
