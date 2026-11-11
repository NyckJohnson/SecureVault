//
//  J8ManageVaultJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 8: Manage a vault (Change Password, Face ID switch, Delete This Vault, Migration failures).
//  Not covered: turning Face ID on/off and its failure (the simulator has no biometrics, so the switch row is
//  hidden: asserted absent); the Migration screen's backgrounding and the "Some Deleted Items Can't Be Read" prompt
//  (no seed creates unreadable trash).
//

import XCTest

final class J8ManageVaultJourneyTests: StoreKitJourneyTestCase {

    static let newPassword = "brandNewPassword456"
    static let otherPassword = "otherVaultPassword789"

    private func start(environment: [String: String] = [:]) {
        launch(environment: ["UITEST_PASSWORD": Self.password].merging(environment) { $1 })
        unlockWithPassword()
        openSettings()
    }

    private func row(_ id: String) -> XCUIElement { app.cells[id] }

    private func openChangePassword(current: String, new: String, confirm: String) {
        row("settings.changePasswordRow").tap()
        let alert = app.alerts["Change Password"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Change Password alert missing")
        if !current.isEmpty { type(current, into: alert.secureTextFields["settings.currentPasswordField"]) }
        if !new.isEmpty { type(new, into: alert.secureTextFields["settings.newPasswordField"]) }
        if !confirm.isEmpty { type(confirm, into: alert.secureTextFields["settings.confirmNewPasswordField"]) }
        tapAlertButton("Change", in: alert)
    }

    private func tapDeleteThisVault() {
        row("settings.deleteVaultRow").tap()
    }

    // MARK: - Vault section

    func testJourney8_VaultSectionShowsChangePasswordAndDeleteAndNoFaceIDSwitchWithoutBiometrics() {
        start()
        XCTAssertTrue(row("settings.changePasswordRow").waitForExistence(timeout: 5))
        XCTAssertTrue(row("settings.deleteVaultRow").exists)
        XCTAssertFalse(row("settings.biometricRow").exists, "The Face ID switch is hidden without biometrics")
        XCTAssertFalse(row("settings.lockMode.passwordRow").exists, "The lock-mode rows are gone")
    }

    // MARK: - Change password

    func testJourney8_ChangePasswordShowsSuccessAndTheNewPasswordOpensTheVault() {
        start()
        openChangePassword(current: Self.password, new: Self.newPassword, confirm: Self.newPassword)
        let done = app.alerts.firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "No result alert")
        XCTAssertTrue(done.staticTexts["Password changed successfully"].exists,
                      "Expected \"Password changed successfully\". Alert: \(done.debugDescription)")
        tapAlertButton("OK", in: done)
        dismissSettingsSheet()

        lockApp()
        attemptOpen(with: Self.password)
        XCTAssertEqual(app.staticTexts["vaults.errorLabel"].waitForExistence(timeout: 10)
                       ? app.staticTexts["vaults.errorLabel"].label : "", "Incorrect password",
                       "The old password should no longer open the vault")
        attemptOpen(with: Self.newPassword)
        waitForBrowser()
        XCTAssertTrue(app.navigationBars["Test Vault"].exists)
    }

    func testJourney8_EmptyNewPasswordShowsError() {
        start()
        openChangePassword(current: Self.password, new: "", confirm: "")
        expectErrorAlertAndDismiss(containing: "Password cannot be empty")
    }

    func testJourney8_MismatchedNewPasswordsShowError() {
        start()
        openChangePassword(current: Self.password, new: Self.newPassword, confirm: "somethingElse1")
        expectErrorAlertAndDismiss(containing: "Passwords do not match")
    }

    func testJourney8_WrongCurrentPasswordShowsError() {
        start()
        openChangePassword(current: "notThePassword", new: Self.newPassword, confirm: Self.newPassword)
        expectErrorAlertAndDismiss(containing: "Current password is incorrect")
    }

