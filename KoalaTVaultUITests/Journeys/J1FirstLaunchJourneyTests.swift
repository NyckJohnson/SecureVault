//
//  J1FirstLaunchJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 1: First launch. A new user sees the lock screen (no setup wizard); "Open Unencrypted Vault" shows the
//  unencrypted vault's empty root. Journey 10 covers creating an encrypted vault.
//

import XCTest

final class J1FirstLaunchJourneyTests: JourneyTestCase {

    func testJourney1_FirstLaunchShowsLockScreenAndNoSetupWizard() {
        waitForLockScreen()
        XCTAssertTrue(app.buttons["vaults.openButton"].exists, "Open button missing")
        XCTAssertTrue(app.buttons["vaults.unencryptedButton"].exists, "Open Unencrypted Vault missing")
        XCTAssertTrue(app.buttons["vaults.createButton"].exists, "Create New Vault missing")
        XCTAssertFalse(app.buttons["vaults.biometricButton"].exists, "No vault has Face ID, so no biometric button")
        XCTAssertFalse(app.staticTexts["setupWizard.titleLabel"].exists, "The setup wizard is gone")
        XCTAssertFalse(app.buttons["continueButton"].exists, "The setup wizard is gone")
        XCTAssertFalse(app.buttons["settingsButton"].isHittable, "The browser must not be usable behind the lock screen")
    }

    func testJourney1_OpenUnencryptedVaultShowsItsEmptyRoot() {
        openUnencryptedVault()
        XCTAssertTrue(app.navigationBars["KoalaTVault"].waitForExistence(timeout: 5),
                      "The unencrypted vault's root is titled \"KoalaTVault\"")
        XCTAssertTrue(app.staticTexts["browser.emptyStateLabel"].waitForExistence(timeout: 5), "The vault should be empty")
        XCTAssertEqual(app.collectionViews["fileGrid"].cells.count, 0)
        XCTAssertFalse(app.secureTextFields["vaults.passwordField"].exists, "The lock screen should be gone")
    }

    func testJourney1_UnencryptedVaultSettingsHasNoVaultSection() {
        openUnencryptedVault()
        openSettings()
        XCTAssertTrue(app.cells["settings.recentlyDeletedRow"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.cells["settings.changePasswordRow"].exists, "No Change Password in the unencrypted vault")
        XCTAssertFalse(app.cells["settings.deleteVaultRow"].exists, "No Delete This Vault in the unencrypted vault")
        XCTAssertFalse(app.cells["settings.lockMode.passwordRow"].exists, "The lock-mode rows are gone")
    }
}
