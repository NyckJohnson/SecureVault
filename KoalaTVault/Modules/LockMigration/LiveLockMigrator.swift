import Foundation
import os

/// Encrypts or decrypts the whole vault (trash included) through the vault store, one file at a time.
///
/// The persisted pending record (`PreferencesStoring.pendingMigration`) is written before the first file and
/// cleared as the very last step, so a kill at any point leaves a record that `resumeIfPending` completes.
/// Work needs the master key: whenever the lock reports `.locked` the migration pauses, and the file in
/// progress is not counted as failed.
@MainActor
final class LiveLockMigrator: LockMigrating {
    /// One migration in this process: the persisted record and how far it got.
    private struct Run {
        let record: PendingMigration
        var progress = MigrationProgress()
        /// The files to migrate have been listed.
        var listed = false
        /// Decrypt only: the closing re-scan for files that appeared meanwhile has been done.
        var rescanned = false

        var encrypting: Bool { record.kind == .encrypt }
    }

    private static let logger = Logger(subsystem: "com.KoalaTVault", category: "LockMigration")

    private let store: any VaultStoring
    private let lock: any VaultLocking
    private let preferences: any PreferencesStoring
    private let uiTestFailFileName: String?
    private let broadcast = MigrationPhaseBroadcast()
    private var run: Run?
    /// True while a pass, a retry or a skip is under way; at most one runs at a time.
    private var isBusy = false

    /// - Parameters:
    ///   - store: the vault store that migrates each file.
    ///   - lock: the vault lock; its state says whether the key is loaded, and it removes the keys after a decrypt.
    ///   - preferences: where the pending record is persisted.
    ///   - uiTestFailFileName: `UITEST_FAIL_MIGRATION_FILE` in UI-test mode only; the file with this display
    ///     name fails every time it is migrated.
    init(
        store: any VaultStoring, lock: any VaultLocking, preferences: any PreferencesStoring,
        uiTestFailFileName: String? = nil
    ) {
        self.store = store
        self.lock = lock
        self.preferences = preferences
        self.uiTestFailFileName = uiTestFailFileName
    }

    var phase: MigrationPhase { broadcast.phase }

    var pending: PendingMigration? { preferences.pendingMigration }

    func phaseUpdates() -> AsyncStream<MigrationPhase> {
        broadcast.updates()
    }

    func start(_ kind: MigrationKind, target: LockMode?) async {
        guard !isBusy else { return }
        let record = PendingMigration(kind: kind, targetLockMode: kind == .encrypt ? target : nil)
        preferences.pendingMigration = record
        run = Run(record: record)
        await drive()
    }

    func resumeIfPending() async {
        guard !isBusy, let record = preferences.pendingMigration else { return }
        // Failures wait for the user's retry or skip.
        if case .failed = phase { return }
        if run?.record != record {
            run = Run(record: record)
        }
        await drive()
    }

    func retryFailed() async {
        guard !isBusy, case .failed = phase, run != nil else { return }
        run?.progress.restartWithFailed()
        run?.rescanned = false
        await drive()
    }

    func skipFailed() async {
        guard !isBusy, case .failed = phase, let run else { return }
        isBusy = true
        defer { isBusy = false }
        if run.encrypting {
            // The lock stays at the target; the files left in plaintext are offered "Re-encrypt Everything".
            do {
                try await applyTarget(of: run)
            } catch {
                Self.logger.error(
                    "Switching to the target lock mode failed: \(String(describing: error), privacy: .private)")
            }
        }
        complete(fully: false)
    }

    // MARK: - Running

    private var keyLoaded: Bool { lock.state != .locked }

