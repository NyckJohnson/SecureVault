//
//  J3BrowseJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 3: Browse. Starts from the No Lock wizard choice with one seeded file.
//

import XCTest

final class J3BrowseJourneyTests: JourneyTestCase {

    private let seedName = "alpha.txt"

    override var launchEnvironment: [String: String] {
        ["UITEST_SEED_FILE_NAME": seedName]
    }

    override func setUp() async throws {
        try await super.setUp()
        openUnencryptedVault()
    }

    // MARK: - Helpers

    /// Starts New Folder and returns the alert (the caller types and confirms).
    private func openNewFolderAlert() -> XCUIElement {
        tapActionsMenuEntry("browser.menu.newFolder", title: "New Folder")
        let alert = app.alerts["New Folder"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "The New Folder alert did not appear")
        return alert
    }

    private func createFolder(named name: String) {
        let alert = openNewFolderAlert()
        type(name, into: alert.textFields["browser.newFolderNameField"])
        tapAlertButton("Create", in: alert)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(cell(name).waitForExistence(timeout: 5), "Folder \(name) did not appear in the grid")
    }

    private func openContextMenu(of name: String) {
        let target = cell(name)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "No cell for \(name)")
        target.press(forDuration: 1.5)
    }

    /// Taps a context-menu action by identifier, falling back to its title.
    private func tapContextAction(_ identifier: String, title: String) {
        let byId = app.buttons[identifier]
        if byId.waitForExistence(timeout: 3) { byId.tap(); return }
        let byTitle = app.buttons[title]
        XCTAssertTrue(byTitle.waitForExistence(timeout: 3), "Context menu action \(title) missing")
        byTitle.tap()
    }

    private func enterSelectMode() {
        tapBarButton("selectButton", fallbackLabel: "Select")
        XCTAssertTrue(browserTitle("Select Items").waitForExistence(timeout: 5), "Select mode did not start")
    }

    private func pickMoveTarget(_ folder: String?) {
        let moveHere = app.buttons["folderPicker.moveHereButton"]
        XCTAssertTrue(moveHere.waitForExistence(timeout: 5), "The folder picker did not appear")
        if let folder {
            let row = app.tables["folderPicker.folderList"].cells["folderPicker.row.\(folder)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Picker has no row for \(folder)")
            row.tap()
            // Tapping a row pushes that folder's picker; Move Here applies to the topmost.
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Tapping \(folder) should push its own picker")
        }
        app.buttons["folderPicker.moveHereButton"].firstMatch.tap()
    }

    // MARK: - Browser contents

    func testJourney3_RootShowsFilesWithNameAndSizeAndGearOnlyOnRoot() {
        XCTAssertTrue(browserTitle("KoalaTVault").exists)
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 5))
        XCTAssertTrue(cell(seedName).staticTexts["browser.cell.\(seedName).nameLabel"].exists)
        XCTAssertTrue(cell(seedName).staticTexts["browser.cell.\(seedName).sizeLabel"].exists)
        XCTAssertTrue(app.buttons["settingsButton"].exists, "Gear should show on the root")
        XCTAssertTrue(app.buttons["selectButton"].exists)
        XCTAssertTrue(app.buttons["browser.actionsMenuButton"].exists)
        app.buttons["browser.actionsMenuButton"].tap()
        for title in ["New Folder", "New Document", "Import", "Sort"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), "Actions menu lacks \(title)")
        }
        app.buttons["New Folder"].firstMatch.tap()  // dismiss by opening an alert, then cancel
        let alert = app.alerts["New Folder"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        tapAlertButton("Cancel", in: alert)
        XCTAssertFalse(app.staticTexts["browser.emptyStateLabel"].exists)
    }

    func testJourney3_LockButtonOnlyOnTheRoot() {
        createFolder(named: "Sub")
        let lock = app.buttons["lockButton"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5), "The root has a Lock button")
        XCTAssertEqual(lock.label, "Lock")
        XCTAssertLessThanOrEqual(lock.frame.maxX, browserTitle("KoalaTVault").frame.minX + 1,
                                 "The \"< lock\" arrow sits left of the vault name")
        XCTAssertFalse(app.navigationBars.buttons["lockButton"].exists, "The bar has no Lock button")
        cell("Sub").tap()
        XCTAssertTrue(browserTitle("Sub").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["lockButton"].exists, "A subfolder has no Lock button")
        XCTAssertFalse(app.buttons["settingsButton"].exists, "A subfolder has no settings gear")
        let back = app.buttons["browser.backButton"]
        XCTAssertTrue(back.exists, "A subfolder's arrow is Back")
        XCTAssertEqual(back.label, "Back")
        XCTAssertLessThanOrEqual(back.frame.maxX, browserTitle("Sub").frame.minX + 1, "The arrow sits left of the folder name")
        back.tap()
        XCTAssertTrue(browserTitle("KoalaTVault").waitForExistence(timeout: 5), "The arrow goes back one folder")
        XCTAssertTrue(app.buttons["lockButton"].exists)
    }

    func testJourney3_FoldersAreListedBeforeFiles() {
        createFolder(named: "Zeta")   // sorts after "alpha.txt" by name, yet must come first
        let folder = cell("Zeta").frame
        let file = cell(seedName).frame
        let folderFirst = folder.minY < file.minY || (folder.minY == file.minY && folder.minX < file.minX)
        XCTAssertTrue(folderFirst, "Folder cell \(folder) should precede file cell \(file)")
    }

    func testJourney3_TapFolderPushesItAndBackReturns() {
        createFolder(named: "Docs")
        cell("Docs").tap()
        XCTAssertTrue(browserTitle("Docs").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settingsButton"].exists, "The gear shows only on the root")
        XCTAssertTrue(app.staticTexts["browser.emptyStateLabel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["browser.emptyStateLabel"].label, "No files yet")

        app.buttons["browser.backButton"].tap()
        XCTAssertTrue(browserTitle("KoalaTVault").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settingsButton"].exists)
        XCTAssertTrue(cell(seedName).exists)
    }

    func testJourney3_NestedFoldersNavigateAndReturn() {
        createFolder(named: "Outer")
        cell("Outer").tap()
        XCTAssertTrue(browserTitle("Outer").waitForExistence(timeout: 5))
        createFolder(named: "Inner")
        cell("Inner").tap()
        XCTAssertTrue(browserTitle("Inner").waitForExistence(timeout: 5))
        app.buttons["browser.backButton"].tap()
        XCTAssertTrue(browserTitle("Outer").waitForExistence(timeout: 5))
        app.buttons["browser.backButton"].tap()
        XCTAssertTrue(browserTitle("KoalaTVault").waitForExistence(timeout: 5))
    }

    // MARK: - New Folder

    func testJourney3_NewFolderAppearsInGrid() {
        createFolder(named: "Photos")
        XCTAssertTrue(cell("Photos").exists)
    }

    func testJourney3_EmptyFolderNameIsIgnored() {
        let alert = openNewFolderAlert()
        tapAlertButton("Create", in: alert)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists, "An empty name must be ignored silently")
        XCTAssertEqual(app.collectionViews["fileGrid"].cells.count, 1, "Only the seeded file should exist")
    }

    func testJourney3_FolderNameWithSlashShowsError() {
        let alert = openNewFolderAlert()
        type("a/b", into: alert.textFields["browser.newFolderNameField"])
        tapAlertButton("Create", in: alert)
        expectErrorAlertAndDismiss(containing: "Names can't contain / or start with .")
        XCTAssertEqual(app.collectionViews["fileGrid"].cells.count, 1, "No folder should be created")
    }

    func testJourney3_FolderNameStartingWithDotShowsError() {
        let alert = openNewFolderAlert()
        type(".hidden", into: alert.textFields["browser.newFolderNameField"])
        tapAlertButton("Create", in: alert)
        expectErrorAlertAndDismiss(containing: "Names can't contain / or start with .")
        XCTAssertEqual(app.collectionViews["fileGrid"].cells.count, 1, "No folder should be created")
    }

    // MARK: - Sort

    func testJourney3_SortSheetListsOptionsAndTappingCurrentFlipsDirection() {
        tapActionsMenuEntry("browser.menu.sort", title: "Sort")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The sort sheet did not appear")
        XCTAssertTrue(sheet.buttons["Name ↑"].exists, "Name should be the current option, ascending")
        XCTAssertTrue(sheet.buttons["Type"].exists)
        XCTAssertTrue(sheet.buttons["Date Modified"].exists)

        sheet.buttons["Name ↑"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))

        tapActionsMenuEntry("browser.menu.sort", title: "Sort")
        XCTAssertTrue(app.sheets.firstMatch.buttons["Name ↓"].waitForExistence(timeout: 5),
                      "Tapping the current option should flip it to descending")
    }

    func testJourney3_SortDescendingReordersTheGrid() {
        createFolderPairAndFile()
        // Folders first; within files, name ascending then descending.
        let ascending = cell("alpha.txt").frame.minX
        _ = ascending
        tapActionsMenuEntry("browser.menu.sort", title: "Sort")
        app.sheets.firstMatch.buttons["Name ↑"].tap()
        XCTAssertTrue(cell("alpha.txt").waitForExistence(timeout: 5))
        let a = cell("Alpha").frame, b = cell("Beta").frame
        XCTAssertTrue(a.minY > b.minY || (a.minY == b.minY && a.minX > b.minX),
                      "Descending: Beta \(b) should precede Alpha \(a)")
    }

    private func createFolderPairAndFile() {
        createFolder(named: "Alpha")
        createFolder(named: "Beta")
        let a = cell("Alpha").frame, b = cell("Beta").frame
        XCTAssertTrue(a.minY < b.minY || (a.minY == b.minY && a.minX < b.minX), "Ascending: Alpha before Beta")
    }

    // MARK: - Context menu

    func testJourney3_LongPressShowsExportMoveCopyRenameDelete() {
        openContextMenu(of: seedName)
        for (identifier, title) in [("browser.contextMenu.export", "Export"), ("browser.contextMenu.move", "Move"),
                                    ("browser.contextMenu.copy", "Copy"), ("browser.contextMenu.rename", "Rename"),
                                    ("browser.contextMenu.delete", "Delete")] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 3) || app.buttons[title].exists,
                          "Context menu is missing \(title)")
        }
    }

    func testJourney3_RenameViaContextMenu() {
        openContextMenu(of: seedName)
        tapContextAction("browser.contextMenu.rename", title: "Rename")
        let alert = app.alerts["Rename"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields["browser.renameField"]
        XCTAssertTrue(field.exists)
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText("beta.txt")
        tapAlertButton("Rename", in: alert)
        XCTAssertTrue(cell("beta.txt").waitForExistence(timeout: 5))
        XCTAssertFalse(cell(seedName).exists)
    }

    func testJourney3_CopyAddsNumberedNameInCurrentFolder() {
        openContextMenu(of: seedName)
        tapContextAction("browser.contextMenu.copy", title: "Copy")
        XCTAssertTrue(cell("alpha 1.txt").waitForExistence(timeout: 5), "Copy should be named \"alpha 1.txt\"")
        XCTAssertTrue(cell(seedName).exists, "The original stays")

        openContextMenu(of: seedName)
        tapContextAction("browser.contextMenu.copy", title: "Copy")
        XCTAssertTrue(cell("alpha 2.txt").waitForExistence(timeout: 5), "Second copy should be \"alpha 2.txt\"")
    }

    // MARK: - Move

    func testJourney3_MoveFileIntoFolderViaPicker() {
        createFolder(named: "Dest")
        openContextMenu(of: seedName)
        tapContextAction("browser.contextMenu.move", title: "Move")
        pickMoveTarget("Dest")

        XCTAssertTrue(cell(seedName).waitForNonExistence(timeout: 5), "The file should leave the root")
        cell("Dest").tap()
        XCTAssertTrue(browserTitle("Dest").waitForExistence(timeout: 5))
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 5), "The file should now be in Dest")
    }

    func testJourney3_FolderPickerCancelMovesNothing() {
        createFolder(named: "Dest")
        openContextMenu(of: seedName)
        tapContextAction("browser.contextMenu.move", title: "Move")
        let cancel = app.buttons["folderPicker.cancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(cell(seedName).exists)
    }

    func testJourney3_MoveIntoItsOwnFolderDoesNothing() {
        openContextMenu(of: seedName)
        tapContextAction("browser.contextMenu.move", title: "Move")
        pickMoveTarget(nil)   // the picker opens at the root, where the file already is
        XCTAssertTrue(app.buttons["folderPicker.moveHereButton"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists, "A no-op move must not raise an error")
        let names = app.collectionViews["fileGrid"].cells.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(names, ["browser.cell.\(seedName)"], "A move into the item's own folder must change nothing")
    }

    func testJourney3_MovePickerLeavesOutTheMovedFolder() {
        createFolder(named: "Loop")
        createFolder(named: "Other")
        openContextMenu(of: "Loop")
        tapContextAction("browser.contextMenu.move", title: "Move")
        XCTAssertTrue(app.buttons["folderPicker.moveHereButton"].waitForExistence(timeout: 5),
                      "The folder picker did not appear")
        let list = app.tables["folderPicker.folderList"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), "The picker has no folder list")
        XCTAssertTrue(list.cells["folderPicker.row.Other"].waitForExistence(timeout: 5),
                      "The picker should offer the other folder")
        XCTAssertFalse(list.cells["folderPicker.row.Loop"].exists,
                       "The picker must not offer the folder being moved")
        app.buttons["folderPicker.cancelButton"].tap()
        XCTAssertTrue(app.buttons["folderPicker.moveHereButton"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(cell("Loop").exists)
    }

    func testJourney3_DragFileOntoFolderMovesIt() {
        createFolder(named: "Target")
        let file = cell(seedName), folder = cell("Target")
        file.press(forDuration: 1.0, thenDragTo: folder, withVelocity: .slow, thenHoldForDuration: 1.0)
        XCTAssertTrue(cell(seedName).waitForNonExistence(timeout: 5), "The dragged file should leave the root")
        folder.tap()
        XCTAssertTrue(browserTitle("Target").waitForExistence(timeout: 5))
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 5))
    }

    // MARK: - Select mode

    func testJourney3_SelectModeTogglesItemsAndShowsCount() {
        enterSelectMode()
        cell(seedName).tap()
        XCTAssertTrue(browserTitle("1 Selected").waitForExistence(timeout: 5))
        XCTAssertTrue(cell(seedName).images["browser.cell.\(seedName).checkmark"].exists
                      || app.descendants(matching: .any)["browser.cell.\(seedName).checkmark"].exists,
                      "A selected cell should show its checkmark")
        cell(seedName).tap()
        XCTAssertTrue(browserTitle("Select Items").waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["browser.cell.\(seedName).checkmark"].exists)
    }

    func testJourney3_SelectModeCancelReturnsToNormalBar() {
        enterSelectMode()
        cell(seedName).tap()
        app.buttons["browser.cancelSelectButton"].tap()
        XCTAssertTrue(browserTitle("KoalaTVault").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settingsButton"].exists)
    }

    func testJourney3_BulkCopyCopiesSelectedItems() {
        createFolder(named: "Pics")
        enterSelectMode()
        cell(seedName).tap()
        cell("Pics").tap()
        XCTAssertTrue(browserTitle("2 Selected").waitForExistence(timeout: 5))
        tapSelectActionsMenuEntry("browser.menu.bulkCopy", title: "Copy")
        XCTAssertTrue(cell("alpha 1.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(cell("Pics 1").waitForExistence(timeout: 5))
    }

    func testJourney3_BulkMoveMovesSelectedItemsIntoFolder() {
        createFolder(named: "Dest")
        createFolder(named: "Other")
        enterSelectMode()
        cell(seedName).tap()
        cell("Other").tap()
        tapSelectActionsMenuEntry("browser.menu.bulkMove", title: "Move")
        pickMoveTarget("Dest")
        XCTAssertTrue(cell(seedName).waitForNonExistence(timeout: 5))
        XCTAssertFalse(cell("Other").exists)
        cell("Dest").tap()
        XCTAssertTrue(browserTitle("Dest").waitForExistence(timeout: 5))
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 5))
        XCTAssertTrue(cell("Other").exists)
    }

    func testJourney3_BulkDeleteRemovesSelectedItemsAfterConfirm() {
        enterSelectMode()
        cell(seedName).tap()
        tapSelectActionsMenuEntry("browser.menu.bulkDelete", title: "Delete")
        let confirm = app.alerts.firstMatch.exists ? app.alerts.firstMatch : app.sheets.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete should ask for confirmation")
        tapAlertButton("Delete", in: confirm)
        XCTAssertTrue(cell(seedName).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["browser.emptyStateLabel"].waitForExistence(timeout: 5))
    }

    // MARK: - Regression: picker Cancel clears the pending move (baseline fix 16)

    /// Makes documents A, B, C and a folder F at the root.
    private func makeABCAndF() {
        createDocument(named: "A")
        createDocument(named: "B")
        createDocument(named: "C")
        createFolder(named: "F")
    }

    private func expectOnlyCMovedIntoF() {
        XCTAssertTrue(cell("C.rtf").waitForNonExistence(timeout: 5), "C should leave the root")
        XCTAssertTrue(cell("A.rtf").exists, "A must stay in the root")
        XCTAssertTrue(cell("B.rtf").exists, "B must stay in the root")
        cell("F").tap()
        XCTAssertTrue(browserTitle("F").waitForExistence(timeout: 5))
        XCTAssertTrue(cell("C.rtf").waitForExistence(timeout: 5), "F should contain C")
        XCTAssertFalse(cell("A.rtf").exists, "F must not contain A")
        XCTAssertFalse(cell("B.rtf").exists, "F must not contain B")
    }

    func testJourney3_PickerCancelAfterBulkMoveClearsPendingMove() {
        makeABCAndF()
        enterSelectMode()
        cell("A.rtf").tap()
        cell("B.rtf").tap()
        XCTAssertTrue(browserTitle("2 Selected").waitForExistence(timeout: 5))
        tapSelectActionsMenuEntry("browser.menu.bulkMove", title: "Move")
        let cancel = app.buttons["folderPicker.cancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "The folder picker did not appear")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))

        app.buttons["browser.cancelSelectButton"].tap()
        XCTAssertTrue(browserTitle("KoalaTVault").waitForExistence(timeout: 5))

        openContextMenu(of: "C.rtf")
        tapContextAction("browser.contextMenu.move", title: "Move")
        pickMoveTarget("F")
        expectOnlyCMovedIntoF()
    }

    func testJourney3_PickerSwipeDownAfterBulkMoveClearsPendingMove() throws {
        makeABCAndF()
        enterSelectMode()
        cell("A.rtf").tap()
        cell("B.rtf").tap()
        tapSelectActionsMenuEntry("browser.menu.bulkMove", title: "Move")
        let moveHere = app.buttons["folderPicker.moveHereButton"]
        XCTAssertTrue(moveHere.waitForExistence(timeout: 5), "The folder picker did not appear")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
        if !moveHere.waitForNonExistence(timeout: 3) {
            throw XCTSkip("XCUITest could not swipe the folder picker sheet away reliably")
        }
        if app.buttons["browser.cancelSelectButton"].waitForExistence(timeout: 3) {
            app.buttons["browser.cancelSelectButton"].tap()
        }
        XCTAssertTrue(browserTitle("KoalaTVault").waitForExistence(timeout: 5))

        openContextMenu(of: "C.rtf")
        tapContextAction("browser.contextMenu.move", title: "Move")
        pickMoveTarget("F")
        expectOnlyCMovedIntoF()
    }
}
