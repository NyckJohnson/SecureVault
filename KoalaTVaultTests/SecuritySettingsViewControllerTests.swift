//
//  SecuritySettingsViewControllerTests.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 8/18/26.
//

import XCTest
@testable import KoalaTVault

@MainActor
final class SecuritySettingsViewControllerTests: XCTestCase {

    func testReEncryptRowHiddenWhenUnlocked() {
        let sut = LegacySecuritySettingsViewController(
            vaultStore: MockVaultStoring(), vaultLock: MockVaultLocking(lockMode: .none), lockMigrator: MockLockMigrating(), proUnlock: MockProUnlocking())
        sut.loadViewIfNeeded()
        sut.testSetHasUnencryptedFiles(true)

        XCTAssertEqual(sut.tableView(sut.testTableView, numberOfRowsInSection: 1), 3)
    }

    func testReEncryptRowHiddenWhenNoUnencryptedFiles() {
        let sut = LegacySecuritySettingsViewController(
            vaultStore: MockVaultStoring(), vaultLock: MockVaultLocking(lockMode: .password), lockMigrator: MockLockMigrating(), proUnlock: MockProUnlocking())
        sut.loadViewIfNeeded()
        sut.testSetHasUnencryptedFiles(false)

        XCTAssertEqual(sut.tableView(sut.testTableView, numberOfRowsInSection: 1), 3)
    }

    func testReEncryptRowShownWhenLockedWithUnencryptedFiles() {
        let sut = LegacySecuritySettingsViewController(
            vaultStore: MockVaultStoring(), vaultLock: MockVaultLocking(lockMode: .password), lockMigrator: MockLockMigrating(), proUnlock: MockProUnlocking())
        sut.loadViewIfNeeded()
        sut.testSetHasUnencryptedFiles(true)

        XCTAssertEqual(sut.tableView(sut.testTableView, numberOfRowsInSection: 1), 4)
    }
}
