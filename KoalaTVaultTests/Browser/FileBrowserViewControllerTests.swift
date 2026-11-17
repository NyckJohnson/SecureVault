import Testing
import UIKit

@testable import KoalaTVault

/// View tests for the browser grid. Seams assumed are listed in `BrowserViewTestSupport.swift`.
/// Assumptions about the UI beyond the memo: Sort opens an action sheet whose titles start with "Name", "Type"
/// and "Date Modified"; New Folder / New Document / Rename are alerts with one text field and a confirm
/// action (any non-Cancel action); the Select button (`selectButton`) toggles select mode; the actions menu
/// (`browser.actionsMenuButton`) and, in select mode only, the select actions menu
/// (`browser.selectActionsMenuButton`) hold the entries (`browser.menu.*`), run through `Rig.chooseMenu`; the title row (under the bar) shows the view model's `title`.
@MainActor
@Suite struct FileBrowserViewControllerTests {
    @MainActor
    struct Rig {
        let host: BrowserViewHost
        let controller: FileBrowserViewController
        let store: MockVaultStoring
        let preferences: MockPreferencesStoring
        let thumbnails: BrowserFakeThumbnails
        let viewer: MockViewerFactory
        let settings: MockSettingsFactory
        let lock: MockVaultLocking
        let transfer: MockVaultTransferring
        let lockCount: LockCounter

        var grid: UICollectionView? { host.element("fileGrid") as? UICollectionView }

        var cells: [FileCell] {
            guard let grid, grid.numberOfSections > 0 else { return [] }
            grid.layoutIfNeeded()
            return (0..<grid.numberOfItems(inSection: 0)).compactMap { item in
                grid.cellForItem(at: IndexPath(item: item, section: 0)) as? FileCell
            }
        }

        var names: [String] {
            cells.compactMap {
                $0.accessibilityIdentifier?.replacingOccurrences(of: "browser.cell.", with: "")
            }
        }

        func indexPath(_ name: String) -> IndexPath? {
            names.firstIndex(of: name).map { IndexPath(item: $0, section: 0) }
        }

        func tapCell(_ name: String) {
            guard let grid, let path = indexPath(name) else { return }
            grid.delegate?.collectionView?(grid, didSelectItemAt: path)
        }

        /// The actions of the item's context menu, by title.
        func menuActions(for name: String) -> [UIAction] {
            guard let path = indexPath(name), let menu = controller.contextMenu(at: path) else {
                return []
            }
            return menu.children.compactMap { $0 as? UIAction }
        }

        /// The grid delegate's configuration for an item, so the real menu stays wired.
        func menuConfiguration(for name: String) -> UIContextMenuConfiguration? {
            guard let grid, let path = indexPath(name) else { return nil }
            return grid.delegate?.collectionView?(
                grid, contextMenuConfigurationForItemsAt: [path], point: .zero)
        }

        func choose(_ title: String, in name: String) {
            menuActions(for: name).first { $0.title == title }?.performWithSender(nil, target: nil)
        }

        /// Runs the bar-menu entry with this identifier (`browser.menu.*`), as a tap on it would.
        func chooseMenu(_ entry: String) {
            BarMenu.perform(entry, in: controller)
        }

        func menuIdentifiers(for name: String) -> [String] {
            menuActions(for: name).map(\.identifier.rawValue)
        }
    }

    @MainActor
    final class LockCounter {
        var count = 0
    }

