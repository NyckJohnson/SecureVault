import Testing
import UIKit

@testable import KoalaTVault

/// Seam assumed: `FolderPickerViewController(store:preferences:excluding:directory:onChoose:onCancel:)`, shown in a
/// navigation controller, with a `UITableView` of the subfolders (folder name as a label in each row), bar
/// buttons `folderPickerMoveHere` and `folderPickerCancel`, and a pushed deeper picker with the same callbacks
/// when a row is selected.
@MainActor
@Suite struct FolderPickerViewControllerTests {
    private final class Results {
        var chosen: [VaultDirectory] = []
        var cancelled = 0
    }

    private struct Rig {
        let host: BrowserViewHost
        let store: MockVaultStoring
        let results: Results
    }

    private func makeRig(excluding names: [String] = [], failing: Bool = false) -> Rig {
        let store = MockVaultStoring()
        let excluded = store.allItems.filter { names.contains($0.name) }
        let results = Results()
        if failing { store.errorToThrow = .notFound }
        let picker = FolderPickerViewController(
            store: store, preferences: MockPreferencesStoring(), excluding: excluded, directory: nil,
            onChoose: { results.chosen.append($0) }, onCancel: { results.cancelled += 1 })
        let host = BrowserViewHost(content: UINavigationController(rootViewController: picker))
        return Rig(host: host, store: store, results: results)
    }

    private func table(_ rig: Rig) -> UITableView? {
        func search(_ view: UIView) -> UITableView? {
            if let table = view as? UITableView { return table }
            for subview in view.subviews { if let found = search(subview) { return found } }
            return nil
        }
        guard let top = rig.host.navigation?.topViewController else { return nil }
        return search(top.view)
    }

    private func rowNames(_ rig: Rig) -> [String] {
        guard let table = table(rig), table.numberOfSections > 0 else { return [] }
        return (0..<table.numberOfRows(inSection: 0)).compactMap { row in
            let cell = table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: row, section: 0))
            return cell.flatMap { BrowserViewHost.texts(in: $0).first }
                ?? (cell?.contentConfiguration as? UIListContentConfiguration)?.text
                ?? cell?.textLabel?.text
        }
    }

    @Test("The picker starts at the root and lists its folders in the saved sort")
    func listsRootFolders() async throws {
        let rig = makeRig()
        await BrowserViewSupport.waitUntil { rowNames(rig).count == 2 }
        #expect(rowNames(rig) == ["Documents", "Photos"])
    }

    @Test("The items being moved are left out of the list")
    func excludesMovedFolders() async throws {
        let rig = makeRig(excluding: ["Photos"])
        await BrowserViewSupport.waitUntil { !rowNames(rig).isEmpty }
        #expect(rowNames(rig) == ["Documents"])
    }

    @Test("Move Here and Cancel have their identifiers")
    func identifiers() async throws {
        let rig = makeRig()
        #expect(rig.host.element("folderPickerMoveHere") != nil)
        #expect(rig.host.element("folderPickerCancel") != nil)
    }

    @Test("Move Here returns the folder the picker shows")
    func moveHereReturnsCurrentFolder() async throws {
        let rig = makeRig()
        rig.host.tap("folderPickerMoveHere")
        #expect(rig.results.chosen == [rig.store.root])
        #expect(rig.results.cancelled == 0)
    }

    @Test("Selecting a folder row opens that folder, and Move Here there returns it")
    func drillDownThenMoveHere() async throws {
        let rig = makeRig()
        await BrowserViewSupport.waitUntil { rowNames(rig).count == 2 }
        let index = try #require(rowNames(rig).firstIndex(of: "Photos"))
        let tableView = try #require(table(rig))
        tableView.delegate?.tableView?(tableView, didSelectRowAt: IndexPath(row: index, section: 0))
        await BrowserViewSupport.waitUntil { (rig.host.navigation?.viewControllers.count ?? 0) == 2 }
        #expect(rig.host.navigation?.viewControllers.count == 2)
        rig.host.tap("folderPickerMoveHere")
        let photos = try #require(
            rig.store.allItems.first { $0.name == "Photos" && $0.isDirectory }?.asDirectory)
        #expect(rig.results.chosen == [photos])
    }

    @Test("Cancel reports the cancellation and chooses nothing")
    func cancelReports() async throws {
        let rig = makeRig()
        rig.host.tap("folderPickerCancel")
        #expect(rig.results.cancelled == 1)
        #expect(rig.results.chosen.isEmpty)
    }

    @Test("A load error is shown as an alert")
    func loadErrorShown() async throws {
        let rig = makeRig(failing: true)
        let alert = await rig.host.alert()
        #expect(alert?.message == VaultStoreError.notFound.localizedDescription)
    }
}
