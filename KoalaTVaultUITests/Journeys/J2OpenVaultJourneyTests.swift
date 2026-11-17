//
//  J2OpenVaultJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 2: Open a vault. `UITEST_PASSWORD` seeds the encrypted vault "Test Vault" (empty); the seed file is in the
//  unencrypted vault. Not covered (the simulator has no biometrics): the "Use Face ID" button and its failure
//  messages. The privacy cover (app switcher snapshot) is not observable from XCUITest.
//

import XCTest

final class J2OpenVaultJourneyTests: JourneyTestCase {

    private let seedName = "plain-note.txt"

    override var launchEnvironment: [String: String] {
        ["UITEST_PASSWORD": Self.password, "UITEST_SEED_FILE_NAME": seedName]
    }

    private var passwordField: XCUIElement { app.secureTextFields["vaults.passwordField"] }

    private func backgroundAndReturn() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
    }

    // MARK: - Journey

    func testJourney2_LaunchShowsLockScreenWithEveryOption() {
        waitForLockScreen()
        XCTAssertTrue(app.buttons["vaults.openButton"].exists)
        XCTAssertTrue(app.buttons["vaults.unencryptedButton"].exists)
        XCTAssertTrue(app.buttons["vaults.createButton"].exists)
        XCTAssertFalse(app.buttons["vaults.biometricButton"].exists, "Face ID is off for every vault")
        XCTAssertFalse(app.staticTexts["vaults.errorLabel"].exists, "No error before an attempt")
        XCTAssertFalse(app.buttons["Cancel"].exists, "The lock screen has no Cancel")
        XCTAssertFalse(app.buttons["settingsButton"].isHittable, "The browser must not be usable while locked")
    }

    func testJourney2_PasswordOpensItsVaultTitledWithItsName() {
        attemptOpen(with: Self.password)
        waitForBrowser()
        XCTAssertTrue(browserTitle("Test Vault").waitForExistence(timeout: 5),
                      "The browser is titled with the vault's name")
        XCTAssertFalse(app.secureTextFields["vaults.passwordField"].exists, "The lock screen should be gone")
        XCTAssertFalse(cell(seedName).exists, "Test Vault is a different vault from the unencrypted one")
    }

    func testJourney2_OpenUnencryptedVaultShowsItsRoot() {
        openUnencryptedVault()
        XCTAssertTrue(browserTitle("KoalaTVault").waitForExistence(timeout: 5))
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 5))
    }

    func testJourney2_LockButtonClosesTheVaultAndShowsTheLockScreen() {
        attemptOpen(with: Self.password)
        waitForBrowser()
        lockApp()
        XCTAssertFalse(app.buttons["settingsButton"].isHittable, "The vault is closed behind the lock screen")
        attemptOpen(with: Self.password)
        waitForBrowser()
        XCTAssertTrue(browserTitle("Test Vault").exists)
    }

    func testJourney2_LockFromTheUnencryptedVaultShowsTheLockScreen() {
        openUnencryptedVault()
        lockApp()
        openUnencryptedVault()
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 5))
    }

    func testJourney2_ReturnFromBackgroundShowsLockScreenForAnEncryptedVault() {
        attemptOpen(with: Self.password)
        waitForBrowser()
        backgroundAndReturn()
        waitForLockScreen()
        XCTAssertFalse(app.buttons["settingsButton"].isHittable)
        attemptOpen(with: Self.password)
        waitForBrowser()
        XCTAssertTrue(browserTitle("Test Vault").exists)
    }

    func testJourney2_ReturnFromBackgroundShowsLockScreenForTheUnencryptedVault() {
        openUnencryptedVault()
        backgroundAndReturn()
        waitForLockScreen()
        openUnencryptedVault()
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 5))
    }

    // MARK: - Failure paths

    func testJourney2_WrongPasswordShowsIncorrectPasswordAndClearsField() {
        attemptOpen(with: "wrong-password")
        let error = app.staticTexts["vaults.errorLabel"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "No error label after a wrong password")
        XCTAssertEqual(error.label, "Incorrect password")
        let value = (passwordField.value as? String) ?? ""
        XCTAssertFalse(value.contains("•"), "The password field should be cleared, but holds: \(value)")
        XCTAssertTrue(app.buttons["vaults.unencryptedButton"].exists, "Still on the lock screen")
    }

    func testJourney2_WrongPasswordHasNoLockoutAndCorrectOneStillWorks() {
        for attempt in 1...4 {
            attemptOpen(with: "wrong-\(attempt)")
            let error = app.staticTexts["vaults.errorLabel"]
            XCTAssertTrue(error.waitForExistence(timeout: 10), "No error after wrong attempt \(attempt)")
            XCTAssertEqual(error.label, "Incorrect password")
        }
        attemptOpen(with: Self.password)
        waitForBrowser()
        XCTAssertTrue(browserTitle("Test Vault").exists, "No lockout and no wipe after repeated failures")
    }

    // MARK: - Migration screen (leftover unencrypted files in an upgraded vault)

    func testJourney2_OpeningAVaultWithLeftoverFilesShowsMigrationThenTheBrowser() {
        app.terminate()
        launch(environment: ["UITEST_LEGACY_LOCK": "password", "UITEST_PASSWORD": Self.password,
                             "UITEST_SEED_FILE_NAME": "leftover.txt", "UITEST_MIGRATION_FILE_DELAY": "2"])
        attemptOpen(with: Self.password)
        let title = app.staticTexts["migration.titleLabel"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "The Migration screen should show")
        XCTAssertEqual(title.label, "Encrypting Files")
        XCTAssertTrue(title.waitForNonExistence(timeout: 30), "The Migration screen should close")
        waitForBrowser()
        XCTAssertTrue(cell("leftover.txt").waitForExistence(timeout: 5))
    }
}
