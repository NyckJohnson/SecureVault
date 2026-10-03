//
//  AuthServiceTests.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/20/26.
//

import XCTest
@testable import KoalaTVault

final class AuthServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AuthService.shared.isLocked = false
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .none
        try? AuthService.shared.removePassword()
        CryptoService.shared.wipeKey()
    }

    override func tearDown() {
        super.tearDown()
        AuthService.shared.isLocked = false
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .none
        try? AuthService.shared.removePassword()
        CryptoService.shared.wipeKey()
    }

    // MARK: - Password
    func testSetAndVerifyPassword() throws {
        try AuthService.shared.createPassword("password123")
        XCTAssertNoThrow(try AuthService.shared.verifyPassword("password123"))
    }

    func testVerifyWrongPasswordThrows() throws {
        try AuthService.shared.createPassword("password123")
        XCTAssertThrowsError(try AuthService.shared.verifyPassword("wrongpassword")) { error in
            XCTAssertEqual(error as? AuthError, .wrongPassword)
        }
    }

    func testHasPasswordReturnsTrueAfterSet() throws {
        try AuthService.shared.createPassword("password123")
        XCTAssertTrue(AuthService.shared.hasPassword())
    }

    func testHasPasswordReturnsFalseAfterRemove() throws {
        try AuthService.shared.createPassword("password123")
        try? AuthService.shared.removePassword()
        XCTAssertFalse(AuthService.shared.hasPassword())
    }

    func testVerifyPasswordLoadsEncryptionKey() throws {
        try AuthService.shared.createPassword("password123")
        try AuthService.shared.verifyPassword("password123")
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
    }

    // MARK: - Change Password
    func testChangePasswordThenVerifyWithNewPassword() throws {
        try AuthService.shared.createPassword("password123")
        try AuthService.shared.verifyPassword("password123")
        try AuthService.shared.changePassword(to: "newpassword456")
        XCTAssertNoThrow(try AuthService.shared.verifyPassword("newpassword456"))
    }

    func testChangePasswordOldPasswordNoLongerVerifies() throws {
        try AuthService.shared.createPassword("password123")
        try AuthService.shared.verifyPassword("password123")
        try AuthService.shared.changePassword(to: "newpassword456")
        XCTAssertThrowsError(try AuthService.shared.verifyPassword("password123")) { error in
            XCTAssertEqual(error as? AuthError, .wrongPassword)
        }
    }

    func testVerifyWithNoPasswordSetThrowsNoMasterKeyBlob() throws {
        try AuthService.shared.removePassword()
        XCTAssertThrowsError(try AuthService.shared.verifyPassword("anything")) { error in
            XCTAssertEqual(error as? CryptoError, .noMasterKeyBlob)
        }
    }

    /// Regression test: this is the scenario that used to corrupt vault access.
    func testChangePasswordPreservesFileAccess() throws {
        try AuthService.shared.createPassword("password123")
        try AuthService.shared.verifyPassword("password123")
        let secret = "vault contents".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: secret, authenticating: ".vault_map")

        try AuthService.shared.changePassword(to: "newpassword456")
        CryptoService.shared.wipeKey()
        try AuthService.shared.verifyPassword("newpassword456")

        XCTAssertEqual(try CryptoService.shared.decrypt(data: encrypted, authenticating: ".vault_map"), secret)
    }

    // MARK: - Resign Active
    func testWillResignActiveDoesNotLockOrWipeKey() throws {
        try AuthService.shared.createPassword("password123")
        try AuthService.shared.verifyPassword("password123")
        AuthService.shared.hasAuthenticated = true
        AuthService.shared.lockMode = .password

        AuthService.shared.handleWillResignActive(in: nil)

        XCTAssertFalse(AuthService.shared.isLocked)
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
    }

    // MARK: - Lock State
    func testHandleDidEnterBackgroundLocksWhenAuthenticated() {
        AuthService.shared.hasAuthenticated = true
        AuthService.shared.lockMode = .password
        AuthService.shared.handleDidEnterBackground(in: nil)
        XCTAssertTrue(AuthService.shared.isLocked)
    }

    func testHandleDidEnterBackgroundDoesNotLockWhenNotAuthenticated() {
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .password
        AuthService.shared.handleDidEnterBackground(in: nil)
        XCTAssertFalse(AuthService.shared.isLocked)
    }

    func testHandleDidEnterBackgroundDoesNotLockWhenNoLock() {
        AuthService.shared.hasAuthenticated = true
        AuthService.shared.lockMode = .none
        AuthService.shared.handleDidEnterBackground(in: nil)
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
    func testDidEnterBackgroundWipesEncryptionKey() throws {
        try AuthService.shared.createPassword("password123")
        try AuthService.shared.verifyPassword("password123")
        AuthService.shared.hasAuthenticated = true
        AuthService.shared.lockMode = .password
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
        AuthService.shared.handleDidEnterBackground(in: nil)
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)
    }
}

final class MigrationFinalizationTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        AuthService.shared.lockMode = .none
        try? AuthService.shared.removePassword()
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
        try AuthService.shared.createPassword("testpassword")
        AuthService.shared.lockMode = .password

        AuthService.shared.finalizeMigration(type: .decrypt, targetLockMode: nil, completedFully: true)

        XCTAssertEqual(AuthService.shared.lockMode, .none)
        XCTAssertFalse(AuthService.shared.hasPassword())
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)
    }

    func testFinalizeDecryptKeepsStateOnFailure() throws {
        try AuthService.shared.createPassword("testpassword")
        AuthService.shared.lockMode = .password

        AuthService.shared.finalizeMigration(type: .decrypt, targetLockMode: nil, completedFully: false)

        XCTAssertEqual(AuthService.shared.lockMode, .password)
        XCTAssertTrue(AuthService.shared.hasPassword())
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
    }
}
