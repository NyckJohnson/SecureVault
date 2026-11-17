import Testing
import UIKit

@testable import KoalaTVault

/// The browser's bar menus, long press in select mode, and selection without a grid reload (feature
/// multiple-vaults-duress-password, device test 2026-11-16). What each entry does is covered by the tests of the
/// old buttons in `FileBrowserViewControllerTests.swift`, which now choose the entries through the menus.
@MainActor
extension FileBrowserViewControllerTests {
    private struct MenuEntrySpec {
        let id: String
        let title: String
        let symbol: String
    }

    private static let normalEntries: [MenuEntrySpec] = [
        MenuEntrySpec(id: "browser.menu.newFolder", title: "New Folder", symbol: "folder.badge.plus"),
        MenuEntrySpec(id: "browser.menu.newDocument", title: "New Document", symbol: "doc.badge.plus"),
        MenuEntrySpec(id: "browser.menu.import", title: "Import", symbol: "square.and.arrow.down"),
        MenuEntrySpec(id: "browser.menu.sort", title: "Sort", symbol: "arrow.up.arrow.down"),
    ]

    private static let selectEntries: [MenuEntrySpec] = [
        MenuEntrySpec(id: "browser.menu.bulkMove", title: "Move", symbol: "folder"),
        MenuEntrySpec(id: "browser.menu.bulkCopy", title: "Copy", symbol: "doc.on.doc"),
        MenuEntrySpec(id: "browser.menu.bulkExport", title: "Export", symbol: "square.and.arrow.up"),
        MenuEntrySpec(id: "browser.menu.moveToVault", title: "Move to Vault…", symbol: "arrow.right.square"),
        MenuEntrySpec(id: "browser.menu.copyToVault", title: "Copy to Vault…", symbol: "plus.square.on.square"),
        MenuEntrySpec(id: "browser.menu.bulkDelete", title: "Delete", symbol: "trash"),
    ]

    private func selectItems(_ rig: Rig, _ names: [String]) async {
        rig.host.tap("selectButton")
        for name in names { rig.tapCell(name) }
        await BrowserViewSupport.settle()
    }

    private func rightIDs(_ rig: Rig) -> [String] {
        (rig.controller.navigationItem.rightBarButtonItems ?? []).map {
            $0.accessibilityIdentifier ?? ($0.customView?.accessibilityIdentifier ?? "")
        }
    }

    // MARK: - Actions menu (outside select mode)

    @Test("Outside select mode the right side holds only Select and the actions menu button")
    func rightSideIsSelectAndMenu() async throws {
        let rig = try await makeRig()
        #expect(Set(rightIDs(rig)) == ["selectButton", "browser.actionsMenuButton"])
        #expect(rightIDs(rig).count == 2)
    }

    @Test("The actions menu button is labelled Actions, shows the line.3.horizontal symbol and opens its menu on tap")
    func actionsMenuButton() async throws {
        let rig = try await makeRig()
        let item = try #require(BarMenu.item("browser.actionsMenuButton", in: rig.controller))
        #expect(BarMenu.menu("browser.actionsMenuButton", in: rig.controller) != nil)
        #expect(BarMenu.opensOnTap("browser.actionsMenuButton", in: rig.controller))
        let label = item.accessibilityLabel ?? item.customView?.accessibilityLabel
        #expect(label == "Actions")
        let image = item.image ?? (item.customView as? UIButton)?.image(for: .normal)
        #expect(BarMenu.isSymbol(image, named: "line.3.horizontal"))
    }

    @Test("The actions menu lists New Folder, New Document, Import and Sort in order, each with its symbol")
    func actionsMenuEntries() async throws {
        let rig = try await makeRig()
        let actions = BarMenu.actions("browser.actionsMenuButton", in: rig.controller)
        #expect(actions.map(\.identifier.rawValue) == Self.normalEntries.map(\.id))
        #expect(actions.map(\.title) == Self.normalEntries.map(\.title))
        for (action, expected) in zip(actions, Self.normalEntries) {
            #expect(BarMenu.isSymbol(action.image, named: expected.symbol), "symbol of \(expected.title)")
        }
    }

    @Test("The actions menu is the same in a subfolder")
    func actionsMenuInSubfolder() async throws {
        let rig = try await makeRig(folder: "Photos")
        let actions = BarMenu.actions("browser.actionsMenuButton", in: rig.controller)
        #expect(actions.map(\.identifier.rawValue) == Self.normalEntries.map(\.id))
    }

