import Foundation
import os

/// Encrypts an opened vault's leftover plaintext files. Feature multiple-vaults-duress-password replaces the
/// whole-vault lock migration (LockMigration unit 1 rebuilds it); until then every member fails loudly.
@MainActor
final class LiveLockMigrator: LockMigrating {
    private let store: any VaultStoring
    private let lock: any VaultLocking
    private let preferences: any PreferencesStoring
    private let uiTestFailFileName: String?

    /// - Parameters:
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

    var phase: MigrationPhase {
        fatalError("Not implemented: LiveLockMigrator.phase (feature multiple-vaults-duress-password)")
    }
    func phaseUpdates() -> AsyncStream<MigrationPhase> {
        fatalError("Not implemented: LiveLockMigrator.phaseUpdates (feature multiple-vaults-duress-password)")
    }
    func encryptLeftovers(in store: any VaultStoring) async {
        fatalError("Not implemented: LiveLockMigrator.encryptLeftovers (feature multiple-vaults-duress-password)")
    }
    func retryFailed() async {
        fatalError("Not implemented: LiveLockMigrator.retryFailed (feature multiple-vaults-duress-password)")
    }
    func skipFailed() async {
        fatalError("Not implemented: LiveLockMigrator.skipFailed (feature multiple-vaults-duress-password)")
    }
    func clearUnreadableTrash() async {
        fatalError("Not implemented: LiveLockMigrator.clearUnreadableTrash (feature multiple-vaults-duress-password)")
    }
    func cancel() {
        fatalError("Not implemented: LiveLockMigrator.cancel (feature multiple-vaults-duress-password)")
    }
}
