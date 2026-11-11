//
//  J10CreateVaultJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 10: Create a vault. Without any seed there is no encrypted vault, so the first one is free. Not covered:
//  a Keychain or disk failure while creating (no seed can cause one).
//

import XCTest

final class J10CreateVaultJourneyTests: StoreKitJourneyTestCase {

    static let otherPassword = "otherVaultPassword789"

    func testJourney10_CreateVaultOpensTheNewEmptyVaultTitledWithItsName() {
        launch(environment: [:])
        createVault(name: "Family", password: Self.password)
        waitForBrowser()
        XCTAssertTrue(app.navigationBars["Family"].waitForExistence(timeout: 10), "Browser is titled with the new name")
        XCTAssertEqual(app.collectionViews["fileGrid"].cells.count, 0, "The new vault is empty")
        XCTAssertFalse(app.textFields["createVault.nameField"].exists, "Both screens should be gone")
        XCTAssertFalse(app.secureTextFields["vaults.passwordField"].exists)
    }

    func testJourney10_TheNewVaultOpensWithItsPasswordFromTheLockScreen() {
        launch(environment: [:])
        createVault(name: "Family", password: Self.password)
        waitForBrowser()
        lockApp()
        unlockWithPassword()
        XCTAssertTrue(app.navigationBars["Family"].waitForExistence(timeout: 5))
    }

    // MARK: - Failure paths

    private func expectCreateError(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let error = app.staticTexts["createVault.errorLabel"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "No error shown; expected \"\(message)\"", file: file, line: line)
        XCTAssertEqual(error.label, message, file: file, line: line)
        XCTAssertTrue(app.textFields["createVault.nameField"].exists, "Still on Create Vault", file: file, line: line)
    }

    func testJourney10_EmptyNameShowsError() {
        launch(environment: [:])
        createVault(name: "", password: Self.password)
        expectCreateError("Enter a name for the vault")
    }

    func testJourney10_EmptyPasswordShowsError() {
        launch(environment: [:])
        createVault(name: "Family", password: "")
        expectCreateError("Password cannot be empty")
    }

    func testJourney10_MismatchedPasswordsShowError() {
        launch(environment: [:])
        createVault(name: "Family", password: Self.password, confirm: "somethingElse1")
        expectCreateError("Passwords do not match")
    }

    func testJourney10_FreeTierWithOneEncryptedVaultOpensThePaywallInstead() {
        launch(environment: ["UITEST_PASSWORD": Self.password])
        waitForLockScreen()
        app.buttons["vaults.createButton"].tap()
        XCTAssertTrue(app.buttons["paywallUnlockButton"].waitForExistence(timeout: 10), "The paywall should open")
        XCTAssertFalse(app.textFields["createVault.nameField"].exists)
    }

    func testJourney10_PasswordAnotherVaultUsesShowsChooseADifferentPassword() {
        launch(environment: ["UITEST_PASSWORD": Self.password])
        unlockWithPassword()
        buyProThroughSettings()
        lockApp()
        createVault(name: "Decoy", password: Self.password)
        expectCreateError("Choose a different password.")
    }

    func testJourney10_WithProASecondVaultCanBeCreatedAndEachPasswordOpensOnlyItsOwn() {
        launch(environment: ["UITEST_PASSWORD": Self.password])
        unlockWithPassword()
        buyProThroughSettings()
        lockApp()
        createVault(name: "Decoy", password: Self.otherPassword)
        waitForBrowser()
        XCTAssertTrue(app.navigationBars["Decoy"].waitForExistence(timeout: 10))
        lockApp()
        unlockWithPassword()
        XCTAssertTrue(app.navigationBars["Test Vault"].waitForExistence(timeout: 5),
                      "The first password opens the first vault")
        lockApp()
        unlockWithPassword(Self.otherPassword)
        XCTAssertTrue(app.navigationBars["Decoy"].waitForExistence(timeout: 5),
                      "The second password opens the second vault")
    }
}
