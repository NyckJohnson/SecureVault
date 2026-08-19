import XCTest

final class AdditionalUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        skipSetupIfNeeded()
    }

    override func tearDown() {
        super.tearDown()
        app.terminate()
    }

    // MARK: - Context Menu
    func testLongPressShowsContextMenu() {
        // create a folder first
        createFolder(named: "ContextMenuTest")
        XCTAssertTrue(app.staticTexts["ContextMenuTest"].waitForExistence(timeout: 3))
        app.staticTexts["ContextMenuTest"].press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
    }

    func testContextMenuHasExpectedOptions() {
        createFolder(named: "MenuOptionsTest")
        XCTAssertTrue(app.staticTexts["MenuOptionsTest"].waitForExistence(timeout: 3))
        app.staticTexts["MenuOptionsTest"].press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Move"].exists)
        XCTAssertTrue(app.buttons["Export"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
    }

    func testContextMenuRename() {
        createFolder(named: "RenameTest")
        app.staticTexts["RenameTest"].press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        app.buttons["Rename"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let textField = alert.textFields.firstMatch
        textField.tap()
        // select all and delete existing text reliably, instead of relying on triple-tap timing
        if let currentValue = textField.value as? String {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            textField.typeText(deleteString)
        }
        textField.typeText("RenamedFolder")
        alert.buttons["Rename"].tap()
        XCTAssertTrue(app.staticTexts["RenamedFolder"].waitForExistence(timeout: 3))
    }

    func testContextMenuDelete() {
        createFolder(named: "DeleteTest")
        XCTAssertTrue(app.staticTexts["DeleteTest"].waitForExistence(timeout: 3))
        app.staticTexts["DeleteTest"].press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
        app.buttons["Delete"].tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Delete"].tap()

        XCTAssertFalse(app.staticTexts["DeleteTest"].waitForExistence(timeout: 3))
    }

    // MARK: - Sort
    func testSortButtonAppearsInNavBar() {
        print(app.navigationBars.firstMatch.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons["sortButton"].waitForExistence(timeout: 3))
    }

    func testSortSheetAppears() {
        app.navigationBars.buttons["sortButton"].tap()
        // name has direction indicator since it's the current sort
        XCTAssertTrue(app.buttons["Name ↑"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Type"].exists)
        XCTAssertTrue(app.buttons["Date Modified"].exists)
    }

    func testSortSheetDismissesOnCancel() {
        app.navigationBars.buttons["sortButton"].tap()
        XCTAssertTrue(app.buttons["Name ↑"].waitForExistence(timeout: 3))
        app.tap()
        XCTAssertFalse(app.buttons["Name ↑"].exists)
    }

    // MARK: - New Document
    func testNewDocumentButtonExists() {
        XCTAssertTrue(app.navigationBars.buttons["doc.badge.plus"].waitForExistence(timeout: 3))
    }

    func testNewDocumentCreationAlert() {
        app.navigationBars.buttons["doc.badge.plus"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.textFields.firstMatch.exists)
        XCTAssertTrue(alert.buttons["Create"].exists)
        XCTAssertTrue(alert.buttons["Cancel"].exists)
    }

    func testNewDocumentCancel() {
        app.navigationBars.buttons["doc.badge.plus"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testNewDocumentCreated() {
        app.navigationBars.buttons["doc.badge.plus"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.typeText("MyDocument")
        alert.buttons["Create"].tap()
        // text editor should open
        XCTAssertTrue(app.navigationBars["MyDocument.rtf"].waitForExistence(timeout: 5))
    }

    // MARK: - Settings Navigation
    func testSettingsShowsLockModeSection() {
        app.navigationBars.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No Lock"].waitForExistence(timeout: 3))
    }

    func testSettingsShowsRecentlyDeleted() {
        app.navigationBars.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Recently Deleted"].waitForExistence(timeout: 3))
    }

    func testSettingsNavigatesToRecentlyDeleted() {
        app.navigationBars.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts["Recently Deleted"].waitForExistence(timeout: 3))
        app.staticTexts["Recently Deleted"].tap()
        XCTAssertTrue(app.navigationBars["Recently Deleted"].waitForExistence(timeout: 3))
    }

    func testRecentlyDeletedShowsEmptyState() {
        app.navigationBars.buttons["settingsButton"].tap()
        app.staticTexts["Recently Deleted"].tap()
        XCTAssertTrue(app.navigationBars["Recently Deleted"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No recently deleted files"].waitForExistence(timeout: 3))
    }

    // MARK: - Select Mode Bulk Actions
    func testSelectModeShowsBulkActionButtons() {
        createFolder(named: "BulkTest")
        app.navigationBars.buttons["selectButton"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Cancel"].waitForExistence(timeout: 3))
        // bulk action buttons should appear
        XCTAssertTrue(app.navigationBars.buttons.count > 1)
    }

    func testSelectModeSelectItem() {
        createFolder(named: "SelectTest")
        app.navigationBars.buttons["selectButton"].tap()
        XCTAssertTrue(app.staticTexts["SelectTest"].waitForExistence(timeout: 3))
        app.staticTexts["SelectTest"].tap()
        // title should update to show count
        XCTAssertTrue(app.navigationBars["1 Selected"].waitForExistence(timeout: 3))
    }

    func testSelectModeDeselectItem() {
        createFolder(named: "DeselectTest")
        app.navigationBars.buttons["selectButton"].tap()
        app.staticTexts["DeselectTest"].tap()
        XCTAssertTrue(app.navigationBars["1 Selected"].waitForExistence(timeout: 3))
        app.staticTexts["DeselectTest"].tap()
        XCTAssertTrue(app.navigationBars["Select Items"].waitForExistence(timeout: 3))
    }

    // MARK: - Folder Navigation
    func testFolderNavigationTitle() {
        createFolder(named: "TitleTest")
        app.staticTexts["TitleTest"].tap()
        XCTAssertTrue(app.navigationBars["TitleTest"].waitForExistence(timeout: 3))
    }

    func testFolderShowsEmptyState() {
        createFolder(named: "EmptyFolder")
        app.staticTexts["EmptyFolder"].tap()
        XCTAssertTrue(app.staticTexts["No files yet"].waitForExistence(timeout: 3))
    }

    func testNestedFolderNavigation() {
        createFolder(named: "ParentFolder")
        app.staticTexts["ParentFolder"].tap()
        XCTAssertTrue(app.navigationBars["ParentFolder"].waitForExistence(timeout: 3))
        createFolder(named: "ChildFolder")
        app.staticTexts["ChildFolder"].tap()
        XCTAssertTrue(app.navigationBars["ChildFolder"].waitForExistence(timeout: 3))
        // navigate back twice
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["ParentFolder"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["SecureVault"].waitForExistence(timeout: 3))
    }
    
    // MARK: - Migration UI
    func testMigrationFailureShowsRetrySkipOptions() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment = [
            "UITEST_SEED_FILE_NAME": "failtest.txt",
            "UITEST_FAIL_MIGRATION_FILE": "failtest.txt"
        ]
        app.launch()
        skipSetupIfNeeded()

        app.navigationBars.buttons["settingsButton"].tap()
        app.tables.staticTexts["Password"].tap()

        let alert = app.alerts["Set Password"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let fields = alert.secureTextFields
        fields.element(boundBy: 0).tap()
        fields.element(boundBy: 0).typeText("testpassword")
        fields.element(boundBy: 1).tap()
        fields.element(boundBy: 1).typeText("testpassword")
        alert.buttons["Set"].tap()

        let failureAlert = app.alerts["Some Files Failed"]
        XCTAssertTrue(failureAlert.waitForExistence(timeout: 10))
        XCTAssertTrue(failureAlert.buttons["Retry"].exists)
        XCTAssertTrue(failureAlert.buttons["Skip"].exists)
        XCTAssertTrue(failureAlert.staticTexts["These files couldn't be migrated: failtest.txt"].exists)

        failureAlert.buttons["Skip"].tap()
        XCTAssertFalse(app.alerts["Some Files Failed"].waitForExistence(timeout: 3))
    }

    // MARK: - Helpers
    private func skipSetupIfNeeded() {
        let continueButton = app.buttons["continueButton"]
        if continueButton.waitForExistence(timeout: 2) {
            continueButton.tap()
        }
        _ = app.navigationBars["SecureVault"].waitForExistence(timeout: 5)
    }

    private func createFolder(named name: String) {
        app.navigationBars.buttons["newFolderButton"].tap()
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        alert.textFields.firstMatch.typeText(name)
        alert.buttons["Create"].tap()
        _ = app.staticTexts[name].waitForExistence(timeout: 3)
    }
}

// MARK: - XCUIElement Extension
extension XCUIElement {
    func clearText() {
        guard let stringValue = self.value as? String else { return }
        tap()
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: stringValue.count)
        typeText(deleteString)
    }
}
