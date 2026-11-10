import Foundation
import Testing

@testable import KoalaTVault

// feature multiple-vaults-duress-password: rebuilt in LockMigration unit 1: this file uses API the feature removed; compiled out until LockMigration unit 1 replaces it.
#if false
    @MainActor private let allNames = MigrationHarness.names

    @MainActor private func encryptHarness(
        unlocked: Bool = true, pending: PendingMigration? = nil
    ) -> MigrationHarness {
        MigrationHarness(
            files: MigrationHarness.sampleFiles(encrypted: false), lockMode: .password, pending: pending,
            unlocked: unlocked)
    }

    /// Collects the published phases until stopped.
    @MainActor
    private final class RunStatePhaseRecorder {
        private(set) var phases: [MigrationPhase] = []
        private var task: Task<Void, Never>?

        init(_ stream: AsyncStream<MigrationPhase>) {
            task = Task { [weak self] in
                for await phase in stream { self?.phases.append(phase) }
            }
        }

        var runningCount: Int {
            phases.filter {
                if case .running = $0 { return true }
                return false
            }.count
        }

        var completedCount: Int {
            phases.filter {
                if case .completed = $0 { return true }
                return false
            }.count
        }

        /// Waits until the recorded phases satisfy `predicate` (generous limit so a real bug fails, not hangs),
        /// then lets any straggling phases arrive briefly, and cancels.
        func stop(after predicate: ([MigrationPhase]) -> Bool) async {
            for _ in 0..<2000 {
                if predicate(phases) { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            try? await Task.sleep(for: .milliseconds(20))
            task?.cancel()
        }

        func stopAfterCompleted() async {
            await stop {
                $0.contains { if case .completed = $0 { return true } else { return false } }
            }
        }

        func stopAfterPaused() async {
            await stop {
                $0.contains { if case .paused = $0 { return true } else { return false } }
            }
        }
    }

    @MainActor
    @Suite struct LiveLockMigratorRunStateTests {
        @Test("A completed encrypt never calls removeKeysAfterDecryption")
        func completedEncryptNeverRemovesKeys() async {
            let harness = encryptHarness()
            await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.log.count(of: "removeKeys") == 0)
            #expect(harness.log.count(of: "finishDecryption") == 0)
        }

        @Test("An encrypt that ends failed makes no switchMode call and leaves the lock mode until Retry completes it")
        func failedEncryptLeavesLockModeUntilCompletion() async {
            let harness = encryptHarness()
            harness.store.setFailure(.io("bad"), for: "b.pdf")
            await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
            #expect(harness.migrator.phase == .failed(names: ["b.pdf"]))
            #expect(harness.log.events(withPrefix: "switchMode").isEmpty)
            #expect(harness.lock.lockMode == .password)
            harness.store.setFailure(nil, for: "b.pdf")
            await harness.migrator.retryFailed()
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(harness.log.count(of: "switchMode:passwordAndBiometrics") == 1)
            #expect(harness.lock.lockMode == .passwordAndBiometrics)
        }

        @Test("An encrypt that ends failed and is skipped leaves no switchMode call before the Skip")
        func failedEncryptMakesNoSwitchModeCallBeforeSkip() async {
            let harness = encryptHarness()
            harness.store.setFailure(.io("bad"), for: "c.mov")
            await harness.migrator.start(.encrypt, target: .passwordAndBiometrics)
            await harness.migrator.resumeIfPending()
            #expect(harness.log.events(withPrefix: "switchMode").isEmpty)
            #expect(harness.lock.lockMode == .password)
            await harness.migrator.skipFailed()
            #expect(harness.migrator.phase == .completed(fully: false))
            #expect(harness.lock.lockMode == .passwordAndBiometrics)
        }

        @Test("Repeated locked resumes start no second run; one resume after unlock completes once")
        func repeatedLockedResumesStartNoSecondRun() async {
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
            let recorder = RunStatePhaseRecorder(harness.migrator.phaseUpdates())
            let mark = harness.log.events.count
            for _ in 0..<3 { await harness.migrator.resumeIfPending() }
            #expect(harness.log.events.count == mark)
            #expect(recorder.runningCount == 0)
            guard case .paused = harness.migrator.phase else {
                Issue.record("Expected paused, got \(harness.migrator.phase)")
                return
            }
            harness.lock.restoreKey()
            await harness.migrator.resumeIfPending()
            await recorder.stopAfterCompleted()
            #expect(harness.migrator.phase == .completed(fully: true))
            #expect(recorder.completedCount == 1)
            for name in allNames {
                #expect(harness.log.count(of: "enc-done:\(name)") == 1)
            }
        }

        @Test("After a relaunch over a pending record while locked, resumeIfPending publishes paused and never running")
        func relaunchedLockedResumeSkipsRunning() async {
            let pending = PendingMigration(kind: .encrypt, targetLockMode: .password)
            let harness = encryptHarness(unlocked: false, pending: pending)
            let migrator = harness.relaunch()
            let recorder = RunStatePhaseRecorder(migrator.phaseUpdates())
            await migrator.resumeIfPending()
            await recorder.stopAfterPaused()
            #expect(recorder.runningCount == 0)
            guard case .paused = migrator.phase else {
                Issue.record("Expected paused, got \(migrator.phase)")
                return
            }
            #expect(harness.log.events(withPrefix: "enc").isEmpty)
            #expect(harness.preferences.pendingMigration == pending)
        }
    }
#endif
