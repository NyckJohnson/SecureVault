//
//  SecureVaultUITests.swift
//  SecureVaultUITests
//
//  Created by Nicholas Johnson on 7/25/26.
//

import XCTest

final class SecureVaultUITests: XCTestCase {

    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // reset app state for each test
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDown() {
        super.tearDown()
        app.terminate()
    }
    
    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
    
    // MARK: - Setup Wizard
    func testSetupWizardAppearsOnFirstLaunch() {
        XCTAssertTrue(app.buttons["continueButton"].waitForExistence(timeout: 5))
    }

    func testSetupWizardContinueWithNoLock() {
        let continueButton = app.buttons["continueButton"]
        if continueButton.waitForExistence(timeout: 3) {
            continueButton.tap()
        }
        XCTAssertTrue(app.navigationBars["SecureVault"].waitForExistence(timeout: 10))
    }

    // MARK: - File Browser
    func testFileBrowserShowsNewFolderButton() {
        skipSetupIfNeeded()
        XCTAssertTrue(app.navigationBars.buttons["newFolderButton"].waitForExistence(timeout: 5))
    }

    func testFileBrowserShowsImportButton() {
        skipSetupIfNeeded()
        XCTAssertTrue(app.navigationBars.buttons["importButton"].waitForExistence(timeout: 5))
    }

    func testFileBrowserShowsSelectButton() {
        skipSetupIfNeeded()
        XCTAssertTrue(app.navigationBars.buttons["selectButton"].waitForExistence(timeout: 5))
    }

    // MARK: - New Folder
    func testCreateNewFolder() {
        skipSetupIfNeeded()
        app.navigationBars.buttons["newFolderButton"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("TestFolder")
        alert.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["TestFolder"].waitForExistence(timeout: 3))
    }

    func testCreateNewFolderCancel() {
        skipSetupIfNeeded()
        app.navigationBars.buttons["newFolderButton"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    // MARK: - Select Mode
    func testSelectModeActivates() {
        skipSetupIfNeeded()
        app.navigationBars.buttons["selectButton"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Cancel"].waitForExistence(timeout: 3))
    }

    func testSelectModeCancelExits() {
        skipSetupIfNeeded()
        app.navigationBars.buttons["selectButton"].tap()
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars.buttons["selectButton"].waitForExistence(timeout: 3))
    }

    // MARK: - Navigation
    func testNavigateIntoFolder() {
        skipSetupIfNeeded()
        // create a folder first
        app.navigationBars.buttons["newFolderButton"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("NavTestFolder")
        alert.buttons["Create"].tap()

        // tap the folder
        XCTAssertTrue(app.staticTexts["NavTestFolder"].waitForExistence(timeout: 3))
        app.staticTexts["NavTestFolder"].tap()

        // should navigate into folder
        XCTAssertTrue(app.navigationBars["NavTestFolder"].waitForExistence(timeout: 3))
    }
    
    func testNavigateBackFromFolder() {
        skipSetupIfNeeded()
        app.navigationBars.buttons["newFolderButton"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("BackTestFolder")
        alert.buttons["Create"].tap()

        XCTAssertTrue(app.staticTexts["BackTestFolder"].waitForExistence(timeout: 3))
        app.staticTexts["BackTestFolder"].tap()
        XCTAssertTrue(app.navigationBars["BackTestFolder"].waitForExistence(timeout: 3))

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["SecureVault"].waitForExistence(timeout: 3))
    }

    // MARK: - Import Sheet
    func testImportButtonShowsActionSheet() {
        skipSetupIfNeeded()
        app.navigationBars.buttons["importButton"].tap()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
    }

    func testImportSheetHasExpectedOptions() {
        skipSetupIfNeeded()
        app.navigationBars.buttons["importButton"].tap()
        XCTAssertTrue(app.buttons["Choose Files"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Choose Folder"].exists)
        XCTAssertTrue(app.buttons["Choose Photos"].exists)
    }

    func testImportSheetCancelDismisses() {
        skipSetupIfNeeded()
        app.navigationBars.buttons["importButton"].tap()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        // on iPad dismiss by tapping outside
        app.tap()
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    // MARK: - Settings
    func testSettingsButtonAppearsOnRoot() {
        skipSetupIfNeeded()
        XCTAssertTrue(app.navigationBars.buttons["settingsButton"].waitForExistence(timeout: 3))
    }

    func testSettingsOpens() {
        skipSetupIfNeeded()
        app.navigationBars.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 3))
    }

    // MARK: - Helpers
    private func skipSetupIfNeeded() {
        let continueButton = app.buttons["continueButton"]
        if continueButton.waitForExistence(timeout: 2) {
            continueButton.tap()
        }
    }
}
