//
//  J7ExportJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 7: Export / share. The document picker and the photo-library permission are system UI
//  that XCUITest cannot drive reliably, so these tests cover the app's own export sheet and the
//  hand-off to the document picker (cancelled).
//  Not covered: saving a copy into Files, the "Exporting..." progress (too brief to observe),
//  removal of decrypted copies, Save to Camera Roll ("N saved, M failed", photo access denied
//  alert; needs a seeded image or video, which no UITEST_* seed creates), and a part-way failure.
//

import XCTest

final class J7ExportJourneyTests: JourneyTestCase {

    private let seedName = "export-me.txt"

    override var launchEnvironment: [String: String] {
        ["UITEST_SEED_FILE_NAME": seedName]
    }

    override func setUp() async throws {
        try await super.setUp()
        openUnencryptedVault()
    }

    private var exportSheet: XCUIElement { app.sheets.firstMatch }

    private func assertExportSheetOffersFilesNotCameraRoll() {
        XCTAssertTrue(exportSheet.waitForExistence(timeout: 5), "The export sheet did not appear")
        XCTAssertTrue(exportSheet.buttons["Save to Files"].exists, "Save to Files missing")
        XCTAssertFalse(exportSheet.buttons["Save to Camera Roll"].exists,
                       "Save to Camera Roll must only show when the selection has images or videos")
        // The sheet's Cancel action is not exposed to XCUITest on iOS 26.5.
    }

    /// Waits for the export document picker (marked by its "Browse View (Picker)" container on iOS 26.5)
    /// and cancels it. The picker's Cancel is a plain element labelled "Cancel", not a button.
    private func cancelDocumentPicker(file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.otherElements["Browse View (Picker)"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15),
                      "The document picker did not appear. UI: \(app.debugDescription)", file: file, line: line)
        let cancel = app.otherElements.matching(NSPredicate(format: "label == 'Cancel'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Picker Cancel missing", file: file, line: line)
        cancel.tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10), "The picker did not close", file: file, line: line)
    }

    private func assertPickerThenCancel() {
        XCTAssertTrue(exportSheet.waitForNonExistence(timeout: 5), "The export sheet should close")
        cancelDocumentPicker()
        XCTAssertTrue(app.otherElements["progressOverlay"].waitForNonExistence(timeout: 5),
                      "The export overlay should be gone")
        XCTAssertTrue(cell(seedName).exists, "The vault item must still be in the grid")
    }

    // MARK: - Context menu

    func testJourney7_ContextMenuExportOffersSaveToFilesAndCancel() {
        longPressCell(seedName)
        tapMenuAction("browser.contextMenu.export", title: "Export")
        assertExportSheetOffersFilesNotCameraRoll()
        dismissActionSheetByTappingOutside()
        XCTAssertTrue(exportSheet.waitForNonExistence(timeout: 5), "Cancel should close the sheet")
        XCTAssertFalse(app.otherElements["progressOverlay"].exists, "Cancel must not start an export")
        XCTAssertTrue(cell(seedName).exists)
    }

    func testJourney7_SaveToFilesHandsOffToDocumentPicker() {
        longPressCell(seedName)
        tapMenuAction("browser.contextMenu.export", title: "Export")
        assertExportSheetOffersFilesNotCameraRoll()
        exportSheet.buttons["Save to Files"].tap()
        assertPickerThenCancel()
    }

    // MARK: - Bulk

    func testJourney7_BulkExportHandsOffToDocumentPicker() {
        tapBarButton("selectButton", fallbackLabel: "Select")
        XCTAssertTrue(browserTitle("Select Items").waitForExistence(timeout: 5))
        cell(seedName).tap()
        XCTAssertTrue(browserTitle("1 Selected").waitForExistence(timeout: 5))
        tapBarButton("browser.bulkExportButton", fallbackLabel: "Export")
        assertExportSheetOffersFilesNotCameraRoll()
        exportSheet.buttons["Save to Files"].tap()
        assertPickerThenCancel()
    }

    /// Folders in a selection are skipped: a file plus a folder still exports (the sheet appears).
    func testJourney7_FolderInSelectionDoesNotBlockExportOfFile() {
        tapBarButton("newFolderButton", fallbackLabel: "New Folder")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        type("Docs", into: alert.textFields["browser.newFolderNameField"])
        tapAlertButton("Create", in: alert)
        XCTAssertTrue(cell("Docs").waitForExistence(timeout: 5))

        tapBarButton("selectButton", fallbackLabel: "Select")
        cell("Docs").tap()
        cell(seedName).tap()
        XCTAssertTrue(browserTitle("2 Selected").waitForExistence(timeout: 5))
        tapBarButton("browser.bulkExportButton", fallbackLabel: "Export")
        assertExportSheetOffersFilesNotCameraRoll()
        exportSheet.buttons["Save to Files"].tap()
        assertPickerThenCancel()
    }

    // MARK: - Viewer share

    func testJourney7_ViewerShareOffersExportSheet() {
        cell(seedName).tap()
        let share = app.buttons["viewer.shareButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), "The viewer did not open")
        if !share.isHittable { app.otherElements["viewer.pager"].tap() }
        share.tap()
        assertExportSheetOffersFilesNotCameraRoll()
        exportSheet.buttons["Save to Files"].tap()
        XCTAssertTrue(exportSheet.waitForNonExistence(timeout: 5))
        cancelDocumentPicker()
        XCTAssertTrue(app.buttons["viewer.closeButton"].waitForExistence(timeout: 10),
                      "The viewer should still be showing after the picker closes")
    }
}

