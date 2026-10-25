//
//  J1SetupJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 1: First launch / setup.
//

import XCTest

final class J1SetupJourneyTests: JourneyTestCase {

    // MARK: - Helpers

    private func waitForWizard() {
        XCTAssertTrue(app.staticTexts["setupWizard.titleLabel"].waitForExistence(timeout: 10),
                      "The setup wizard did not appear on first launch")
    }

    private func openSettings() {
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tables["settings.table"].waitForExistence(timeout: 5))
    }

    private func fillPasswordAlert(password: String, confirm: String) {
        let alert = app.alerts["Set Password"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "The Set Password alert did not appear")
        type(password, into: alert.secureTextFields["setupWizard.passwordField"])
        type(confirm, into: alert.secureTextFields["setupWizard.confirmPasswordField"])
        tapAlertButton("Set", in: alert)
    }

    private func chooseCardAndContinue(_ cardIdentifier: String) {
        let card = app.buttons[cardIdentifier]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        app.buttons["continueButton"].tap()
    }

    // MARK: - Journey

    func testJourney1_FirstLaunchShowsWizardWithThreeCards() {
        waitForWizard()
        XCTAssertTrue(app.staticTexts["Welcome to Koala T Vault"].exists)
        XCTAssertTrue(app.buttons["setupWizard.noLockCard"].exists, "No Lock card missing")
        XCTAssertTrue(app.buttons["setupWizard.passwordCard"].exists, "Password card missing")
        XCTAssertTrue(app.buttons["setupWizard.biometricCard"].exists, "Password + biometric card missing")
        XCTAssertTrue(app.buttons["continueButton"].isHittable)
    }

    func testJourney1_BiometricCardIsDisabledWithoutBiometrics() {
        waitForWizard()
        // The simulator has no enrolled biometrics, so the third card must be disabled.
        XCTAssertFalse(app.buttons["setupWizard.biometricCard"].isEnabled,
                       "The biometric card should be disabled when biometrics are unavailable")
    }

    func testJourney1_ContinueWithNoLockShowsEmptyVault() {
        waitForWizard()
        // No Lock is the default: Continue without choosing a card.
        app.buttons["continueButton"].tap()

        XCTAssertTrue(app.staticTexts["setupWizard.titleLabel"].waitForNonExistence(timeout: 5),
                      "The wizard did not close")
        waitForBrowser()
        XCTAssertTrue(app.navigationBars["KoalaTVault"].exists)
        XCTAssertTrue(app.staticTexts["browser.emptyStateLabel"].waitForExistence(timeout: 5),
                      "The browser should show the empty vault")

        // The lock mode is set: No Lock is the checked row in Settings.
        openSettings()
        XCTAssertTrue(app.cells["settings.lockMode.noLockRow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["settings.lockMode.noLockRow"].isSelected, "No Lock should be the current mode")
    }

    func testJourney1_ContinueWithPasswordSetsPasswordMode() {
        waitForWizard()
        chooseCardAndContinue("setupWizard.passwordCard")
        fillPasswordAlert(password: Self.password, confirm: Self.password)

        XCTAssertTrue(app.staticTexts["setupWizard.titleLabel"].waitForNonExistence(timeout: 10),
                      "The wizard did not close after setting the password")
        waitForBrowser()
        XCTAssertTrue(app.staticTexts["browser.emptyStateLabel"].exists)

        openSettings()
        XCTAssertTrue(app.cells["settings.lockMode.passwordRow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["settings.lockMode.passwordRow"].isSelected, "Password should be the current mode")
        XCTAssertTrue(app.cells["settings.changePasswordRow"].exists, "Change Password row should exist with a lock")
    }

    // MARK: - Failure paths

    func testJourney1_EmptyPasswordShowsErrorAndUserCanRetry() {
        waitForWizard()
        chooseCardAndContinue("setupWizard.passwordCard")
        fillPasswordAlert(password: "", confirm: "")

        expectErrorAlertAndDismiss(containing: "Password cannot be empty")
        XCTAssertTrue(app.alerts["Set Password"].waitForNonExistence(timeout: 3), "The Set Password alert should close")
        XCTAssertTrue(app.staticTexts["setupWizard.titleLabel"].exists, "The wizard should stay")

        // Retry succeeds.
        app.buttons["continueButton"].tap()
        fillPasswordAlert(password: Self.password, confirm: Self.password)
        XCTAssertTrue(app.staticTexts["setupWizard.titleLabel"].waitForNonExistence(timeout: 10))
        waitForBrowser()
    }

    func testJourney1_MismatchedPasswordsShowErrorAndUserCanRetry() {
        waitForWizard()
        chooseCardAndContinue("setupWizard.passwordCard")
        fillPasswordAlert(password: Self.password, confirm: "somethingElse")

        expectErrorAlertAndDismiss(containing: "Passwords do not match")
        XCTAssertTrue(app.alerts["Set Password"].waitForNonExistence(timeout: 3), "The Set Password alert should close")
        XCTAssertTrue(app.staticTexts["setupWizard.titleLabel"].exists, "The wizard should stay")

        app.buttons["continueButton"].tap()
        fillPasswordAlert(password: Self.password, confirm: Self.password)
        XCTAssertTrue(app.staticTexts["setupWizard.titleLabel"].waitForNonExistence(timeout: 10))
        waitForBrowser()
    }

    func testJourney1_CancellingThePasswordAlertKeepsTheWizard() {
        waitForWizard()
        chooseCardAndContinue("setupWizard.passwordCard")
        let alert = app.alerts["Set Password"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        tapAlertButton("Cancel", in: alert)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["setupWizard.titleLabel"].exists, "The wizard should stay after Cancel")
    }
}