    /// Lists (once), migrates the remaining files, re-scans (decrypt), then runs the closing steps.
    /// Stops at a pause or a failure, keeping the run so the next call continues where it stopped.
    private func drive() async {
        guard !isBusy, let current = run else { return }
        isBusy = true
        defer { isBusy = false }

        if !current.listed {
            guard let items = await list(encrypting: current.encrypting) else { return }
            run?.progress.items = items
            run?.listed = true
        }
        if let progress = run?.progress { broadcast.update(progress.running) }
        guard await migrateRemaining(), noFailures() else { return }

        if !current.encrypting, run?.rescanned == false {
            guard let items = await list(encrypting: false) else { return }
            run?.progress.items.append(contentsOf: items)
            run?.rescanned = true
            if let progress = run?.progress { broadcast.update(progress.running) }
            guard await migrateRemaining(), noFailures() else { return }
        }

        guard await finish() else { return }
        complete(fully: true)
    }

    /// The files still to migrate, or nil when the run stopped (paused, or failed with the key loaded).
    private func list(encrypting: Bool) async -> [VaultItem]? {
        guard keyLoaded else {
            pause()
            return nil
        }
        do {
            return try await store.itemsToMigrate(toEncrypted: encrypting)
        } catch {
            stop(after: error)
            return nil
        }
    }

    /// Migrates the rest of the pass; false when it paused.
    private func migrateRemaining() async -> Bool {
        while let current = run, let item = current.progress.next {
            guard keyLoaded else {
                pause()
                return false
            }
            do {
                try await migrate(item, encrypting: current.encrypting)
                run?.progress.advance()
            } catch {
                if isInterruption(error) {
                    pause()
                    return false
                }
                run?.progress.fail()
            }
            if let progress = run?.progress { broadcast.update(progress.running) }
        }
        return true
    }

    private func migrate(_ item: VaultItem, encrypting: Bool) async throws {
        if let uiTestFailFileName, item.name == uiTestFailFileName {
            throw VaultStoreError.io("UI-test failure for this file")
        }
        if encrypting {
            try await store.migrateToEncrypted(item)
        } else {
            try await store.migrateToDecrypted(item)
        }
    }

    /// Publishes the failures if the pass had any; true when it had none.
    private func noFailures() -> Bool {
        guard let progress = run?.progress, !progress.failed.isEmpty else { return true }
        broadcast.update(progress.failedPhase)
        return false
    }

    /// The closing steps, after every file migrated; false when the run stopped.
    ///
    /// Encrypt: `finishEncryption` (a failure with the key loaded is logged and does not stop the migration, as
    /// in the legacy app: every file is safe, and the next save of that folder's index encrypts it), then the
    /// target lock mode. Decrypt: `finishDecryption`, then `removeKeysAfterDecryption`. Each step is safe to redo.
    private func finish() async -> Bool {
        guard let current = run else { return false }
        guard keyLoaded else {
            pause()
            return false
        }
        do {
            if current.encrypting {
                do {
                    try await store.finishEncryption()
                } catch where !isInterruption(error) {
                    Self.logger.error(
                        "Re-encrypting folder indexes failed: \(String(describing: error), privacy: .private)")
                }
                try await applyTarget(of: current)
            } else {
                try await store.finishDecryption()
                try await lock.removeKeysAfterDecryption()
            }
            return true
        } catch {
            stop(after: error)
            return false
        }
    }

    private func applyTarget(of run: Run) async throws {
        guard let target = run.record.targetLockMode, lock.lockMode != target else { return }
        try await lock.switchMode(to: target)
    }

    // MARK: - Phases

    /// A key wipe, not the file, made the step fail.
    private func isInterruption(_ error: any Error) -> Bool {
        (error as? VaultStoreError) == .locked || !keyLoaded
    }

    /// Pauses on a key wipe; otherwise reports the failure, so Retry redoes the step and Skip gives up.
    private func stop(after error: any Error) {
        if isInterruption(error) {
            pause()
            return
        }
        Self.logger.error("Lock migration step failed: \(String(describing: error), privacy: .private)")
        broadcast.update(run?.progress.failedPhase ?? .failed(names: []))
    }

    private func pause() {
        broadcast.update(run?.progress.paused ?? .paused(done: 0, total: 0))
    }

    /// Clears the pending record last, then publishes the end.
    private func complete(fully: Bool) {
        run = nil
        preferences.pendingMigration = nil
        broadcast.update(.completed(fully: fully))
    }
}
