import Foundation
import os

/// The one-time upgrade from the single vault of 1.2 to the vaults model (feature multiple-vaults-duress-password),
/// behind `VaultLocking.upgradeIfNeeded()`; run once at launch before anything shows.
///
/// If the old app had a lock (a lock mode other than none, or a pending encrypt while the old blob exists), every
/// entry of Documents moves into `Vaults/primary/`, and a password + biometrics lock gives that vault Face ID.
/// Then the pending migration is cleared and `vaultsUpgraded` is set, last. Each step can be repeated, so after a
/// failure the next launch carries on from what is left. `hasCompletedSetup` and `lockMode` are never written.
struct VaultUpgrade: Sendable {
    private static let logger = Logger(subsystem: "com.KoalaTVault", category: "VaultUpgrade")

    private let documents: URL
    private let catalog: VaultCatalog
    private let keychain: any KeychainAccessing
    private let preferences: any PreferencesStoring

    /// An upgrade moving the vault in `documents` into `vaultsFolder`, using `keychain` for the old blob and the
    /// Face ID marker, and `preferences` for the old lock settings and the `vaultsUpgraded` flag.
    init(documents: URL, vaultsFolder: URL, keychain: any KeychainAccessing, preferences: any PreferencesStoring) {
        self.documents = documents
        self.catalog = VaultCatalog(vaultsFolder: vaultsFolder, keychain: keychain)
        self.keychain = keychain
        self.preferences = preferences
    }

    /// Runs the upgrade if it has not completed yet.
    /// - Throws: a file-system error creating the primary folder or moving an entry, or `VaultCryptoError.keychain`
    ///   writing the Face ID marker. `vaultsUpgraded` stays false, so the next launch runs it again.
    func run() throws {
        guard !preferences.vaultsUpgraded else { return }
        if hadLock() {
            try moveDocumentsIntoPrimary()
            if preferences.lockMode == .passwordAndBiometrics {
                try catalog.setBiometricVaultID(VaultCatalog.primaryID)
            }
        }
        if preferences.pendingMigration != nil {
            preferences.pendingMigration = nil
        }
        preferences.vaultsUpgraded = true
    }

    /// Whether the old app had a lock: a lock mode other than none, or a pending encrypt while the old blob exists.
    private func hadLock() -> Bool {
        if preferences.lockMode != .none { return true }
        guard preferences.pendingMigration?.kind == .encrypt else { return false }
        do {
            return try keychain.read(account: VaultCatalog.blobAccount(for: VaultCatalog.primaryID), prompt: nil) != nil
        } catch {
            // A Keychain error counts as a blob: dropping a real vault's lock would be worse than keeping it.
            return true
        }
    }

    /// Moves every entry of Documents (hidden ones included) into `Vaults/primary/`. Moves only: an entry whose
    /// name is already there stays in Documents and is logged, never overwritten.
    private func moveDocumentsIntoPrimary() throws {
        let manager = FileManager.default
        let primary = catalog.folderURL(for: VaultCatalog.primaryID)
        try manager.createDirectory(at: primary, withIntermediateDirectories: true)
        let entries = try manager.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil, options: [])
        for entry in entries {
            let destination = primary.appendingPathComponent(entry.lastPathComponent)
            if manager.fileExists(atPath: destination.path) {
                Self.logger.error("Upgrade left an entry in Documents: its name is already in the primary vault")
                continue
            }
            try manager.moveItem(at: entry, to: destination)
        }
    }
}
