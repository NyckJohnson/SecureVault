import Foundation
import os

/// Encrypts the plaintext files an encrypted vault still holds (left by a 1.2 lock change) when it opens,
/// one file at a time, through the store it is handed.
///
/// Nothing is persisted: whatever is left unencrypted is listed again the next time the vault opens.
/// `cancel()` (the vault closed) and a `.locked` error from the store end the run: the file in progress
/// finishes or fails without being counted, and the phase becomes `.idle`.
@MainActor
final class LiveLockMigrator: LockMigrating {
    /// The run in this process: the vault it works on and how far it got.
    private struct Run {
        let store: any VaultStoring
        var progress = MigrationProgress()
        /// The files to encrypt have been listed.
        var listed = false
    }

    private static let logger = Logger(subsystem: "com.KoalaTVault", category: "LockMigration")

    private let uiTestFailFileName: String?
    private let broadcast = MigrationPhaseBroadcast()
    private var run: Run?
    /// Bumped by every cancel; a runner whose generation is stale stops at its next step.
    private var generation = 0
    /// The generation of the runner under way (a pass, a retry or a clear); at most one runs at a time.
    private var busyGeneration: Int?
    /// Callers waiting for a cancelled runner to finish its file in progress.
    private var runnerExitWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - uiTestFailFileName: `UITEST_FAIL_MIGRATION_FILE` in UI-test mode only; the file with this display
    ///     name fails every time it is encrypted.
    init(uiTestFailFileName: String? = nil) {
        self.uiTestFailFileName = uiTestFailFileName
    }

    var phase: MigrationPhase { broadcast.phase }

    func phaseUpdates() -> AsyncStream<MigrationPhase> {
        broadcast.updates()
    }

    func encryptLeftovers(in store: any VaultStoring) async {
        guard store.isEncrypted else { return }
        // A cancelled runner still finishing its file in progress must end before a new run touches a vault.
        await waitForCancelledRunner()
        // One runner: a run that exists (running, failed, unreadable trash) must end first.
        guard busyGeneration == nil, run == nil else { return }
        run = Run(store: store)
        await runExclusively { generation in
            await self.drive(generation)
        }
    }

    func retryFailed() async {
        guard busyGeneration == nil, case .failed = phase, run != nil else { return }
        // A listing failure leaves nothing listed: the drive lists again. Otherwise only the failed files.
        if run?.listed == true { run?.progress.restartWithFailed() }
        // Publish `.running` first, so that the same failure happening again is a change subscribers hear about.
        if let progress = run?.progress { broadcast.update(progress.running) }
        await runExclusively { generation in
            await self.drive(generation)
        }
    }

    func skipFailed() async {
        guard busyGeneration == nil, awaitsUserChoice, run != nil else { return }
        run = nil
        broadcast.update(.completed(fully: false))
    }

    func clearUnreadableTrash() async {
        guard busyGeneration == nil, phase == .unreadableTrash, let store = run?.store else { return }
        // The run continues from a fresh listing: files already encrypted are not listed again.
        run?.listed = false
        run?.progress = MigrationProgress()
        if let progress = run?.progress { broadcast.update(progress.running) }
        await runExclusively { generation in
            do {
                try await store.clearUnreadableTrash()
            } catch {
                guard self.isCurrent(generation) else { return }
                if Self.isLocked(error) {
                    self.endRun()
                } else {
                    // Not `publishFailure`: the trash is still unreadable, and asking again would loop back here.
                    Self.logger.error(
                        "Clearing unreadable trash failed: \(String(describing: error), privacy: .private)")
                    self.broadcast.update(.failed(names: []))
                }
                return
            }
            guard self.isCurrent(generation) else { return }
            await self.drive(generation)
        }
    }

    func cancel() {
        endRun()
    }

    // MARK: - Running

    /// The run stopped on failures or unreadable trash and waits for Retry, Skip or Clear.
    private var awaitsUserChoice: Bool {
        switch phase {
        case .failed, .unreadableTrash: true
        default: false
        }
    }

    private func isCurrent(_ runGeneration: Int) -> Bool {
        runGeneration == generation && run != nil
    }

