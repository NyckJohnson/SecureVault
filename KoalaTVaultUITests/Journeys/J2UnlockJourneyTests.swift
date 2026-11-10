//
//  J2UnlockJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 2: Unlock. `UITEST_PASSWORD` starts the vault set up with a password lock,
//  so the cold launch shows the lock screen.
//

import XCTest

final class J2UnlockJourneyTests: JourneyTestCase {

    override var launchEnvironment: [String: String] {
        ["UITEST_PASSWORD": Self.password, "UITEST_SEED_FILE_NAME": "locked-note.txt"]
    }

    private var passwordField: XCUIElement { app.secureTextFields["passwordField"] }

    private func waitForLockScreen() {
        XCTAssertTrue(app.staticTexts["lockScreen.titleLabel"].waitForExistence(timeout: 10),
                      "The lock screen did not appear")
    }

    private func attemptUnlock(with password: String) {
        type(password, into: passwordField)
        app.buttons["unlockButton"].tap()
    }

    // MARK: - Journey

    func testJourney2_ColdLaunchShowsLockScreen() {
        waitForLockScreen()
        XCTAssertEqual(app.staticTexts["lockScreen.titleLabel"].label, "KoalaTVault Locked")
        XCTAssertTrue(passwordField.exists)
        XCTAssertTrue(app.buttons["unlockButton"].exists)
        // Password mode (not biometric): no biometric button.
        XCTAssertFalse(app.buttons["lockScreen.biometricButton"].exists)
        XCTAssertFalse(app.staticTexts["lockScreen.errorLabel"].exists, "No error should show before an attempt")
        XCTAssertFalse(app.buttons["settingsButton"].isHittable, "The browser must not be usable while locked")
    }

    func testJourney2_CorrectPasswordUnlocksAndBrowserReloads() {
        waitForLockScreen()
        attemptUnlock(with: Self.password)

        XCTAssertTrue(app.staticTexts["lockScreen.titleLabel"].waitForNonExistence(timeout: 10),
                      "The lock screen did not dismiss")
        waitForBrowser()
        XCTAssertTrue(cell("locked-note.txt").waitForExistence(timeout: 5),
                      "The browser should reload with the vault's files")
    }

    func testJourney2_ReturnFromBackgroundShowsLockScreenAgain() {
        waitForLockScreen()
        attemptUnlock(with: Self.password)
        waitForBrowser()

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()

        waitForLockScreen()
        XCTAssertTrue(passwordField.exists)

        attemptUnlock(with: Self.password)
        XCTAssertTrue(app.staticTexts["lockScreen.titleLabel"].waitForNonExistence(timeout: 10))
        waitForBrowser()
        XCTAssertTrue(cell("locked-note.txt").waitForExistence(timeout: 5))
    }

    // MARK: - Failure paths

    func testJourney2_WrongPasswordShowsIncorrectPasswordAndClearsField() {
        waitForLockScreen()
        attemptUnlock(with: "wrong-password")

        let error = app.staticTexts["lockScreen.errorLabel"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "No error label after a wrong password")
        XCTAssertEqual(error.label, "Incorrect password")
        // The field is cleared: its value is the placeholder (or empty), never the typed text.
        let value = (passwordField.value as? String) ?? ""
        XCTAssertFalse(value.contains("•"), "The password field should be cleared, but holds: \(value)")
        XCTAssertTrue(app.staticTexts["lockScreen.titleLabel"].exists, "Still locked")
    }

    func testJourney2_WrongPasswordHasNoLockoutAndCorrectOneStillWorks() {
        waitForLockScreen()
        for attempt in 1...4 {
            attemptUnlock(with: "wrong-\(attempt)")
            XCTAssertTrue(app.staticTexts["lockScreen.errorLabel"].waitForExistence(timeout: 10),
                          "No error after wrong attempt \(attempt)")
            XCTAssertEqual(app.staticTexts["lockScreen.errorLabel"].label, "Incorrect password")
        }
        attemptUnlock(with: Self.password)
        XCTAssertTrue(app.staticTexts["lockScreen.titleLabel"].waitForNonExistence(timeout: 10),
                      "Correct password should unlock after repeated failures (no lockout, no wipe)")
        waitForBrowser()
        XCTAssertTrue(cell("locked-note.txt").waitForExistence(timeout: 5), "The vault must not be wiped")
    }
}