    func makeRig(
        folder: String? = nil, withSampleContent: Bool = true, failing: Bool = false,
        waitForCells: Bool = true,
        regularWidth: Bool = false, encryptedStore: Bool = false
    ) async throws -> Rig {
        let store = MockVaultStoring(
            withSampleContent: withSampleContent, name: encryptedStore ? "Work" : "KoalaTVault",
            isEncrypted: encryptedStore)
        let directory: VaultDirectory
        if let folder {
            let item = try #require(store.allItems.first { $0.name == folder && $0.isDirectory })
            directory = try #require(item.asDirectory)
        } else {
            directory = store.root
        }
        let preferences = MockPreferencesStoring()
        let thumbnails = BrowserFakeThumbnails()
        let exporter = MockVaultExporting()
        let viewer = MockViewerFactory()
        let settings = MockSettingsFactory()
        if failing { store.errorToThrow = .notFound }
        let lock = MockVaultLocking(
            vaults: [MockVaultLocking.Vault(id: "primary", name: "Work", password: "correct horse")])
        if encryptedStore { try await lock.open(password: "correct horse") }
        let transfer = MockVaultTransferring()
        let lockCount = LockCounter()
        let controller = FileBrowserViewController(
            directory: directory, store: store, preferences: preferences, thumbnails: thumbnails,
            exporter: exporter, exportPresenter: ExportPresenter(exporter: exporter),
            importPresenter: ImportPresenter(
                importer: MockVaultImporting(), cameraRoll: MockCameraRollDeleting(), store: store),
            viewerFactory: viewer, settingsFactory: settings,
            vaultServices: BrowserVaultServices(
                lock: lock, transfer: transfer, onLock: { lockCount.count += 1 }))
        let host = BrowserViewHost(
            content: UINavigationController(rootViewController: controller), regularWidth: regularWidth)
        let rig = Rig(
            host: host, controller: controller, store: store, preferences: preferences,
            thumbnails: thumbnails,
            viewer: viewer, settings: settings, lock: lock, transfer: transfer, lockCount: lockCount)
        if waitForCells && withSampleContent && !failing {
            await BrowserViewSupport.waitUntil { !rig.cells.isEmpty }
        }
        return rig
    }

    private func enterSelectMode(_ rig: Rig, selecting names: [String]) async {
        rig.host.tap("selectButton")
        for name in names { rig.tapCell(name) }
        await BrowserViewSupport.settle()
    }

    // MARK: - Identifiers and layout

    @Test(
        "The root browser has the grid, the settings gear, Select and the actions menu button identified")
    func rootIdentifiers() async throws {
        let rig = try await makeRig()
        for id in ["fileGrid", "settingsButton"] {
            #expect(rig.host.element(id) != nil, "missing \(id)")
        }
        for id in ["selectButton", "browser.actionsMenuButton"] {
            #expect(BarMenu.item(id, in: rig.controller) != nil, "missing \(id)")
        }
    }

    @Test("A subfolder's browser has no settings button")
    func subfolderHasNoSettingsButton() async throws {
        let rig = try await makeRig(folder: "Photos")
        #expect(rig.host.element("settingsButton") == nil)
        #expect(BarMenu.item("browser.actionsMenuButton", in: rig.controller) != nil)
    }

