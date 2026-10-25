//
//  JourneyTestCase.swift
//  KoalaTVaultUITests
//
//  Shared base class and helpers for the baseline journey tests (adoption Stage 3).
//  Every journey test launches the app with `-uiTesting` (clean, in-memory state).
//

import XCTest

class JourneyTestCase: XCTestCase {

    var app: XCUIApplication!

    /// Seeds for `-uiTesting` launches (`UITEST_*` variables). Override per journey.
    var launchEnvironment: [String: String] { [:] }

    /// Whether `setUp` launches the app. Journeys that need a relaunch can turn it off.
    var launchesInSetUp: Bool { true }

    static let password = "journeyPassword123"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        if launchesInSetUp { launch() }
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func launch(environment: [String: String]? = nil) {
        app.launchArguments = ["-uiTesting"]
        app.launchEnvironment = environment ?? launchEnvironment
        app.launch()
    }

    // MARK: - Screens

    /// Finishes the first-launch wizard with No Lock if it is showing, then waits for the browser.
    func completeSetupWithNoLockIfShown() {
        let wizardTitle = app.staticTexts["setupWizard.titleLabel"]
        if wizardTitle.waitForExistence(timeout: 5) {
            app.buttons["continueButton"].tap()
        }
        waitForBrowser()
    }

    func waitForBrowser(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.collectionViews["fileGrid"].waitForExistence(timeout: 10),
                      "The file browser did not appear", file: file, line: line)
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5),
                      "The browser's settings gear did not appear", file: file, line: line)
    }

    func cell(_ name: String) -> XCUIElement {
        app.collectionViews["fileGrid"].cells["browser.cell.\(name)"]
    }

    // MARK: - Typing

    func type(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Text field missing: \(field)", file: file, line: line)
        field.tap()
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                       "Field never received keyboard focus: \(field)", file: file, line: line)
        field.typeText(text)
    }

    // MARK: - Bar buttons (with the iOS "More" overflow)

    /// Taps a right bar button by identifier. When iOS has moved it into the overflow
    /// "More" menu, opens that menu and picks the row by identifier, then by `fallbackLabel`.
    func tapBarButton(_ identifier: String, fallbackLabel: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let direct = app.navigationBars.buttons[identifier]
        if direct.waitForExistence(timeout: 2), direct.isHittable {
            direct.tap()
            return
        }
        let more = app.navigationBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 3),
                      "\(identifier) is neither in the bar nor behind a More button", file: file, line: line)
        more.tap()
        // Overflow rows carry the image's accessibility label (e.g. "new folder", lower case),
        // not the bar button's identifier, so match the label case-insensitively too.
        let labelMatch = NSPredicate(format: "label ==[c] %@", fallbackLabel)
        let candidates: [XCUIElement] = [
            app.buttons[identifier], app.menuItems[identifier],
            app.buttons.matching(labelMatch).firstMatch, app.menuItems.matching(labelMatch).firstMatch
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 1) {
            candidate.tap()
            return
        }
        XCTFail("No overflow row for \(identifier) / \(fallbackLabel). Menu: \(app.debugDescription)",
                file: file, line: line)
    }

    // MARK: - Alerts

    /// Taps a `UIAlertAction` button (found by label; alert actions cannot take identifiers).
    func tapAlertButton(_ label: String, in alert: XCUIElement,
                        file: StaticString = #filePath, line: UInt = #line) {
        let button = alert.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Alert button \(label) missing", file: file, line: line)
        button.tap()
    }

    /// Waits for an error alert showing `message`, then dismisses it with OK.
    func expectErrorAlertAndDismiss(containing message: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "No alert appeared; expected \"\(message)\"",
                      file: file, line: line)
        XCTAssertTrue(alert.staticTexts[message].exists,
                      "Alert does not say \"\(message)\". Alert: \(alert.debugDescription)",
                      file: file, line: line)
        tapAlertButton("OK", in: alert, file: file, line: line)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "Alert did not close", file: file, line: line)
    }
}
