//
//  J6DeleteRestoreJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 6: Delete / restore. Not covered: the automatic 30-day purge (needs aged trash entries
//  that no UITEST_* seed can create).
//

import XCTest

final class J6DeleteRestoreJourneyTests: JourneyTestCase {

    private let seedName = "alpha.txt"

    override var launchEnvironment: [String: String] {
        ["UITEST_SEED_FILE_NAME": seedName, "UITEST_PASSWORD": Self.password]
    }

    override func setUp() async throws {
        try await super.setUp()
        openUnencryptedVault()
    }

    private func trashRow(_ name: String) -> XCUIElement {
        app.tables["recentlyDeleted.list"].cells["recentlyDeleted.row.\(name)"]
    }

    private func tapSheetButton(_ label: String) {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Action sheet button \(label) missing")
        button.tap()
        XCTAssertTrue(button.waitForNonExistence(timeout: 5), "Action sheet did not close")
    }

    private func gridNames() -> [String] {
        app.collectionViews["fileGrid"].cells.allElementsBoundByIndex.map(\.identifier)
    }

    private func leaveTrash() {
        app.navigationBars["Recently Deleted"].buttons["Security"].tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 5))
        dismissSettingsSheet()
    }

    // MARK: - Delete

    func testJourney6_DeleteViaContextMenuMovesItemToRecentlyDeleted() {
        deleteViaContextMenu(seedName)
        openRecentlyDeleted()
        XCTAssertTrue(trashRow(seedName).waitForExistence(timeout: 5), "Deleted item should be in the trash")
        XCTAssertTrue(trashRow(seedName).staticTexts["Deletes in 30 days"].exists,
                      "Row should say \"Deletes in 30 days\". Row: \(trashRow(seedName).debugDescription)")
    }

    func testJourney6_DeleteConfirmCancelKeepsItem() {
        longPressCell(seedName)
        tapMenuAction("browser.contextMenu.delete", title: "Delete")
        let alert = app.alerts["Delete \"\(seedName)\"?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        tapAlertButton("Cancel", in: alert)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(cell(seedName).exists)
    }

    func testJourney6_BulkDeleteMovesSelectionToRecentlyDeleted() {
        createDocument(named: "Second")
        tapBarButton("selectButton", fallbackLabel: "Select")
        XCTAssertTrue(app.navigationBars["Select Items"].waitForExistence(timeout: 5))
        cell(seedName).tap()
        cell("Second.rtf").tap()
        XCTAssertTrue(app.navigationBars["2 Selected"].waitForExistence(timeout: 5))
        app.buttons["browser.bulkDeleteButton"].tap()
        let alert = app.alerts["Delete 2 items?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Bulk delete needs a confirm")
        tapAlertButton("Delete", in: alert)
        XCTAssertTrue(cell(seedName).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["browser.emptyStateLabel"].waitForExistence(timeout: 5))
        openRecentlyDeleted()
        XCTAssertTrue(trashRow(seedName).waitForExistence(timeout: 5))
        XCTAssertTrue(trashRow("Second.rtf").exists)
    }

    // MARK: - Restore / delete permanently

    func testJourney6_TappingRowOffersRestoreDeletePermanentlyCancel() {
        deleteViaContextMenu(seedName)
        openRecentlyDeleted()
        trashRow(seedName).tap()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5), "Action sheet expected")
        XCTAssertTrue(app.buttons["Delete Permanently"].exists)
        // Cancel is not exposed to XCUITest on iOS 26.5; tap outside the sheet instead.
        dismissActionSheetByTappingOutside()
        XCTAssertTrue(app.buttons["Restore"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(trashRow(seedName).exists, "Cancel leaves the item in the trash")
    }

    func testJourney6_RestoreReturnsItemToBrowser() {
        deleteViaContextMenu(seedName)
        openRecentlyDeleted()
        trashRow(seedName).tap()
        tapSheetButton("Restore")
        XCTAssertTrue(trashRow(seedName).waitForNonExistence(timeout: 5), "Restored item leaves the trash")
        XCTAssertTrue(app.staticTexts["recentlyDeleted.emptyStateLabel"].waitForExistence(timeout: 5))
        leaveTrash()
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 5), "Restored item is back in the grid")
    }

    func testJourney6_DeletePermanentlyRemovesItemForGood() {
        deleteViaContextMenu(seedName)
        openRecentlyDeleted()
        trashRow(seedName).tap()
        tapSheetButton("Delete Permanently")
        let alert = app.alerts["Delete Permanently?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete Permanently needs a confirm")
        tapAlertButton("Delete", in: alert)
        XCTAssertTrue(trashRow(seedName).waitForNonExistence(timeout: 5), "Item should be gone from the trash")
        XCTAssertTrue(app.staticTexts["recentlyDeleted.emptyStateLabel"].waitForExistence(timeout: 5))
        leaveTrash()
        XCTAssertFalse(cell(seedName).exists)
    }

    func testJourney6_DeletePermanentlyAsksToConfirmAndCancelKeepsItem() {
        deleteViaContextMenu(seedName)
        openRecentlyDeleted()
        trashRow(seedName).tap()
        tapSheetButton("Delete Permanently")
        let alert = app.alerts["Delete Permanently?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete Permanently needs a confirm")
        tapAlertButton("Cancel", in: alert)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(trashRow(seedName).exists, "Cancel keeps the item in the trash")
    }

    func testJourney6_EmptyTrashAsksToConfirmAndCancelKeepsItems() {
        deleteViaContextMenu(seedName)
        openRecentlyDeleted()
        app.buttons["recentlyDeleted.emptyTrashButton"].tap()
        let alert = app.alerts["Empty Trash?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Empty Trash needs a confirm")
        tapAlertButton("Cancel", in: alert)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(trashRow(seedName).exists)
    }

    func testJourney6_EmptyTrashRemovesEverything() {
        deleteViaContextMenu(seedName)
        openRecentlyDeleted()
        app.buttons["recentlyDeleted.emptyTrashButton"].tap()
        let alert = app.alerts["Empty Trash?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let confirm = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Empty' OR label == 'Delete'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Confirm button missing. Alert: \(alert.debugDescription)")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["recentlyDeleted.emptyStateLabel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recentlyDeleted.emptyTrashButton"].isEnabled, "Empty Trash is disabled when empty")
    }

    // MARK: - Failure paths

    /// Restoring into a folder that already has the same name gives " 1".
    func testJourney6_RestoreWithSameNameInFolderGetsNumberSuffix() {
        createDocument(named: "alpha")
        deleteViaContextMenu("alpha.rtf")
        createDocument(named: "alpha")
        openRecentlyDeleted()
        trashRow("alpha.rtf").firstMatch.tap()
        tapSheetButton("Restore")
        let restoreError = app.alerts.firstMatch.exists ? app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ") : "none"
        let trashEmpty = app.staticTexts["recentlyDeleted.emptyStateLabel"].waitForExistence(timeout: 3)
        leaveTrash()
        XCTAssertTrue(cell("alpha.rtf").waitForExistence(timeout: 5), "The new document stays")
        XCTAssertTrue(cell("alpha 1.rtf").waitForExistence(timeout: 5), "Restored duplicate should be \"alpha 1.rtf\"; grid: \(gridNames()); trash emptied: \(trashEmpty); alert: \(restoreError)")
    }

    /// Restoring when the original folder is gone recreates it.
    func testJourney6_RestoreWhenOriginalFolderGoneRecreatesIt() {
        tapBarButton("newFolderButton", fallbackLabel: "New Folder")
        let alert = app.alerts["New Folder"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        type("Box", into: alert.textFields["browser.newFolderNameField"])
        tapAlertButton("Create", in: alert)
        cell("Box").tap()
        XCTAssertTrue(app.navigationBars["Box"].waitForExistence(timeout: 5))
        createDocument(named: "inner")
        deleteViaContextMenu("inner.rtf")
        app.navigationBars["Box"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["KoalaTVault"].waitForExistence(timeout: 5))
        deleteViaContextMenu("Box")

        openRecentlyDeleted()
        trashRow("inner.rtf").tap()
        tapSheetButton("Restore")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Restore should succeed without an error")
        leaveTrash()
        XCTAssertTrue(cell("Box").waitForExistence(timeout: 5), "The original folder should be recreated")
        cell("Box").tap()
        XCTAssertTrue(cell("inner.rtf").waitForExistence(timeout: 5), "The file should be inside the recreated folder")
    }

    // MARK: - Each vault has its own Recently Deleted

    func testJourney6_EncryptedVaultHasItsOwnTrash() {
        deleteViaContextMenu(seedName)
        openRecentlyDeleted()
        XCTAssertTrue(trashRow(seedName).waitForExistence(timeout: 5))
        leaveTrash()

        lockApp()
        unlockWithPassword()
        XCTAssertTrue(app.navigationBars["Test Vault"].waitForExistence(timeout: 5), "Browser is titled with the vault")
        XCTAssertFalse(cell(seedName).exists)
        createDocument(named: "A")
        deleteViaContextMenu("A.rtf")
        openRecentlyDeleted()
        XCTAssertTrue(trashRow("A.rtf").waitForExistence(timeout: 5), "A.rtf should be in Test Vault's trash")
        XCTAssertFalse(trashRow(seedName).exists, "The unencrypted vault's trash is not shown here")
        trashRow("A.rtf").tap()
        tapSheetButton("Restore")
        XCTAssertTrue(trashRow("A.rtf").waitForNonExistence(timeout: 5))
        leaveTrash()
        XCTAssertTrue(cell("A.rtf").waitForExistence(timeout: 5), "A.rtf should be back in the grid")
    }
}