    @Test("The grid shows the folder's items in order, folders first")
    func gridItems() async throws {
        let rig = try await makeRig()
        #expect(
            rig.names == [
                "Documents", "Photos", "Beach.jpg", "Holiday.mov", "Notes.rtf", "Tax Return 2025.pdf",
            ])
    }

    @Test("Each cell shows the item's name and size text")
    func cellContent() async throws {
        let rig = try await makeRig()
        let cell = try #require(
            rig.cells.first { $0.accessibilityIdentifier == "browser.cell.Beach.jpg" })
        let texts = BrowserViewHost.texts(in: cell)
        #expect(texts.contains("Beach.jpg"))
        #expect(texts.contains(ByteCountFormatter.string(fromByteCount: 2_481_152, countStyle: .file)))
    }

    @Test("Cells ask for their item's thumbnail")
    func cellsRequestThumbnails() async throws {
        let rig = try await makeRig()
        let beach = try #require(rig.store.allItems.first { $0.name == "Beach.jpg" })
        await BrowserViewSupport.waitUntil { rig.thumbnails.requested().contains(beach.id) }
        #expect(rig.thumbnails.requested().contains(beach.id))
    }

    @Test("An empty folder shows No files yet")
    func emptyState() async throws {
        let rig = try await makeRig(withSampleContent: false)
        let label = try #require(await rig.host.waitForElement("browser.emptyStateLabel") as? UILabel)
        await BrowserViewSupport.waitUntil { label.text == "No files yet" && !label.isHidden }
        #expect(label.text == "No files yet")
        #expect(label.isHidden == false)
    }

    @Test("A folder with items hides the empty message")
    func nonEmptyHidesMessage() async throws {
        let rig = try await makeRig()
        let label = rig.host.element("browser.emptyStateLabel") as? UILabel
        #expect(label == nil || label?.isHidden == true)
    }

    @Test("A load error is presented as an alert")
    func loadErrorAlert() async throws {
        let rig = try await makeRig(failing: true, waitForCells: false)
        let alert = await rig.host.alert()
        #expect(alert?.message == VaultStoreError.notFound.localizedDescription)
    }

    // MARK: - Open

    @Test("Tapping a folder cell pushes a browser for that folder")
    func tapFolderPushes() async throws {
        let rig = try await makeRig()
        rig.tapCell("Photos")
        await BrowserViewSupport.waitUntil { (rig.host.navigation?.viewControllers.count ?? 0) == 2 }
        #expect(rig.host.navigation?.viewControllers.count == 2)
        let pushed = try #require(rig.host.navigation?.topViewController as? FileBrowserViewController)
        await BrowserViewSupport.waitUntil { TitleRow.shows("Photos", in: pushed) }
        #expect(TitleRow.shows("Photos", in: pushed))
    }

    @Test("Tapping a file opens the viewer on the folder's files, starting at the tapped one")
    func tapFileOpensViewer() async throws {
        let rig = try await makeRig()
        rig.tapCell("Holiday.mov")
        let files = rig.store.allItems.filter {
            $0.name != "Photos" && $0.name != "Documents" && $0.id.split(separator: "/").count == 1
        }
        let sortedNames = ["Beach.jpg", "Holiday.mov", "Notes.rtf", "Tax Return 2025.pdf"]
        let ids = sortedNames.compactMap { name in files.first { $0.name == name }?.id }
        await BrowserViewSupport.waitUntil { !rig.viewer.calls.isEmpty }
        #expect(rig.viewer.calls == [.makeViewer(itemIDs: ids, startingAt: 1)])
    }

    @Test("Tapping an .rtf file opens the editor")
    func tapRtfOpensEditor() async throws {
        let rig = try await makeRig()
        let notes = try #require(rig.store.allItems.first { $0.name == "Notes.rtf" })
        rig.tapCell("Notes.rtf")
        await BrowserViewSupport.waitUntil { !rig.viewer.calls.isEmpty }
        #expect(rig.viewer.calls == [.makeEditor(notes.id)])
    }

    @Test("The settings button opens Settings")
    func settingsButtonOpensSettings() async throws {
        let rig = try await makeRig()
        rig.host.tap("settingsButton")
        await BrowserViewSupport.waitUntil { !rig.settings.calls.isEmpty }
        #expect(rig.settings.calls == [.makeSettings])
    }

    // MARK: - Lock button and vault actions

    @Test(
        "The root of the unencrypted vault has a Lock button that calls onLock",
        arguments: [false, true])
    func lockButtonCallsOnLock(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        #expect(rig.host.element("lockButton") != nil)
        rig.host.tap("lockButton")
        #expect(rig.lockCount.count == 1)
    }

    @Test("A pushed subfolder has no Lock button", arguments: [false, true])
    func subfolderHasNoLockButton(encrypted: Bool) async throws {
        let rig = try await makeRig(folder: "Photos", encryptedStore: encrypted)
        #expect(rig.host.element("lockButton") == nil)
    }

    // MARK: - Bar layout (the title row itself is tested in FileBrowserTitleRowTests.swift)

    private func leadingIDs(_ rig: Rig) -> [String] {
        (rig.controller.navigationItem.leftBarButtonItems ?? []).map {
            $0.accessibilityIdentifier ?? ($0.customView?.accessibilityIdentifier ?? "")
        }
    }

    @Test("Select mode shows only Cancel at the left")
    func selectModeLeadingIsCancelOnly() async throws {
        let rig = try await makeRig()
        await enterSelectMode(rig, selecting: ["Beach.jpg"])
        #expect(leadingIDs(rig) == ["browser.cancelSelectButton"])
    }

    @Test(
        "The select menu's Move to Vault… and Copy to Vault… present the vault picker with no sheet between",
        arguments: ["browser.menu.moveToVault", "browser.menu.copyToVault"])
    func bulkVaultMenuEntryPresentsPicker(entry: String) async throws {
        let rig = try await makeRig()
        await enterSelectMode(rig, selecting: ["Beach.jpg"])
        rig.chooseMenu(entry)
        await BrowserViewSupport.waitUntil { rig.host.element("vaultPicker.useButton") != nil }
        #expect(rig.host.element("vaultPicker.useButton") != nil)
        let top = rig.host.topmost
        #expect(!(top is UIAlertController))
        let picker = (top as? UINavigationController)?.viewControllers.first ?? top
        #expect(picker is VaultPickerViewController)
    }

    @Test(
        "The context menu's vault items present the vault picker",
        arguments: [
            "Move to Vault…", "Copy to Vault…",
        ])
    func contextVaultItemPresentsPicker(title: String) async throws {
        let rig = try await makeRig()
        rig.choose(title, in: "Beach.jpg")
        await BrowserViewSupport.waitUntil { rig.host.element("vaultPicker.useButton") != nil }
        #expect(rig.host.element("vaultPicker.useButton") != nil)
    }

    @Test("Cancelling the vault picker transfers nothing")
    func vaultPickerCancelTransfersNothing() async throws {
        let rig = try await makeRig()
        rig.choose("Move to Vault…", in: "Beach.jpg")
        await BrowserViewSupport.waitUntil { rig.host.element("vaultPicker.cancelButton") != nil }
        rig.host.tap("vaultPicker.cancelButton")
        await BrowserViewSupport.settle()
        #expect(rig.transfer.calls.isEmpty)
    }

    @Test("Choosing the unencrypted vault in the picker transfers the item and moves it out")
    func vaultPickerTransfers() async throws {
        let rig = try await makeRig(encryptedStore: true)
        rig.choose("Move to Vault…", in: "Beach.jpg")
        await BrowserViewSupport.waitUntil { rig.host.element("vaultPicker.unencryptedRow") != nil }
        rig.host.tap("vaultPicker.unencryptedRow")
        await BrowserViewSupport.waitUntil { !rig.transfer.calls.isEmpty }
        #expect(rig.transfer.calls.count == 1)
        #expect(rig.transfer.calls.first?.removingOriginals == true)
        #expect(rig.settings.calls.isEmpty)
    }

    @Test("A transfer refused with limitReached presents the paywall")
    func limitReachedPresentsPaywall() async throws {
        let rig = try await makeRig(encryptedStore: true)
        rig.transfer.errorToThrow = .limitReached
        rig.choose("Copy to Vault…", in: "Beach.jpg")
        await BrowserViewSupport.waitUntil { rig.host.element("vaultPicker.unencryptedRow") != nil }
        rig.host.tap("vaultPicker.unencryptedRow")
        await BrowserViewSupport.waitUntil { rig.settings.calls.contains(.makePaywall) }
        #expect(rig.settings.calls == [.makePaywall])
    }

    // MARK: - Sort, New Folder, New Document

    @Test("Sort offers Name, Type and Date Modified, and a choice is saved")
    func sortSheet() async throws {
        let rig = try await makeRig()
        rig.chooseMenu("browser.menu.sort")
        let sheet = try #require(await rig.host.alert())
        let titles = sheet.actionTitles
        #expect(titles.contains { $0.hasPrefix("Name") })
        #expect(titles.contains { $0.hasPrefix("Type") })
        #expect(titles.contains { $0.hasPrefix("Date Modified") })
        let type = try #require(sheet.actions.first { $0.title?.hasPrefix("Type") == true })
        type.fire()
        await BrowserViewSupport.waitUntil { rig.preferences.sortOption == .type }
        #expect(rig.preferences.sortOption == .type)
        #expect(rig.preferences.sortDirection == .ascending)
    }

    @Test("Sort anchors its iPad popover on the actions menu button")
    func sortAnchor() async throws {
        let rig = try await makeRig(regularWidth: true)
        rig.chooseMenu("browser.menu.sort")
        let sheet = try #require(await rig.host.alert())
        if let popover = sheet.popoverPresentationController {
            #expect(
                popover.barButtonItem === BarMenu.item("browser.actionsMenuButton", in: rig.controller))
        }
    }

    @Test("New Folder asks for a name and creates the folder")
    func newFolder() async throws {
        let rig = try await makeRig()
        rig.chooseMenu("browser.menu.newFolder")
        let alert = try #require(await rig.host.alert())
        let field = try #require(alert.textFields?.first)
        field.text = "  Trips "
        alert.fireConfirm()
        await BrowserViewSupport.waitUntil { rig.names.contains("Trips") }
        #expect(rig.names.contains("Trips"))
    }

    @Test("New Folder with a blank name does nothing")
    func newFolderBlank() async throws {
        let rig = try await makeRig()
        rig.chooseMenu("browser.menu.newFolder")
        let alert = try #require(await rig.host.alert())
        alert.textFields?.first?.text = "   "
        alert.fireConfirm()
        await BrowserViewSupport.settle()
        #expect(
            !rig.store.calls.contains { if case .createFolder = $0 { return true } else { return false } }
        )
    }

    @Test("New Document creates the file and opens the editor on it")
    func newDocument() async throws {
        let rig = try await makeRig()
        rig.chooseMenu("browser.menu.newDocument")
        let alert = try #require(await rig.host.alert())
        alert.textFields?.first?.text = "Draft"
        alert.fireConfirm()
        await BrowserViewSupport.waitUntil { !rig.viewer.calls.isEmpty }
        let created = rig.store.allItems.first { $0.name.hasPrefix("Draft") }
        #expect(created != nil)
        #expect(rig.viewer.calls == [.makeEditor(try #require(created).id)])
    }

    // MARK: - Select mode

    @Test("Select mode shows Select Items, then the count, and the select actions menu")
    func selectMode() async throws {
        let rig = try await makeRig()
        #expect(BarMenu.item("browser.selectActionsMenuButton", in: rig.controller) == nil)
        rig.host.tap("selectButton")
        await BrowserViewSupport.waitUntil { TitleRow.shows("Select Items", in: rig.controller) }
        #expect(TitleRow.shows("Select Items", in: rig.controller))
        #expect(BarMenu.item("browser.selectActionsMenuButton", in: rig.controller) != nil)
        rig.tapCell("Beach.jpg")
        rig.tapCell("Notes.rtf")
        await BrowserViewSupport.waitUntil { TitleRow.shows("2 Selected", in: rig.controller) }
        #expect(TitleRow.shows("2 Selected", in: rig.controller))
    }

    @Test("In select mode a tap selects instead of opening")
    func selectModeTapDoesNotOpen() async throws {
        let rig = try await makeRig()
        rig.host.tap("selectButton")
        rig.tapCell("Notes.rtf")
        rig.tapCell("Photos")
        await BrowserViewSupport.settle()
        #expect(rig.viewer.calls.isEmpty)
        #expect(rig.host.navigation?.viewControllers.count == 1)
    }

    @Test("Leaving select mode restores the folder title and removes the select actions menu")
    func leaveSelectMode() async throws {
        let rig = try await makeRig()
        await enterSelectMode(rig, selecting: ["Beach.jpg"])
        #expect(rig.host.element("browser.cancelSelectButton") != nil)
        rig.host.tap("browser.cancelSelectButton")
        await BrowserViewSupport.waitUntil {
            BarMenu.item("browser.selectActionsMenuButton", in: rig.controller) == nil
        }
        #expect(BarMenu.item("browser.selectActionsMenuButton", in: rig.controller) == nil)
        #expect(!TitleRow.shows("1 Selected", in: rig.controller))
        #expect(!TitleRow.shows("Select Items", in: rig.controller))
        #expect(TitleRow.shows("KoalaTVault", in: rig.controller))
        #expect(rig.host.element("browser.cancelSelectButton") == nil)
    }

    @Test("Bulk Delete confirms with Delete N items? and then trashes the selection")
    func bulkDelete() async throws {
        let rig = try await makeRig()
        await enterSelectMode(rig, selecting: ["Beach.jpg", "Notes.rtf"])
        rig.chooseMenu("browser.menu.bulkDelete")
        let alert = try #require(await rig.host.alert())
        #expect(alert.title == "Delete 2 items?")
        #expect(alert.message?.contains("Recently Deleted") == true)
        #expect(rig.store.trashBatches.isEmpty)
        #expect(
            !rig.store.calls.contains { if case .moveToTrash = $0 { return true } else { return false } })
        alert.fire("Delete")
        await BrowserViewSupport.waitUntil { !rig.names.contains("Beach.jpg") }
        #expect(!rig.names.contains("Beach.jpg"))
        #expect(!rig.names.contains("Notes.rtf"))
    }

    @Test("Cancelling the bulk delete confirmation trashes nothing")
    func bulkDeleteCancel() async throws {
        let rig = try await makeRig()
        await enterSelectMode(rig, selecting: ["Beach.jpg"])
        rig.chooseMenu("browser.menu.bulkDelete")
        let alert = try #require(await rig.host.alert())
        alert.fire("Cancel")
        await BrowserViewSupport.settle()
        #expect(rig.store.trashBatches.isEmpty)
        #expect(
            !rig.store.calls.contains { if case .moveToTrash = $0 { return true } else { return false } })
    }

    @Test("Bulk Copy copies the selection into the current folder")
    func bulkCopy() async throws {
        let rig = try await makeRig()
        await enterSelectMode(rig, selecting: ["Beach.jpg"])
        rig.chooseMenu("browser.menu.bulkCopy")
        await BrowserViewSupport.waitUntil { rig.names.contains("Beach 1.jpg") }
        #expect(rig.names.contains("Beach 1.jpg"))
    }

    @Test("Bulk Move opens the folder picker, and the picker's choice moves the selection")
    func bulkMove() async throws {
        let rig = try await makeRig()
        await enterSelectMode(rig, selecting: ["Beach.jpg"])
        rig.chooseMenu("browser.menu.bulkMove")
        await BrowserViewSupport.waitUntil { rig.host.topmost is UINavigationController }
        let nav = try #require(rig.host.topmost as? UINavigationController)
        #expect(nav.topViewController is FolderPickerViewController)
        rig.host.tap("folderPicker.moveHereButton")
        // Moving into the folder the item already lives in does nothing, so the item stays.
        await BrowserViewSupport.settle()
        #expect(rig.names.contains("Beach.jpg"))
    }

    @Test("Swiping the picker down counts as cancel, so a later single move moves only its own item")
    func swipeDownPickerCountsAsCancel() async throws {
        let rig = try await makeRig()
        await enterSelectMode(rig, selecting: ["Beach.jpg"])
        rig.chooseMenu("browser.menu.bulkMove")
        await BrowserViewSupport.waitUntil { rig.host.topmost is UINavigationController }
        let nav = try #require(rig.host.topmost as? UINavigationController)
        let presentation = try #require(nav.presentationController)
        rig.controller.presentationControllerDidDismiss(presentation)
        rig.controller.dismiss(animated: false)
        await BrowserViewSupport.waitUntil {
            !(rig.host.topmost is UINavigationController) || rig.host.topmost === rig.host.root
        }
        await BrowserViewSupport.settle()

        rig.choose("Move", in: "Notes.rtf")
        await BrowserViewSupport.waitUntil {
            rig.host.topmost is UINavigationController && rig.host.topmost !== rig.host.root
        }
        let picker = try #require(
            (rig.host.topmost as? UINavigationController)?.topViewController
                as? FolderPickerViewController)
        let table = try #require(Self.findTable(in: picker.view))
        await BrowserViewSupport.waitUntil {
            table.numberOfSections > 0 && table.numberOfRows(inSection: 0) == 2
        }
        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        let pickerNav = try #require(rig.host.topmost as? UINavigationController)
        await BrowserViewSupport.waitUntil { pickerNav.viewControllers.count == 2 }
        rig.host.tap("folderPicker.moveHereButton")
        await BrowserViewSupport.waitUntil { !rig.names.contains("Notes.rtf") }

        let beachID = try #require(rig.store.allItems.first { $0.name == "Beach.jpg" }).id
        let moved = rig.store.calls.compactMap { call -> String? in
            if case .move(let id, _) = call { return id }
            return nil
        }
        #expect(!moved.isEmpty)
        #expect(!moved.contains(beachID))
    }

    @Test("Cancelling the folder picker moves nothing")
    func pickerCancelMovesNothing() async throws {
        let rig = try await makeRig()
        await enterSelectMode(rig, selecting: ["Beach.jpg"])
        rig.chooseMenu("browser.menu.bulkMove")
        await BrowserViewSupport.waitUntil { rig.host.topmost is UINavigationController }
        rig.host.tap("folderPicker.cancelButton")
        await BrowserViewSupport.settle()
        #expect(!rig.store.calls.contains { if case .move = $0 { return true } else { return false } })
        #expect(rig.names.contains("Beach.jpg"))
    }

    @Test("Bulk Export anchors its iPad popover on the select actions menu button")
    func bulkExportAnchor() async throws {
        let rig = try await makeRig(regularWidth: true)
        await enterSelectMode(rig, selecting: ["Beach.jpg"])
        rig.chooseMenu("browser.menu.bulkExport")
        let sheet = try #require(await rig.host.alert())
        #expect(sheet.actionTitles.contains("Save to Files"))
        // UIKit only gives an action sheet a popover on an iPad idiom; on an iPhone destination there is no
        // popover to inspect, so the anchor is checked wherever one exists (see the report: needs a seam).
        if let popover = sheet.popoverPresentationController {
            #expect(
                popover.barButtonItem === BarMenu.item("browser.selectActionsMenuButton", in: rig.controller))
        }
    }

    @Test("Import anchors its iPad popover on the actions menu button and offers the four choices")
    func importAnchor() async throws {
        let rig = try await makeRig(regularWidth: true)
        rig.chooseMenu("browser.menu.import")
        let sheet = try #require(await rig.host.alert())
        #expect(sheet.actionTitles.contains("Choose Files"))
        #expect(sheet.actionTitles.contains("Choose Folder"))
        #expect(sheet.actionTitles.contains("Choose Photos"))
        // Anchor checked wherever the destination gives the sheet a popover (iPad idiom only).
        if let popover = sheet.popoverPresentationController {
            #expect(
                popover.barButtonItem === BarMenu.item("browser.actionsMenuButton", in: rig.controller))
        }
    }

    // MARK: - Context menu

    @Test("The context menu offers Export, Move, Copy, Rename, Delete and the two vault actions")
    func contextMenuActions() async throws {
        let rig = try await makeRig()
        #expect(rig.menuConfiguration(for: "Beach.jpg") != nil)
        #expect(
            rig.menuActions(for: "Beach.jpg").map(\.title) == [
                "Export", "Move", "Copy", "Rename", "Delete", "Move to Vault…", "Copy to Vault…",
            ])
        #expect(
            rig.menuIdentifiers(for: "Beach.jpg") == [
                "browser.contextMenu.export", "browser.contextMenu.move", "browser.contextMenu.copy",
                "browser.contextMenu.rename", "browser.contextMenu.delete",
                "browser.contextMenu.moveToVault", "browser.contextMenu.copyToVault",
            ])
    }

    @Test("Rename starts with the current name and renames through the store")
    func contextRename() async throws {
        let rig = try await makeRig()
        rig.choose("Rename", in: "Beach.jpg")
        let alert = try #require(await rig.host.alert())
        #expect(alert.textFields?.first?.text == "Beach.jpg")
        alert.textFields?.first?.text = "Shore.jpg"
        alert.fireConfirm()
        await BrowserViewSupport.waitUntil { rig.names.contains("Shore.jpg") }
        #expect(rig.names.contains("Shore.jpg"))
        #expect(!rig.names.contains("Beach.jpg"))
    }

    @Test("Delete asks first, naming the item and mentioning Recently Deleted")
    func contextDelete() async throws {
        let rig = try await makeRig()
        rig.choose("Delete", in: "Beach.jpg")
        let alert = try #require(await rig.host.alert())
        #expect(alert.title == "Delete \"Beach.jpg\"?")
        #expect(alert.message?.contains("Recently Deleted") == true)
        alert.fire("Delete")
        await BrowserViewSupport.waitUntil { !rig.names.contains("Beach.jpg") }
        #expect(!rig.names.contains("Beach.jpg"))
    }

    @Test("Copy from the context menu copies the item into the folder")
    func contextCopy() async throws {
        let rig = try await makeRig()
        rig.choose("Copy", in: "Notes.rtf")
        await BrowserViewSupport.waitUntil { rig.names.contains("Notes 1.rtf") }
        #expect(rig.names.contains("Notes 1.rtf"))
    }

    @Test("Move from the context menu opens the folder picker, and choosing a folder moves the item")
    func contextMove() async throws {
        let rig = try await makeRig()
        rig.choose("Move", in: "Beach.jpg")
        await BrowserViewSupport.waitUntil { rig.host.topmost is UINavigationController }
        let nav = try #require(rig.host.topmost as? UINavigationController)
        let picker = try #require(nav.topViewController as? FolderPickerViewController)
        let table = try #require(Self.findTable(in: picker.view))
        await BrowserViewSupport.waitUntil {
            table.numberOfSections > 0 && table.numberOfRows(inSection: 0) == 2
        }
        // Rows are Documents, Photos: pick Photos.
        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        await BrowserViewSupport.waitUntil { nav.viewControllers.count == 2 }
        rig.host.tap("folderPicker.moveHereButton")
        await BrowserViewSupport.waitUntil { !rig.names.contains("Beach.jpg") }
        #expect(!rig.names.contains("Beach.jpg"))
    }

    @Test("Export from the context menu shows the export sheet")
    func contextExport() async throws {
        let rig = try await makeRig(regularWidth: true)
        rig.choose("Export", in: "Beach.jpg")
        let sheet = try #require(await rig.host.alert())
        #expect(sheet.actionTitles.contains("Save to Files"))
        let path = try #require(rig.indexPath("Beach.jpg"))
        let cell = try #require(rig.grid?.cellForItem(at: path))
        if let popover = sheet.popoverPresentationController {
            #expect(popover.sourceView === cell)
        }
    }

    private static func findTable(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        for subview in view.subviews { if let found = findTable(in: subview) { return found } }
        return nil
    }

    // MARK: - Drag and drop

    @Test("A folder cell is a drop target")
    func folderIsDropTarget() async throws {
        let rig = try await makeRig()
        #expect(rig.controller.dropTargetAllowed(at: rig.indexPath("Photos")) == true)
    }

    @Test("A file cell and empty space are not drop targets")
    func fileIsNotDropTarget() async throws {
        let rig = try await makeRig()
        #expect(rig.controller.dropTargetAllowed(at: rig.indexPath("Beach.jpg")) == false)
        #expect(rig.controller.dropTargetAllowed(at: nil) == false)
    }

    @Test("Dropping an item of this app onto a folder cell moves it into the folder")
    func dropOntoFolderMoves() async throws {
        let rig = try await makeRig()
        let beach = try #require(rig.store.allItems.first { $0.name == "Beach.jpg" })
        await rig.controller.drop(beach, at: try #require(rig.indexPath("Photos")))
        await BrowserViewSupport.waitUntil { !rig.names.contains("Beach.jpg") }
        #expect(!rig.names.contains("Beach.jpg"))
    }

    @Test("Dropping onto a file cell moves nothing")
    func dropOntoFileDoesNothing() async throws {
        let rig = try await makeRig()
        let beach = try #require(rig.store.allItems.first { $0.name == "Beach.jpg" })
        await rig.controller.drop(beach, at: try #require(rig.indexPath("Notes.rtf")))
        #expect(!rig.store.calls.contains { if case .move = $0 { return true } else { return false } })
    }

    @Test("A drop from another app (no item of ours) is ignored")
    func externalDropIgnored() async throws {
        let rig = try await makeRig()
        await rig.controller.drop(nil, at: try #require(rig.indexPath("Photos")))
        #expect(!rig.store.calls.contains { if case .move = $0 { return true } else { return false } })
    }

    @Test("In the unencrypted vault an unencrypted item can be dragged out to other apps")
    func dragOutAllowed() async throws {
        let rig = try await makeRig()
        let items = rig.controller.dragItems(at: try #require(rig.indexPath("Beach.jpg")))
        #expect(items.count == 1)
        #expect(items.first?.itemProvider.registeredTypeIdentifiers.isEmpty == false)
    }

    @Test("In an encrypted vault the drag stays inside the app")
    func dragOutRefusedInEncryptedVault() async throws {
        let rig = try await makeRig(encryptedStore: true)
        let items = rig.controller.dragItems(at: try #require(rig.indexPath("Beach.jpg")))
        #expect(items.count == 1)
        #expect(items.first?.itemProvider.registeredTypeIdentifiers.isEmpty == true)
        #expect((items.first?.localObject as? VaultItem)?.name == "Beach.jpg")
    }
}
