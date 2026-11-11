//
//  PostUnlockMaintenance.swift
//  KoalaTVault
//
//  The app shell's housekeeping after an encrypted vault opens.
//

import Foundation

/// The vault housekeeping the app runs each time an encrypted vault opens, once its key is loaded and its folder
/// indexes can be read.
enum PostUnlockMaintenance {
    /// Purges trash items older than 30 days, then sweeps orphaned files.
    ///
    /// A purge failure (for example an unreadable trash map, which is never overwritten) is ignored on purpose: the
    /// purge runs again the next time the vault opens, and the sweep still runs.
    /// - Parameters:
    ///   - vaultStore: the opened vault's store.
    ///   - now: the current time, which decides which trash items have expired.
    static func run(vaultStore: any VaultStoring, now: Date) async {
        _ = try? await vaultStore.purgeExpiredTrash(now: now)
        await vaultStore.sweepOrphans()
    }
}
