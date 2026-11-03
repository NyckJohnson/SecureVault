//
//  FileSystem.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/17/26.
//
//  All that remains of the old `FileSystem`: the notification posted after Recently Deleted restores an item
//  (the composition root posts it from the Settings factory's `onRestore`), which the browser observes.
//  Export is the Export module's `VaultExporting`, import the Import module's `VaultImporting`,
//  and everything else the VaultStore module's `VaultStoring`.
//

import Foundation

extension Notification.Name {
    static let fileRestored = Notification.Name("FileRestored")
}