    @Test("The actions menu button is enabled with nothing selected")
    func actionsMenuEnabled() async throws {
        let rig = try await makeRig()
        #expect(BarMenu.item("browser.actionsMenuButton", in: rig.controller) != nil)
        #expect(BarMenu.isEnabled("browser.actionsMenuButton", in: rig.controller))
    }

    // MARK: - Select actions menu

    @Test("Select mode shows Cancel at the left and only the select actions menu button at the right")
    func selectModeBar() async throws {
        let rig = try await makeRig()
        await selectItems(rig, ["Beach.jpg"])
        let leading = (rig.controller.navigationItem.leftBarButtonItems ?? []).map {
            $0.accessibilityIdentifier ?? ($0.customView?.accessibilityIdentifier ?? "")
        }
        #expect(leading == ["browser.cancelSelectButton"])
        #expect(rightIDs(rig) == ["browser.selectActionsMenuButton"])
        #expect(BarMenu.item("browser.actionsMenuButton", in: rig.controller) == nil)
    }

    @Test("The select actions menu button is labelled Actions, shows line.3.horizontal and opens on tap")
    func selectActionsMenuButton() async throws {
        let rig = try await makeRig()
        await selectItems(rig, ["Beach.jpg"])
        let item = try #require(BarMenu.item("browser.selectActionsMenuButton", in: rig.controller))
        #expect(BarMenu.opensOnTap("browser.selectActionsMenuButton", in: rig.controller))
        let label = item.accessibilityLabel ?? item.customView?.accessibilityLabel
        #expect(label == "Actions")
        let image = item.image ?? (item.customView as? UIButton)?.image(for: .normal)
        #expect(BarMenu.isSymbol(image, named: "line.3.horizontal"))
    }

    @Test("The select menu lists Move, Copy, Export, Move to Vault…, Copy to Vault… and Delete in order, with symbols")
    func selectMenuEntries() async throws {
        let rig = try await makeRig()
        await selectItems(rig, ["Beach.jpg"])
        let actions = BarMenu.actions("browser.selectActionsMenuButton", in: rig.controller)
        #expect(actions.map(\.identifier.rawValue) == Self.selectEntries.map(\.id))
        #expect(actions.map(\.title) == Self.selectEntries.map(\.title))
        for (action, expected) in zip(actions, Self.selectEntries) {
            #expect(BarMenu.isSymbol(action.image, named: expected.symbol), "symbol of \(expected.title)")
        }
    }

    @Test("Delete is the only destructive entry of the select menu and is last")
    func deleteIsDestructiveAndLast() async throws {
        let rig = try await makeRig()
        await selectItems(rig, ["Beach.jpg"])
        let actions = BarMenu.actions("browser.selectActionsMenuButton", in: rig.controller)
        #expect(actions.last?.identifier.rawValue == "browser.menu.bulkDelete")
        #expect(actions.last?.attributes.contains(.destructive) == true)
        #expect(actions.dropLast().allSatisfy { !$0.attributes.contains(.destructive) })
    }

    @Test("The select menu button is disabled with nothing selected and enabled with a selection")
    func selectMenuEnabledOnlyWithSelection() async throws {
        let rig = try await makeRig()
        rig.host.tap("selectButton")
        await BrowserViewSupport.waitUntil {
            BarMenu.item("browser.selectActionsMenuButton", in: rig.controller) != nil
        }
        #expect(!BarMenu.isEnabled("browser.selectActionsMenuButton", in: rig.controller))
        rig.tapCell("Beach.jpg")
        await BrowserViewSupport.waitUntil {
            BarMenu.isEnabled("browser.selectActionsMenuButton", in: rig.controller)
        }
        #expect(BarMenu.isEnabled("browser.selectActionsMenuButton", in: rig.controller))
        rig.tapCell("Beach.jpg")
        await BrowserViewSupport.waitUntil {
            !BarMenu.isEnabled("browser.selectActionsMenuButton", in: rig.controller)
        }
        #expect(!BarMenu.isEnabled("browser.selectActionsMenuButton", in: rig.controller))
    }

    @Test("Delete from the select menu asks Delete N items? for the selection")
    func selectMenuDeleteAsks() async throws {
        let rig = try await makeRig()
        await selectItems(rig, ["Beach.jpg", "Notes.rtf", "Holiday.mov"])
        rig.chooseMenu("browser.menu.bulkDelete")
        let alert = try #require(await rig.host.alert())
        #expect(alert.title == "Delete 3 items?")
        #expect(rig.store.trashBatches.isEmpty)
    }

