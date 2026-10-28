//
//  AuthServiceTests.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/20/26.
//

import XCTest
@testable import KoalaTVault

@MainActor
final class AuthServiceTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        AuthService.shared.isLocked = false
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .none
        try? AuthService.shared.removePassword()
        TestCrypto.keyStore.wipeKey()
    }

    override func tearDown() async throws {
        try await super.tearDown()
        AuthService.shared.isLocked = false
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .none
        try? AuthService.shared.removePassword()
        TestCrypto.keyStore.wipeKey()
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
        XCTAssertTrue(TestCrypto.keyStore.isKeyLoaded)
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
            XCTAssertEqual(error as? VaultCryptoError, .noMasterKeyBlob)
        }
    }

    /// Regression test: this is the scenario that used to corrupt vault access.
    func testChangePasswordPreservesFileAccess() throws {
        try AuthService.shared.createPassword("password123")
        try AuthService.shared.verifyPassword("password123")
        let secret = "vault contents".data(using: .utf8)!
        let encrypted = try TestCrypto.cipher.encrypt(secret, context: ".vault_map")

        try AuthService.shared.changePassword(to: "newpassword456")
        TestCrypto.keyStore.wipeKey()
        try AuthService.shared.verifyPassword("newpassword456")

        XCTAssertEqual(try TestCrypto.cipher.decrypt(encrypted, contexts: [".vault_map"]), secret)
    }

    // MARK: - Resign Active
    func testWillResignActiveDoesNotLockOrWipeKey() throws {
        try AuthService.shared.createPassword("password123")
        try AuthService.shared.verifyPassword("password123")
        AuthService.shared.hasAuthenticated = true
        AuthService.shared.lockMode = .password

        AuthService.shared.handleWillResignActive(in: nil)

        XCTAssertFalse(AuthService.shared.isLocked)
        XCTAssertTrue(TestCrypto.keyStore.isKeyLoaded)
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
        XCTAssertTrue(TestCrypto.keyStore.isKeyLoaded)
        AuthService.shared.handleDidEnterBackground(in: nil)
        XCTAssertFalse(TestCrypto.keyStore.isKeyLoaded)
    }
}

// MARK: - AuthServiceForegroundTests

@MainActor
final class AuthServiceForegroundTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        AuthService.shared.isLocked = false
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .none
    }

    override func tearDown() async throws {
        AuthService.shared.isLocked = false
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .none
        try await super.tearDown()
    }

    // MARK: - handleForeground

    func testHandleForegroundWithNoLockSetsHasAuthenticated() {
        AuthService.shared.lockMode = .none
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.handleForeground(in: nil)
        XCTAssertTrue(AuthService.shared.hasAuthenticated)
    }

    func testHandleForegroundWithNoLockDoesNotSetIsLocked() {
        AuthService.shared.lockMode = .none
        AuthService.shared.isLocked = false
        AuthService.shared.handleForeground(in: nil)
        XCTAssertFalse(AuthService.shared.isLocked)
    }

    func testHandleForegroundWhenLockedKeepsIsLockedTrue() {
        AuthService.shared.lockMode = .password
        AuthService.shared.isLocked = true
        AuthService.shared.handleForeground(in: nil)
        XCTAssertTrue(AuthService.shared.isLocked)
    }

    func testHandleForegroundWhenNotLockedKeepsIsLockedFalse() {
        AuthService.shared.lockMode = .password
        AuthService.shared.isLocked = false
        AuthService.shared.handleForeground(in: nil)
        XCTAssertFalse(AuthService.shared.isLocked)
    }

    // MARK: - handleInitialLaunch

    func testHandleInitialLaunchWithNoLockPostsUnlockNotification() {
        AuthService.shared.lockMode = .none
        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: AuthService.vaultUnlockedNotification, object: nil, queue: .main
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }
        AuthService.shared.handleInitialLaunch(in: nil)
        XCTAssertTrue(received)
    }

    func testHandleInitialLaunchWithPasswordSetsIsLocked() {
        AuthService.shared.lockMode = .password
        AuthService.shared.isLocked = false
        AuthService.shared.handleInitialLaunch(in: nil)
        XCTAssertTrue(AuthService.shared.isLocked)
    }

    func testHandleInitialLaunchWithNoLockDoesNotSetIsLocked() {
        AuthService.shared.lockMode = .none
        AuthService.shared.handleInitialLaunch(in: nil)
        XCTAssertFalse(AuthService.shared.isLocked)
    }

    // MARK: - biometricType

    func testBiometricTypeReturnsNonEmptyString() {
        XCTAssertFalse(AuthService.shared.biometricType.isEmpty)
    }

    // MARK: - removeBiometricSecret

    func testRemoveBiometricSecretDoesNotCrashWhenNoItemExists() {
        XCTAssertNoThrow(AuthService.shared.removeBiometricSecret())
    }

    func testRemoveBiometricSecretIsIdempotent() {
        AuthService.shared.removeBiometricSecret()
        XCTAssertNoThrow(AuthService.shared.removeBiometricSecret())
    }

    // MARK: - lockMode delegation

    func testLockModeGetterReflectsPreferences() {
        LegacyStorage.current.preferences.lockMode = .passwordAndBiometrics
        XCTAssertEqual(AuthService.shared.lockMode, .passwordAndBiometrics)
        LegacyStorage.current.preferences.lockMode = .none
    }

    func testLockModeSetterUpdatesPreferences() {
        AuthService.shared.lockMode = .password
        XCTAssertEqual(LegacyStorage.current.preferences.lockMode, .password)
        AuthService.shared.lockMode = .none
    }
}

// MARK: - MigrationFinalizationTests

@MainActor
final class MigrationFinalizationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AuthService.shared.lockMode = .none
        try? AuthService.shared.removePassword()
        TestCrypto.keyStore.wipeKey()
    }

    override func tearDown() async throws {
        try await super.tearDown()
        AuthService.shared.lockMode = .none
        try? AuthService.shared.removePassword()
        TestCrypto.keyStore.wipeKey()
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
        XCTAssertFalse(TestCrypto.keyStore.isKeyLoaded)
    }

    func testFinalizeDecryptKeepsStateOnFailure() throws {
        try AuthService.shared.createPassword("testpassword")
        AuthService.shared.lockMode = .password

        AuthService.shared.finalizeMigration(type: .decrypt, targetLockMode: nil, completedFully: false)

        XCTAssertEqual(AuthService.shared.lockMode, .password)
        XCTAssertTrue(AuthService.shared.hasPassword())
        XCTAssertTrue(TestCrypto.keyStore.isKeyLoaded)
    }
}
