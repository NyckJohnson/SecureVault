//
//  JourneyTestCase.swift
//  KoalaTVaultUITests
//
//  Shared base class and helpers for the baseline journey tests (adoption Stage 3).
//  Every journey test launches the app with `-uiTesting` (clean, in-memory state).
//

import XCTest

@MainActor
class JourneyTestCase: XCTestCase {

    var app: XCUIApplication!

    /// Seeds for `-uiTesting` launches (`UITEST_*` variables). Override per journey.
    var launchEnvironment: [String: String] { [:] }

    /// Whether `setUp` launches the app. Journeys that need a relaunch can turn it off.
    var launchesInSetUp: Bool { true }

    static let password = "journeyPassword123"

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        if launchesInSetUp { launch() }
    }

    override func tearDown() async throws {
        app.terminate()
        try await super.tearDown()
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

    // MARK: - Shared helpers for journeys 4-6 (additive)

    /// Long-presses a grid cell to open its context menu.
    func longPressCell(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = cell(name)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "No cell for \(name)", file: file, line: line)
        target.press(forDuration: 1.5)
    }

    /// Taps a context-menu action by identifier, falling back to its title (identifiers are not
    /// exposed for context menus on iOS 26.5).
    func tapMenuAction(_ identifier: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        let byId = app.buttons[identifier]
        if byId.waitForExistence(timeout: 2) { byId.tap(); return }
        let byTitle = app.buttons[title]
        XCTAssertTrue(byTitle.waitForExistence(timeout: 3), "Context menu action \(title) missing",
                      file: file, line: line)
        byTitle.tap()
    }

    /// Creates a document through New Document and closes the editor with Done. Returns once the cell shows.
    func createDocument(named name: String, text: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.navigationBars.buttons["browser.newDocumentButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "New Document button missing", file: file, line: line)
        button.tap()
        let alert = app.alerts["New Document"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "New Document alert missing", file: file, line: line)
        type(name, into: alert.textFields["browser.newDocumentNameField"], file: file, line: line)
        tapAlertButton("Create", in: alert, file: file, line: line)
        let fileName = name.hasSuffix(".rtf") ? name : "\(name).rtf"
        XCTAssertTrue(app.navigationBars[fileName].waitForExistence(timeout: 5), "Editor did not open", file: file, line: line)
        if let text {
            type(text, into: app.textViews["textEditor.textView"], file: file, line: line)
        }
        app.buttons["textEditor.doneButton"].tap()
        XCTAssertTrue(app.navigationBars[fileName].waitForNonExistence(timeout: 5), "Editor did not close", file: file, line: line)
        XCTAssertTrue(cell(fileName).waitForExistence(timeout: 5), "\(fileName) missing from grid", file: file, line: line)
    }

    /// Deletes a grid item through its context menu and the confirm alert.
    func deleteViaContextMenu(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        longPressCell(name, file: file, line: line)
        tapMenuAction("browser.contextMenu.delete", title: "Delete", file: file, line: line)
        let alert = app.alerts["Delete \"\(name)\"?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete confirm missing for \(name)", file: file, line: line)
        tapAlertButton("Delete", in: alert, file: file, line: line)
        XCTAssertTrue(cell(name).waitForNonExistence(timeout: 5), "\(name) still in grid", file: file, line: line)
    }

    /// Settings gear -> Recently Deleted.
    func openRecentlyDeleted(file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 5), "Settings did not open", file: file, line: line)
        let row = app.cells["settings.recentlyDeletedRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Recently Deleted row missing", file: file, line: line)
        row.tap()
        XCTAssertTrue(app.navigationBars["Recently Deleted"].waitForExistence(timeout: 5),
                      "Recently Deleted did not open", file: file, line: line)
    }

    /// Dismisses the settings form sheet (it has no close button) and waits for the browser.
    func dismissSettingsSheet(file: StaticString = #filePath, line: UInt = #line) {
        app.navigationBars.firstMatch.swipeDown(velocity: .fast)
        if !app.collectionViews["fileGrid"].buttons.firstMatch.exists {
            // swipe from the nav bar can miss; drag the sheet by its top edge
            let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            top.press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
        }
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5) && app.buttons["settingsButton"].isHittable,
                      "Settings sheet did not dismiss", file: file, line: line)
    }

    /// Dismisses an action sheet by tapping the dimmed area outside it. iOS 26.5 does not expose a
    /// `UIAlertAction` Cancel button of an action sheet to XCUITest, so this is how Cancel is exercised.
    func dismissActionSheetByTappingOutside() {
        app.tap()
    }

    // MARK: - Shared helpers for journeys 7-9 (additive)

    /// Opens the Security settings sheet from the browser's gear.
    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Settings gear missing", file: file, line: line)
        gear.tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 5),
                      "Settings did not open", file: file, line: line)
    }

    /// Unlocks the lock screen with `password` and waits for the browser (journeys seeded with `UITEST_PASSWORD`).
    func unlockWithPassword(_ password: String = JourneyTestCase.password,
                            file: StaticString = #filePath, line: UInt = #line) {
        type(password, into: app.secureTextFields["passwordField"], file: file, line: line)
        app.buttons["unlockButton"].tap()
        waitForBrowser(file: file, line: line)
    }

    // MARK: - Shared helpers for the regression tests of baseline fixes (additive)

    /// Like `createDocument`, for when the app resolves a name conflict: types `name`, expects the editor titled
    /// `resultingFileName`, optionally types `text`, taps Done and waits for that cell.
    func createDocument(named name: String, resultingFileName: String, text: String? = nil,
                        file: StaticString = #filePath, line: UInt = #line) {
        let button = app.navigationBars.buttons["browser.newDocumentButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "New Document button missing", file: file, line: line)
        button.tap()
        let alert = app.alerts["New Document"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "New Document alert missing", file: file, line: line)
        type(name, into: alert.textFields["browser.newDocumentNameField"], file: file, line: line)
        tapAlertButton("Create", in: alert, file: file, line: line)
        XCTAssertTrue(app.navigationBars[resultingFileName].waitForExistence(timeout: 5),
                      "Editor did not open titled \(resultingFileName)", file: file, line: line)
        if let text {
            type(text, into: app.textViews["textEditor.textView"], file: file, line: line)
        }
        app.buttons["textEditor.doneButton"].tap()
        XCTAssertTrue(app.navigationBars[resultingFileName].waitForNonExistence(timeout: 5),
                      "Editor did not close", file: file, line: line)
        XCTAssertTrue(cell(resultingFileName).waitForExistence(timeout: 5),
                      "\(resultingFileName) missing from grid", file: file, line: line)
    }

    /// Creates a folder through New Folder (the button may be in the overflow menu).
    func createFolderViaBar(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        tapBarButton("newFolderButton", fallbackLabel: "New Folder", file: file, line: line)
        let alert = app.alerts["New Folder"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "New Folder alert missing", file: file, line: line)
        type(name, into: alert.textFields["browser.newFolderNameField"], file: file, line: line)
        tapAlertButton("Create", in: alert, file: file, line: line)
        XCTAssertTrue(cell(name).waitForExistence(timeout: 5), "Folder \(name) missing from grid", file: file, line: line)
    }
}
