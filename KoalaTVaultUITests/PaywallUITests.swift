//
//  PaywallUITests.swift
//  KoalaTVaultUITests
//

import XCTest
import StoreKitTest

final class PaywallUITests: VaultUITestCase {

    private var session: SKTestSession!
    private let testPassword = "uitestPassword123"

    override var additionalLaunchEnvironment: [String: String] {
        ["UITEST_PASSWORD": testPassword]
    }

    override func setUpWithError() throws {
        let configURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "premiumTesting", withExtension: "storekit"),
            "premiumTesting.storekit is not in the KoalaTVaultUITests bundle — check target membership"
        )
        session = try SKTestSession(contentsOf: configURL)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        try super.setUpWithError()
    }

    override func tearDown() {
        session?.clearTransactions()
        super.tearDown()
    }

    /// Regression test: purchasing Pro must not wipe the crypto key or present the
    /// lock screen, since sceneWillResignActive fires when the StoreKit sheet appears.
    func testPurchaseDoesNotTriggerLockScreen() throws {
        unlockVaultAtLaunch()

        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Vault did not unlock at launch")
        settingsButton.tap()

        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 3))

        let upgradeRow = app.cells["upgradeToProCell"]
        XCTAssertTrue(upgradeRow.waitForExistence(timeout: 5))
        upgradeRow.tap()

        let purchaseButton = app.buttons["paywallUnlockButton"]
        XCTAssertTrue(purchaseButton.waitForExistence(timeout: 5))
        purchaseButton.tap()

        // The lock screen must never appear during or after the purchase.
        let passwordField = app.secureTextFields["passwordField"]
        XCTAssertFalse(passwordField.waitForExistence(timeout: 3), "Vault relocked during purchase")

        // On success the paywall dismisses itself.
        XCTAssertTrue(purchaseButton.waitForNonExistence(timeout: 5), "Paywall did not dismiss after purchase")

        // Confirm the Settings row now reflects the unlocked state.
        XCTAssertTrue(app.staticTexts["Pro Unlocked"].waitForExistence(timeout: 5))
    }

    // MARK: - Helpers
    /// The app always shows the lock screen on cold launch when a password is
    /// configured (handleInitialLaunch) — authenticate through it before continuing.
    private func unlockVaultAtLaunch() {
        let passwordField = app.secureTextFields["passwordField"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Lock screen did not appear at launch")

        passwordField.tap()
        let hasFocus = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: passwordField
        )

        XCTAssertEqual(
            XCTWaiter.wait(for: [hasFocus], timeout: 3), .completed,
            "Password field never received keyboard focus"
        )
        passwordField.typeText(testPassword)
        app.buttons["unlockButton"].tap()

        XCTAssertTrue(
            passwordField.waitForNonExistence(timeout: 5),
            "Lock screen did not dismiss after entering the test password"
        )
    }
}
