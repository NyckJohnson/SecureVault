//
//  AuthServiceTests.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/20/26.
//

import XCTest
@testable import SecureVault

final class AuthServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AuthService.shared.isLocked = false
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .none
        AuthService.shared.removePassword()
        CryptoService.shared.wipeKey()
    }

    override func tearDown() {
        super.tearDown()
        AuthService.shared.isLocked = false
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .none
        AuthService.shared.removePassword()
        CryptoService.shared.wipeKey()
    }

    // MARK: - Password
    func testSetAndVerifyPassword() throws {
        try AuthService.shared.setPassword("password123")
        XCTAssertNoThrow(try AuthService.shared.verifyPassword("password123"))
    }

    func testVerifyWrongPasswordThrows() throws {
        try AuthService.shared.setPassword("password123")
        XCTAssertThrowsError(try AuthService.shared.verifyPassword("wrongpassword"))
    }

    func testHasPasswordReturnsTrueAfterSet() throws {
        try AuthService.shared.setPassword("password123")
        XCTAssertTrue(AuthService.shared.hasPassword())
    }

    func testHasPasswordReturnsFalseAfterRemove() throws {
        try AuthService.shared.setPassword("password123")
        AuthService.shared.removePassword()
        XCTAssertFalse(AuthService.shared.hasPassword())
    }

    func testVerifyPasswordLoadsEncryptionKey() throws {
        try AuthService.shared.setPassword("password123")
        try AuthService.shared.verifyPassword("password123")
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
    }

    // MARK: - Lock State
    func testHandleBackgroundLocksWhenAuthenticated() {
        AuthService.shared.hasAuthenticated = true
        AuthService.shared.lockMode = .password
        AuthService.shared.handleBackground(in: nil)
        XCTAssertTrue(AuthService.shared.isLocked)
    }

    func testHandleBackgroundDoesNotLockWhenNotAuthenticated() {
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .password
        AuthService.shared.handleBackground(in: nil)
        XCTAssertFalse(AuthService.shared.isLocked)
    }

    func testHandleBackgroundDoesNotLockWhenNoLock() {
        AuthService.shared.hasAuthenticated = true
        AuthService.shared.lockMode = .none
        AuthService.shared.handleBackground(in: nil)
        XCTAssertFalse(AuthService.shared.isLocked)
    }

    func testIsLockedTrueWhenLocked() {
        AuthService.shared.lockMode = .password
        AuthService.shared.isLocked = true
        XCTAssertTrue(AuthService.shared.isLocked)
    }

    func testIsLockedFalseWhenNotLocked() {
        AuthService.shared.lockMode = .password
        AuthService.shared.isLocked = false
        XCTAssertFalse(AuthService.shared.isLocked)
    }

    func testNoLockModeIsNone() {
        AuthService.shared.lockMode = .none
        XCTAssertEqual(AuthService.shared.lockMode, .none)
    }

    // MARK: - Background wipes key
    func testBackgroundWipesEncryptionKey() throws {
        try AuthService.shared.setPassword("password123")
        try AuthService.shared.verifyPassword("password123")
        AuthService.shared.hasAuthenticated = true
        AuthService.shared.lockMode = .password
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
        AuthService.shared.handleBackground(in: nil)
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)
    }
}

final class MigrationFinalizationTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        AuthService.shared.lockMode = .none
        AuthService.shared.removePassword()
        CryptoService.shared.wipeKey()
    }

    func testFinalizeEncryptSetsTargetLockModeOnSuccess() {
        AuthService.shared.finalizeMigration(type: .encrypt, targetLockMode: .password, completedFully: true)
        XCTAssertEqual(AuthService.shared.lockMode, .password)
    }

    func testFinalizeEncryptDoesNotSetLockModeOnFailure() {
        AuthService.shared.lockMode = .none
        AuthService.shared.finalizeMigration(type: .encrypt, targetLockMode: .password, completedFully: false)
        XCTAssertEqual(AuthService.shared.lockMode, .none)
    }

    func testFinalizeDecryptClearsStateOnSuccess() throws {
        try CryptoService.shared.loadKey(from: "testpassword")
        try AuthService.shared.setPassword("testpassword")
        AuthService.shared.lockMode = .password

        AuthService.shared.finalizeMigration(type: .decrypt, targetLockMode: nil, completedFully: true)

        XCTAssertEqual(AuthService.shared.lockMode, .none)
        XCTAssertFalse(AuthService.shared.hasPassword())
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)
    }

    func testFinalizeDecryptKeepsStateOnFailure() throws {
        try CryptoService.shared.loadKey(from: "testpassword")
        try AuthService.shared.setPassword("testpassword")
        AuthService.shared.lockMode = .password

        AuthService.shared.finalizeMigration(type: .decrypt, targetLockMode: nil, completedFully: false)

        XCTAssertEqual(AuthService.shared.lockMode, .password)
        XCTAssertTrue(AuthService.shared.hasPassword())
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
    }
}
