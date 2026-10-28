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

    override func tearDown() async throws {
        try await super.tearDown()
        AuthService.shared.lockMode = .none
    }

    func testReEncryptRowHiddenWhenUnlocked() {
        AuthService.shared.lockMode = .none
        let sut = LegacySecuritySettingsViewController(proUnlock: MockProUnlocking())
        sut.loadViewIfNeeded()
        sut.testSetHasUnencryptedFiles(true)

        XCTAssertEqual(sut.tableView(sut.testTableView, numberOfRowsInSection: 1), 3)
    }

    func testReEncryptRowHiddenWhenNoUnencryptedFiles() {
        AuthService.shared.lockMode = .password
        let sut = LegacySecuritySettingsViewController(proUnlock: MockProUnlocking())
        sut.loadViewIfNeeded()
        sut.testSetHasUnencryptedFiles(false)

        XCTAssertEqual(sut.tableView(sut.testTableView, numberOfRowsInSection: 1), 3)
    }

    func testReEncryptRowShownWhenLockedWithUnencryptedFiles() {
        AuthService.shared.lockMode = .password
        let sut = LegacySecuritySettingsViewController(proUnlock: MockProUnlocking())
        sut.loadViewIfNeeded()
        sut.testSetHasUnencryptedFiles(true)

        XCTAssertEqual(sut.tableView(sut.testTableView, numberOfRowsInSection: 1), 4)
    }
}