    @Test(
        "Move to Vault… and Copy to Vault… transfer the selected items, moving or copying",
        arguments: [true, false])
    func vaultEntriesTransferSelection(isMove: Bool) async throws {
        let rig = try await makeRig(encryptedStore: true)
        await selectItems(rig, ["Beach.jpg", "Notes.rtf"])
        rig.chooseMenu(isMove ? "browser.menu.moveToVault" : "browser.menu.copyToVault")
        await BrowserViewSupport.waitUntil { rig.host.element("vaultPicker.unencryptedRow") != nil }
        #expect(!(rig.host.topmost is UIAlertController))
        rig.host.tap("vaultPicker.unencryptedRow")
        await BrowserViewSupport.waitUntil { !rig.transfer.calls.isEmpty }
        let call = try #require(rig.transfer.calls.first)
        let expected = rig.store.allItems.filter { ["Beach.jpg", "Notes.rtf"].contains($0.name) }.map(\.id)
        #expect(Set(call.itemIDs) == Set(expected))
        #expect(call.itemIDs.count == 2)
        #expect(call.removingOriginals == isMove)
    }

    // MARK: - Long press

    @Test("In select mode a long press on a cell gives no context menu")
    func noContextMenuInSelectMode() async throws {
        let rig = try await makeRig()
        #expect(rig.menuConfiguration(for: "Beach.jpg") != nil)
        await selectItems(rig, ["Notes.rtf"])
        #expect(rig.menuConfiguration(for: "Beach.jpg") == nil)
        #expect(rig.menuConfiguration(for: "Notes.rtf") == nil)
        #expect(rig.menuConfiguration(for: "Photos") == nil)
    }

    @Test("After leaving select mode the context menu is back")
    func contextMenuReturnsAfterSelectMode() async throws {
        let rig = try await makeRig()
        await selectItems(rig, ["Notes.rtf"])
        rig.host.tap("browser.cancelSelectButton")
        await BrowserViewSupport.waitUntil { rig.menuConfiguration(for: "Beach.jpg") != nil }
        #expect(rig.menuConfiguration(for: "Beach.jpg") != nil)
    }

    @Test("In select mode a tap still toggles the cell")
    func tapStillTogglesInSelectMode() async throws {
        let rig = try await makeRig()
        await selectItems(rig, ["Beach.jpg"])
        #expect(TitleRow.shows("1 Selected", in: rig.controller))
    }

    // MARK: - Selection does not reload the grid

    private func checkmark(_ rig: Rig, _ name: String) -> UIView? {
        rig.cells.first { $0.accessibilityIdentifier == "browser.cell.\(name)" }
            .flatMap { BrowserViewHost.find("browser.cell.\(name).checkmark", in: $0) }
    }

    @Test("Toggling a cell in select mode does not redraw any cell or ask for thumbnails again")
    func selectionDoesNotReloadGrid() async throws {
        let rig = try await makeRig()
        rig.host.tap("selectButton")
        await BrowserViewSupport.settle()
        let grid = try #require(rig.grid)
        // Mark every visible cell's icon with a sentinel: a redraw (configure) would replace it.
        let sentinel = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 3)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }
        let before = rig.cells
        #expect(!before.isEmpty)
        for cell in before { cell.thumbnailView.image = sentinel }
        let requestsBefore = rig.thumbnails.requested()
        let storeCallsBefore = rig.store.calls.count
        let path = try #require(rig.indexPath("Beach.jpg"))
        let cellBefore = grid.cellForItem(at: path)

        rig.tapCell("Beach.jpg")
        rig.tapCell("Photos")
        await BrowserViewSupport.settle()

        #expect(grid.cellForItem(at: path) === cellBefore)
        for cell in rig.cells { #expect(cell.thumbnailView.image === sentinel) }
        #expect(rig.thumbnails.requested() == requestsBefore)
        #expect(rig.store.calls.count == storeCallsBefore)
        #expect(checkmark(rig, "Beach.jpg")?.isHidden == false)
        #expect(checkmark(rig, "Photos")?.isHidden == false)
        #expect(checkmark(rig, "Notes.rtf")?.isHidden == true)
        #expect(TitleRow.shows("2 Selected", in: rig.controller))
    }

    @Test("Deselecting a cell hides its checkmark without reloading the grid")
    func deselectionDoesNotReloadGrid() async throws {
        let rig = try await makeRig()
        await selectItems(rig, ["Beach.jpg"])
        let requestsBefore = rig.thumbnails.requested()
        rig.tapCell("Beach.jpg")
        await BrowserViewSupport.settle()
        #expect(checkmark(rig, "Beach.jpg")?.isHidden == true)
        #expect(rig.thumbnails.requested() == requestsBefore)
        #expect(TitleRow.shows("Select Items", in: rig.controller))
    }
}
