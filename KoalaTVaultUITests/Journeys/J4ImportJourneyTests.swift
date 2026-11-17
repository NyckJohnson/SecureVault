//
//  J4ImportJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 4: Import. The Files and Photos pickers are system UI that XCUITest cannot drive
//  reliably, so these tests cover the app's own import sheet and the hand-off to the pickers.
//  Not covered: picking files/folders/photos, the "Importing..." progress, "N imported, M failed",
//  the delete-originals prompt, same-name skip/" 1" naming, mid-import failure and the free-tier
//  100-file limit (all need a picked item).
//

import XCTest

final class J4ImportJourneyTests: JourneyTestCase {

    private let seedName = "alpha.txt"

    override var launchEnvironment: [String: String] {
        ["UITEST_SEED_FILE_NAME": seedName, "UITEST_PASSWORD": Self.password]
    }

    override func setUp() async throws {
        try await super.setUp()
        openUnencryptedVault()
    }

    private func openImportSheet() -> XCUIElement {
        tapActionsMenuEntry("browser.menu.import", title: "Import")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The import sheet did not appear")
        return sheet
    }

    private func assertGridUnchanged(file: StaticString = #filePath, line: UInt = #line) {
        let names = app.collectionViews["fileGrid"].cells.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(names, ["browser.cell.\(seedName)"], "Nothing should have been imported", file: file, line: line)
    }

    /// Each vault imports on its own: the sheet is the same in an encrypted vault.
    func testJourney4_ImportSheetInAnEncryptedVaultOffersTheSameChoices() {
        lockApp()
        unlockWithPassword()
        let sheet = openImportSheet()
        XCTAssertTrue(sheet.buttons["Choose Files"].exists)
        XCTAssertTrue(sheet.buttons["Choose Folder"].exists)
        XCTAssertTrue(sheet.buttons["Choose Photos"].exists)
        dismissActionSheetByTappingOutside()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.collectionViews["fileGrid"].cells.count, 0, "Test Vault is empty, nothing imported")
    }

    func testJourney4_ImportSheetListsChooseFilesFolderPhotosAndCancel() {
        let sheet = openImportSheet()
        XCTAssertTrue(sheet.buttons["Choose Files"].exists)
        XCTAssertTrue(sheet.buttons["Choose Folder"].exists)
        XCTAssertTrue(sheet.buttons["Choose Photos"].exists)
        // The sheet's Cancel action is not exposed to XCUITest on iOS 26.5; it is exercised by tapping outside.
    }

    func testJourney4_CancelOnImportSheetImportsNothing() {
        let sheet = openImportSheet()
        dismissActionSheetByTappingOutside()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "The sheet should close")
        XCTAssertFalse(app.otherElements["progressOverlay"].exists)
        assertGridUnchanged()
    }

    func testJourney4_ChooseFilesOpensDocumentPickerAndCancelImportsNothing() {
        let sheet = openImportSheet()
        sheet.buttons["Choose Files"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "The document picker did not appear (no Cancel button)")
        cancel.tap()
        XCTAssertTrue(app.buttons["browser.actionsMenuButton"].waitForExistence(timeout: 10), "The picker did not close")
        XCTAssertFalse(app.otherElements["progressOverlay"].exists)
        assertGridUnchanged()
    }

    func testJourney4_ChooseFolderOpensDocumentPickerAndCancelImportsNothing() {
        let sheet = openImportSheet()
        sheet.buttons["Choose Folder"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "The folder picker did not appear (no Cancel button)")
        cancel.tap()
        XCTAssertTrue(app.buttons["browser.actionsMenuButton"].waitForExistence(timeout: 10), "The picker did not close")
        assertGridUnchanged()
    }

    /// Failure path: photo picker Cancel closes the picker and imports nothing.
    func testJourney4_PhotoPickerCancelClosesPickerAndImportsNothing() {
        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos", "OK", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        let sheet = openImportSheet()
        sheet.buttons["Choose Photos"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        app.tap()  // lets an interruption monitor handle a permission alert
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "The photo picker did not appear (no Cancel button)")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5), "Cancel must close the photo picker")
        XCTAssertTrue(app.buttons["browser.actionsMenuButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists, "Cancel must not raise an error")
        assertGridUnchanged()
    }
}
