//
//  J9PaywallJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 9: Paywall. Purchases run against premiumTesting.storekit through an in-process
//  SKTestSession (dialogs disabled), as the legacy PaywallUITests did.
//  Not covered: the import-limit entry (needs a picked item to reach the 100-file check) and the
//  user cancelling the App Store sheet (system UI; SKTestSession cannot simulate a cancel).
//

import XCTest
import StoreKitTest

private final class SessionBox: @unchecked Sendable {
    let session: SKTestSession
    init(_ session: SKTestSession) { self.session = session }
}

final class J9PaywallJourneyTests: JourneyTestCase {

    private var session: SKTestSession!
    private let productID = "nej.KoalaTVault.unlockpro"

    override var launchesInSetUp: Bool { false }

    override func setUp() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "premiumTesting", withExtension: "storekit"),
            "premiumTesting.storekit is not in the KoalaTVaultUITests bundle")
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        try await super.setUp()
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session?.resetToDefaultState()
        try await super.tearDown()
    }

    private func startAndOpenPaywall() {
        launch(environment: ["UITEST_SEED_FILE_NAME": "paywall-note.txt"])
        completeSetupWithNoLockIfShown()
        openSettings()
        let pro = app.cells["upgradeToProCell"]
        XCTAssertTrue(pro.waitForExistence(timeout: 5), "Pro row missing")
        XCTAssertTrue(pro.staticTexts["Upgrade to Pro"].exists, "Free user should see \"Upgrade to Pro\"")
        pro.tap()
        XCTAssertTrue(app.otherElements["paywall"].waitForExistence(timeout: 5)
                      || app.buttons["paywallUnlockButton"].waitForExistence(timeout: 5), "Paywall did not open")
    }

    func testJourney9_PaywallShowsTitleDescriptionPriceAndButtons() {
        startAndOpenPaywall()
        XCTAssertEqual(app.staticTexts["paywall.titleLabel"].label, "Unlock Pro")
        XCTAssertEqual(app.staticTexts["paywall.descriptionLabel"].label, "Store more than 100 files.")
        let price = app.staticTexts["paywall.priceLabel"]
        XCTAssertTrue(price.exists, "Price label missing")
        let hasPrice = NSPredicate(format: "label.length > 1")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hasPrice, object: price)], timeout: 10),
                       .completed, "The price should load from the StoreKit configuration. Label: \"\(price.label)\"")
        XCTAssertTrue(app.buttons["paywallUnlockButton"].exists)
        XCTAssertTrue(app.buttons["restoreButton"].exists)
        XCTAssertTrue(app.buttons["paywall.closeButton"].exists)
    }

    func testJourney9_CloseButtonDismissesPaywallAndLeavesFreeUser() {
        startAndOpenPaywall()
        app.buttons["paywall.closeButton"].tap()
        XCTAssertTrue(app.buttons["paywallUnlockButton"].waitForNonExistence(timeout: 5), "Paywall did not close")
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["upgradeToProCell"].staticTexts["Upgrade to Pro"].exists)
    }

    func testJourney9_UnlockPurchasesAndShowsProUnlocked() {
        startAndOpenPaywall()
        app.buttons["paywallUnlockButton"].tap()
        XCTAssertTrue(app.buttons["paywallUnlockButton"].waitForNonExistence(timeout: 15),
                      "Paywall did not close after the purchase")
        XCTAssertTrue(app.cells["upgradeToProCell"].staticTexts["Pro Unlocked"].waitForExistence(timeout: 10),
                      "Settings should show \"Pro Unlocked\"")
    }

    func testJourney9_PendingPurchaseShowsApprovalAlertAndKeepsPaywall() {
        session.askToBuyEnabled = true
        startAndOpenPaywall()
        app.buttons["paywallUnlockButton"].tap()
        expectErrorAlertAndDismiss(containing: "Purchase pending approval.")
        XCTAssertTrue(app.buttons["paywallUnlockButton"].exists, "Paywall should stay up")
    }

    func testJourney9_RestoreWithNothingShowsNotFoundAlert() {
        startAndOpenPaywall()
        app.buttons["restoreButton"].tap()
        expectErrorAlertAndDismiss(containing: "No previous purchase found to restore.")
        XCTAssertTrue(app.buttons["paywallUnlockButton"].exists, "Paywall should stay up")
    }

    func testJourney9_RestoreWithExistingPurchaseUnlocksPro() throws {
        startAndOpenPaywall()
        try session.buyProduct(productIdentifier: productID)
        // The purchase may already have unlocked Pro via Transaction.updates and closed the paywall.
        if app.buttons["restoreButton"].exists { app.buttons["restoreButton"].tap() }
        XCTAssertTrue(app.buttons["restoreButton"].waitForNonExistence(timeout: 10), "Paywall did not close")
        XCTAssertTrue(app.cells["upgradeToProCell"].staticTexts["Pro Unlocked"].waitForExistence(timeout: 10))
    }

    @available(iOS 17.0, *)
    func testJourney9_PriceUnavailableShowsMessageAndUnlockStillPresent() throws {
        let done = expectation(description: "simulated product-load error set")
        let box = SessionBox(session)
        Task { try? await box.session.setSimulatedError(.generic(.unknown), forAPI: .loadProducts); done.fulfill() }
        wait(for: [done], timeout: 10)
        startAndOpenPaywall()
        let price = app.staticTexts["paywall.priceLabel"]
        XCTAssertTrue(price.waitForExistence(timeout: 5))
        let said = NSPredicate(format: "label == %@", "Price unavailable")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: said, object: price)], timeout: 10),
                       .completed, "Expected \"Price unavailable\". Label: \"\(price.label)\"")
        let unlock = app.buttons["paywallUnlockButton"]
        XCTAssertTrue(unlock.exists && unlock.isEnabled && unlock.isHittable, "Unlock must still be usable")
    }
}