    func testJourney8_NewPasswordAnotherVaultUsesShowsChooseADifferentPassword() {
        // Pro lets a second encrypted vault exist; its password may not become Test Vault's.
        launch(environment: ["UITEST_PASSWORD": Self.password])
        unlockWithPassword()
        buyProThroughSettings()
        lockApp()
        createVault(name: "Second Vault", password: Self.otherPassword)
        waitForBrowser()
        XCTAssertTrue(app.navigationBars["Second Vault"].waitForExistence(timeout: 10))
        openSettings()
        openChangePassword(current: Self.otherPassword, new: Self.password, confirm: Self.password)
        expectErrorAlertAndDismiss(containing: "Choose a different password.")
    }

    // MARK: - Delete This Vault

    func testJourney8_DeleteThisVaultAsksForThePasswordAndCancelKeepsTheVault() {
        start()
        tapDeleteThisVault()
        let alert = app.alerts["Delete This Vault?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete This Vault? alert missing")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Everything in \"Test Vault\" will be erased"))
            .firstMatch.exists, "The alert names the vault. Alert: \(alert.debugDescription)")
        XCTAssertTrue(alert.secureTextFields["settings.deleteVaultPasswordField"].exists)
        tapAlertButton("Cancel", in: alert)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Security"].exists, "Still in Settings")
    }

    func testJourney8_DeleteThisVaultWithWrongPasswordShowsIncorrectPasswordAndErasesNothing() {
        start()
        tapDeleteThisVault()
        let alert = app.alerts["Delete This Vault?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        type("wrongPassword1", into: alert.secureTextFields["settings.deleteVaultPasswordField"])
        tapAlertButton("Delete", in: alert)
        expectErrorAlertAndDismiss(containing: "Incorrect password")
        dismissSettingsSheet()
        lockApp()
        unlockWithPassword()
        XCTAssertTrue(app.navigationBars["Test Vault"].exists, "The vault must still exist")
    }

    func testJourney8_DeleteThisVaultErasesItAndShowsTheLockScreen() {
        start()
        tapDeleteThisVault()
        let alert = app.alerts["Delete This Vault?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        type(Self.password, into: alert.secureTextFields["settings.deleteVaultPasswordField"])
        tapAlertButton("Delete", in: alert)
        waitForLockScreen()
        XCTAssertFalse(app.buttons["settingsButton"].isHittable)
        attemptOpen(with: Self.password)
        let error = app.staticTexts["vaults.errorLabel"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "Incorrect password", "The deleted vault's password opens nothing")
    }

    // MARK: - Migration failures (an upgraded vault with a leftover file that fails to encrypt)

    private func openLegacyVaultWithFailingFile() {
        let name = "stuck.txt"
        launch(environment: ["UITEST_LEGACY_LOCK": "password", "UITEST_PASSWORD": Self.password,
                             "UITEST_SEED_FILE_NAME": name, "UITEST_FAIL_MIGRATION_FILE": name])
        attemptOpen(with: Self.password)
    }

    func testJourney8_FailedFileOffersRetryAndSkipAndRetryShowsTheFailureAgain() {
        openLegacyVaultWithFailingFile()
        let alert = app.alerts["Some Files Failed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "Some Files Failed missing")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "stuck.txt")).firstMatch.exists,
                      "The alert lists the failed file. Alert: \(alert.debugDescription)")
        tapAlertButton("Retry", in: alert)
        XCTAssertTrue(app.alerts["Some Files Failed"].waitForExistence(timeout: 15),
                      "Retry after a failure that happens again shows it again")
        tapAlertButton("Skip", in: app.alerts["Some Files Failed"])
        waitForBrowser()
        XCTAssertTrue(app.navigationBars["My Vault"].exists)
    }

    func testJourney8_SkippedFileIsOfferedAgainTheNextTimeTheVaultOpens() {
        openLegacyVaultWithFailingFile()
        let alert = app.alerts["Some Files Failed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        tapAlertButton("Skip", in: alert)
        waitForBrowser()
        lockApp()
        attemptOpen(with: Self.password)
        XCTAssertTrue(app.alerts["Some Files Failed"].waitForExistence(timeout: 15),
                      "A skipped file stays unencrypted and is offered again")
        tapAlertButton("Skip", in: app.alerts["Some Files Failed"])
        waitForBrowser()
    }
}