    private static func isLocked(_ error: any Error) -> Bool {
        (error as? VaultStoreError) == .locked
    }

    /// Runs `body` as the one runner, then wakes callers waiting for it to end.
    private func runExclusively(_ body: (Int) async -> Void) async {
        let runGeneration = generation
        busyGeneration = runGeneration
        await body(runGeneration)
        busyGeneration = nil
        let waiters = runnerExitWaiters
        runnerExitWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func waitForCancelledRunner() async {
        while let busy = busyGeneration, busy != generation {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                runnerExitWaiters.append(continuation)
            }
        }
    }

    /// Lists (once), encrypts the remaining files, then runs the closing step. Stops at a cancel, a lock or a
    /// failure, keeping a failed run so Retry, Skip or Clear can continue it.
    private func drive(_ runGeneration: Int) async {
        guard let store = run?.store else { return }
        if run?.listed == false {
            guard await list(store: store, runGeneration: runGeneration) else { return }
        }

        guard await encryptRemaining(store: store, runGeneration: runGeneration) else { return }
        if let progress = run?.progress, !progress.failed.isEmpty {
            await publishFailure(progress.failedPhase, store: store, runGeneration: runGeneration)
            return
        }

        do {
            try await store.finishEncryption()
        } catch {
            guard isCurrent(runGeneration) else { return }
            if Self.isLocked(error) {
                endRun()
                return
            }
            // Every file is safe; the next save of that folder's index encrypts it.
            Self.logger.error("Re-encrypting folder indexes failed: \(String(describing: error), privacy: .private)")
        }
        guard isCurrent(runGeneration) else { return }
        run = nil
        broadcast.update(.completed(fully: true))
    }

    /// Lists the files to encrypt into a fresh pass; false when the run stopped (ended, or failed).
    private func list(store: any VaultStoring, runGeneration: Int) async -> Bool {
        let items: [VaultItem]
        do {
            items = try await store.itemsToEncrypt()
        } catch {
            guard isCurrent(runGeneration) else { return false }
            if Self.isLocked(error) {
                endRun()
            } else {
                Self.logger.error("Listing files to encrypt failed: \(String(describing: error), privacy: .private)")
                await publishFailure(.failed(names: []), store: store, runGeneration: runGeneration)
            }
            return false
        }
        guard isCurrent(runGeneration) else { return false }
        run?.progress = MigrationProgress()
        run?.progress.items = items
        run?.listed = true
        // With nothing to encrypt the run goes straight to completed, without a `.running(0, 0)`.
        if !items.isEmpty, let progress = run?.progress { broadcast.update(progress.running) }
        return true
    }

    /// Encrypts the rest of the pass; false when the run ended (cancelled or locked).
    private func encryptRemaining(store: any VaultStoring, runGeneration: Int) async -> Bool {
        while let item = run?.progress.next {
            do {
                try await encrypt(item, in: store)
                guard isCurrent(runGeneration) else { return false }
                run?.progress.advance()
            } catch {
                // The file in progress during a cancel is not counted, whether it finished or failed.
                guard isCurrent(runGeneration) else { return false }
                if Self.isLocked(error) {
                    endRun()
                    return false
                }
                run?.progress.fail()
            }
            if let progress = run?.progress { broadcast.update(progress.running) }
        }
        return isCurrent(runGeneration)
    }

    private func encrypt(_ item: VaultItem, in store: any VaultStoring) async throws {
        if let uiTestFailFileName, item.name == uiTestFailFileName {
            throw VaultStoreError.io("UI-test failure for this file")
        }
        try await store.migrateToEncrypted(item)
    }

    /// Publishes `failure`, or `.unreadableTrash` when the trash holds items that can never be decrypted
    /// (the likely cause, which only clearing the trash fixes).
    private func publishFailure(_ failure: MigrationPhase, store: any VaultStoring, runGeneration: Int) async {
        let unreadable = await store.hasUnreadableTrash()
        guard isCurrent(runGeneration) else { return }
        broadcast.update(unreadable ? .unreadableTrash : failure)
    }

    /// Ends the run as a cancel does: any runner stops at its next step and the phase is `.idle`.
    private func endRun() {
        generation += 1
        run = nil
        broadcast.update(.idle)
    }
}
