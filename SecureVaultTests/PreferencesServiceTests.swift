//
//  Untitled.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/20/26.
//

import XCTest
@testable import SecureVault

final class PreferencesServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // reset to clean state before each test
        PreferencesService.shared.hasCompletedSetup = false
        PreferencesService.shared.lockMode = .none
    }

    override func tearDown() {
        super.tearDown()
        PreferencesService.shared.hasCompletedSetup = false
        PreferencesService.shared.lockMode = .none
    }

    // MARK: - Setup
    func testHasCompletedSetupDefaultsFalse() {
        XCTAssertFalse(PreferencesService.shared.hasCompletedSetup)
    }

    func testHasCompletedSetupCanBeSetTrue() {
        PreferencesService.shared.hasCompletedSetup = true
        XCTAssertTrue(PreferencesService.shared.hasCompletedSetup)
    }

    func testHasCompletedSetupPersists() {
        PreferencesService.shared.hasCompletedSetup = true
        // read it back fresh
        XCTAssertTrue(PreferencesService.shared.hasCompletedSetup)
    }

    // MARK: - Lock Mode
    func testLockModeDefaultsToNone() {
        XCTAssertEqual(PreferencesService.shared.lockMode, .none)
    }

    func testLockModeCanBeSetToPassword() {
        PreferencesService.shared.lockMode = .password
        XCTAssertEqual(PreferencesService.shared.lockMode, .password)
    }

    func testLockModeCanBeSetToPasswordAndBiometrics() {
        PreferencesService.shared.lockMode = .passwordAndBiometrics
        XCTAssertEqual(PreferencesService.shared.lockMode, .passwordAndBiometrics)
    }

    func testLockModeCanBeResetToNone() {
        PreferencesService.shared.lockMode = .password
        PreferencesService.shared.lockMode = .none
        XCTAssertEqual(PreferencesService.shared.lockMode, .none)
    }

    func testLockModePersists() {
        PreferencesService.shared.lockMode = .password
        XCTAssertEqual(PreferencesService.shared.lockMode, .password)
    }

    // MARK: - Pending Migration
    func testPendingMigrationTypeRoundTrips() {
        PreferencesService.shared.pendingMigrationType = nil
        XCTAssertNil(PreferencesService.shared.pendingMigrationType)
        PreferencesService.shared.pendingMigrationType = .encrypt
        XCTAssertEqual(PreferencesService.shared.pendingMigrationType, .encrypt)
        PreferencesService.shared.pendingMigrationType = nil
        XCTAssertNil(PreferencesService.shared.pendingMigrationType)
    }

    func testPendingMigrationTargetLockModeRoundTrips() {
        PreferencesService.shared.pendingMigrationTargetLockMode = .passwordAndBiometrics
        XCTAssertEqual(PreferencesService.shared.pendingMigrationTargetLockMode, .passwordAndBiometrics)
        PreferencesService.shared.pendingMigrationTargetLockMode = nil
        XCTAssertNil(PreferencesService.shared.pendingMigrationTargetLockMode)
    }
}
