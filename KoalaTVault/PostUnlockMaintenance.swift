//
//  PostUnlockMaintenance.swift
//  KoalaTVault
//
//  The app shell's housekeeping after every unlock.
//

import Foundation

/// The vault housekeeping the app runs after each unlock, once the key is loaded and the folder indexes
/// can be read.
enum PostUnlockMaintenance {
    /// Purges trash items older than 30 days, then sweeps orphaned files unless a lock migration is pending.
    ///
    /// A purge failure (for example an unreadable trash map, which is never overwritten) is ignored: the
    /// purge runs again after the next unlock. A pending migration has copies that aren't indexed yet, so the
    /// sweep (which would take them for orphans) waits until the migration has finished.
    /// - Parameters:
    ///   - vaultStore: the app's vault store.
    ///   - preferences: the app's preferences, read for the pending migration.
    ///   - now: the current time, which decides which trash items have expired.
    static func run(vaultStore: any VaultStoring, preferences: any PreferencesStoring, now: Date) async {
        _ = try? await vaultStore.purgeExpiredTrash(now: now)
        guard preferences.pendingMigration == nil else { return }
        await vaultStore.sweepOrphans()
    }
}