// MARK: - Regression: export from an encrypted vault is decrypted (baseline fix 20)

/// In an encrypted vault (the seed file moved into Test Vault, journey 11) the disk holds UUID-named encrypted files and `.vault_map` indexes. Export must hand the
/// document picker a decrypted copy under the real name. The picker's "Save as" field (`DOCPicker.filenameTextField`)
/// shows the name of the single item being saved, which is the one thing XCUITest can see of the hand-off; the
/// bytes written into Files and the contents of an exported folder are not observable.
final class J7ExportEncryptedVaultJourneyTests: JourneyTestCase {

    private let seedName = "export-me.txt"

    override var launchesInSetUp: Bool { false }

    override func setUp() async throws {
        try await super.setUp()
        launch(environment: ["UITEST_SEED_FILE_NAME": seedName, "UITEST_PASSWORD": Self.password])
        openTestVaultHolding(seedName)
    }

    private var exportSheet: XCUIElement { app.sheets.firstMatch }

    private func chooseSaveToFiles(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(exportSheet.waitForExistence(timeout: 5), "The export sheet did not appear", file: file, line: line)
        exportSheet.buttons["Save to Files"].tap()
    }

    /// Waits for the document picker, asserts it offers `expectedName` (not a UUID or `.vault_map`) with no error
    /// alert, then cancels it.
    private func assertPickerOffersThenCancel(name expectedName: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.otherElements["Browse View (Picker)"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15),
                      "The document picker did not appear. Alert: \(app.alerts.firstMatch.debugDescription)",
                      file: file, line: line)
        XCTAssertFalse(app.alerts["Error"].exists, "Export must not fail: \(app.alerts.firstMatch.debugDescription)",
                       file: file, line: line)
        // The "Save as" field is `DOCPicker.filenameTextField` on iOS 26 and unidentified on iOS 18; it is the only text field showing.
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "The picker's \"Save as\" name is missing",
                      file: file, line: line)
        let value = (nameField.value as? String) ?? ""
        XCTAssertTrue(value == expectedName || value == (expectedName as NSString).deletingPathExtension,
                      "The picker should offer \"\(expectedName)\", not \"\(value)\"", file: file, line: line)
        XCTAssertFalse(value.contains("vault_map"), "The index must not be exported", file: file, line: line)
        let cancel = app.otherElements.matching(NSPredicate(format: "label == 'Cancel'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Picker Cancel missing", file: file, line: line)
        cancel.tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10), "The picker did not close", file: file, line: line)
    }

    func testJourney7_ExportFromPasswordVaultOffersDecryptedFileUnderItsRealName() {
        longPressCell(seedName)
        tapMenuAction("browser.contextMenu.export", title: "Export")
        chooseSaveToFiles()
        assertPickerOffersThenCancel(name: seedName)
        XCTAssertTrue(cell(seedName).exists, "The vault item must still be in the grid")
    }

    func testJourney7_BulkExportFromPasswordVaultOffersDecryptedFileUnderItsRealName() {
        tapBarButton("selectButton", fallbackLabel: "Select")
        cell(seedName).tap()
        XCTAssertTrue(browserTitle("1 Selected").waitForExistence(timeout: 5))
        tapBarButton("browser.bulkExportButton", fallbackLabel: "Export")
        chooseSaveToFiles()
        assertPickerOffersThenCancel(name: seedName)
    }

    func testJourney7_ViewerShareFromPasswordVaultOffersDecryptedFileUnderItsRealName() {
        cell(seedName).tap()
        let share = app.buttons["viewer.shareButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), "The viewer did not open")
        if !share.isHittable { app.otherElements["viewer.pager"].tap() }
        share.tap()
        chooseSaveToFiles()
        assertPickerOffersThenCancel(name: seedName)
        XCTAssertTrue(app.buttons["viewer.closeButton"].waitForExistence(timeout: 10),
                      "The viewer should still be showing after the picker closes")
    }

    /// A folder in a password vault is stored as UUID-named files plus `.vault_map`. Exporting it must succeed and
    /// offer the folder under its visible name. What is inside the exported folder cannot be seen from here.
    func testJourney7_ExportFolderFromPasswordVaultOffersItUnderItsRealName() {
        createFolderViaBar(named: "Docs")
        cell("Docs").tap()
        XCTAssertTrue(browserTitle("Docs").waitForExistence(timeout: 5))
        createDocument(named: "notes")
        app.buttons["browser.backButton"].tap()
        XCTAssertTrue(cell("Docs").waitForExistence(timeout: 5))

        longPressCell("Docs")
        tapMenuAction("browser.contextMenu.export", title: "Export")
        chooseSaveToFiles()
        assertPickerOffersThenCancel(name: "Docs")
        XCTAssertTrue(cell("Docs").exists, "The folder must still be in the grid")
    }
}
