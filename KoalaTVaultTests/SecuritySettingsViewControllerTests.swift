//
//  SecuritySettingsViewControllerTests.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 8/18/26.
//

import XCTest
@testable import SecureVault

final class SecuritySettingsViewControllerTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        AuthService.shared.lockMode = .none
    }

    func testReEncryptRowHiddenWhenUnlocked() {
        AuthService.shared.lockMode = .none
        let sut = SecuritySettingsViewController()
        sut.loadViewIfNeeded()
        sut.testSetHasUnencryptedFiles(true)

        XCTAssertEqual(sut.tableView(sut.testTableView, numberOfRowsInSection: 0), 3)
    }

    func testReEncryptRowHiddenWhenNoUnencryptedFiles() {
        AuthService.shared.lockMode = .password
        let sut = SecuritySettingsViewController()
        sut.loadViewIfNeeded()
        sut.testSetHasUnencryptedFiles(false)

        XCTAssertEqual(sut.tableView(sut.testTableView, numberOfRowsInSection: 0), 3)
    }

    func testReEncryptRowShownWhenLockedWithUnencryptedFiles() {
        AuthService.shared.lockMode = .password
        let sut = SecuritySettingsViewController()
        sut.loadViewIfNeeded()
        sut.testSetHasUnencryptedFiles(true)

        XCTAssertEqual(sut.tableView(sut.testTableView, numberOfRowsInSection: 0), 4)
    }
}
