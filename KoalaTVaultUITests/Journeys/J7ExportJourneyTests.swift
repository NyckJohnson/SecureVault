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

    override func setUp() {
        super.setUp()
        completeSetupWithNoLockIfShown()
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
        XCTAssertTrue(app.navigationBars["Select Items"].waitForExistence(timeout: 5))
        cell(seedName).tap()
        XCTAssertTrue(app.navigationBars["1 Selected"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.navigationBars["2 Selected"].waitForExistence(timeout: 5))
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
