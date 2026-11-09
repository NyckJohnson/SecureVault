import Testing
import UIKit

@testable import KoalaTVault

/// Contract for the view (the code-writer must match it):
/// `RecentlyDeletedViewController(store: any VaultStoring, onRestore: @escaping @MainActor () -> Void)`,
/// shown in a navigation controller. Identifiers follow the journey tests: `recentlyDeleted.list` (table),
/// `recentlyDeleted.row.<name>` (cells), `recentlyDeleted.emptyStateLabel`, `recentlyDeleted.emptyTrashButton`.
@MainActor
@Suite struct RecentlyDeletedViewControllerTests {
    private struct Rig {
        let host: SettingsViewHost
        let store: MockVaultStoring
        let restored: SettingsRecorder<Void>
    }

    private func makeRig(trashing files: [String]) async throws -> Rig {
        let store = MockVaultStoring(withSampleContent: false)
        for name in files {
            let source = URL(fileURLWithPath: "/nonexistent/source")
            let item = try await store.addFile(from: source, named: name, to: store.root)
            try await store.moveToTrash(item)
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = SettingsRecorder<Void>()
        let controller = RecentlyDeletedViewController(store: store, onRestore: { restored.record(()) })
        let host = SettingsViewHost(content: UINavigationController(rootViewController: controller))
        return Rig(host: host, store: store, restored: restored)
    }

    private func row(_ name: String, _ rig: Rig) -> UIView? {
        rig.host.element("recentlyDeleted.row.\(name)") as? UIView
    }

    @Test("Each trashed item is a row with its name and Deletes in 30 days")
    func rowsShowNameAndCountdown() async throws {
        let rig = try await makeRig(trashing: ["a.txt"])
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) != nil }
        let cell = try #require(row("a.txt", rig))
        let texts = SettingsViewHost.texts(in: cell)
        #expect(texts.contains("a.txt"))
        #expect(texts.contains("Deletes in 30 days"))
    }

    @Test("The most recently deleted item is listed first")
    func newestFirst() async throws {
        let rig = try await makeRig(trashing: ["old.txt", "new.txt"])
        await SettingsTestSupport.waitUntil { self.row("old.txt", rig) != nil && self.row("new.txt", rig) != nil }
        let table = try #require(rig.host.element("recentlyDeleted.list") as? UITableView)
        let newCell = try #require(row("new.txt", rig) as? UITableViewCell)
        let oldCell = try #require(row("old.txt", rig) as? UITableViewCell)
        let newPath = try #require(table.indexPath(for: newCell))
        let oldPath = try #require(table.indexPath(for: oldCell))
        #expect(newPath.row < oldPath.row)
    }

    @Test("An empty trash shows No recently deleted files and disables Empty Trash")
    func emptyState() async throws {
        let rig = try await makeRig(trashing: [])
        await SettingsTestSupport.waitUntil { rig.host.element("recentlyDeleted.emptyStateLabel") != nil }
        let label = try #require(rig.host.element("recentlyDeleted.emptyStateLabel") as? UILabel)
        #expect(label.text == "No recently deleted files")
        #expect(label.isHidden == false)
        #expect(rig.host.isEnabled("recentlyDeleted.emptyTrashButton") == false)
    }

    @Test("A trash with items hides the empty message and enables Empty Trash")
    func nonEmptyState() async throws {
        let rig = try await makeRig(trashing: ["a.txt"])
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) != nil }
        let label = rig.host.element("recentlyDeleted.emptyStateLabel") as? UILabel
        #expect(label == nil || label?.isHidden == true)
        #expect(rig.host.isEnabled("recentlyDeleted.emptyTrashButton") == true)
    }

    @Test("Tapping a row offers Restore, Delete Permanently and Cancel")
    func rowActions() async throws {
        let rig = try await makeRig(trashing: ["a.txt"])
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) != nil }
        rig.host.selectRow("recentlyDeleted.row.a.txt", inTable: "recentlyDeleted.list")
        let sheet = try #require(await rig.host.alert())
        #expect(sheet.actionTitles.contains("Restore"))
        #expect(sheet.actionTitles.contains("Delete Permanently"))
        #expect(sheet.actionTitles.contains("Cancel"))
    }

    @Test("Restore puts the item back, removes the row and tells the browser to refresh")
    func restoreRow() async throws {
        let rig = try await makeRig(trashing: ["a.txt"])
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) != nil }
        rig.host.selectRow("recentlyDeleted.row.a.txt", inTable: "recentlyDeleted.list")
        let sheet = try #require(await rig.host.alert())
        sheet.fire("Restore")
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) == nil }
        #expect(row("a.txt", rig) == nil)
        #expect(rig.restored.values.count == 1)
        #expect(try await rig.store.trashContents().isEmpty)
    }

    @Test("Delete Permanently asks to confirm first and deletes nothing until confirmed")
    func deleteAsksFirst() async throws {
        let rig = try await makeRig(trashing: ["a.txt"])
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) != nil }
        rig.host.selectRow("recentlyDeleted.row.a.txt", inTable: "recentlyDeleted.list")
        try #require(await rig.host.alert()).fire("Delete Permanently")
        let confirm = try #require(await rig.host.alert())
        #expect(confirm.actionTitles.contains("Cancel"))
        #expect(try await rig.store.trashContents().count == 1)
    }

    @Test("Cancelling the delete confirmation keeps the item")
    func deleteCancelled() async throws {
        let rig = try await makeRig(trashing: ["a.txt"])
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) != nil }
        rig.host.selectRow("recentlyDeleted.row.a.txt", inTable: "recentlyDeleted.list")
        try #require(await rig.host.alert()).fire("Delete Permanently")
        try #require(await rig.host.alert()).fire("Cancel")
        await SettingsTestSupport.settle()
        #expect(try await rig.store.trashContents().count == 1)
    }

    @Test("Confirming the delete removes the item for good")
    func deleteConfirmed() async throws {
        let rig = try await makeRig(trashing: ["a.txt"])
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) != nil }
        rig.host.selectRow("recentlyDeleted.row.a.txt", inTable: "recentlyDeleted.list")
        let sheet = try #require(await rig.host.alert())
        sheet.fire("Delete Permanently")
        await SettingsTestSupport.waitUntil { rig.host.topmost !== sheet && rig.host.topmost is UIAlertController }
        let confirm = try #require(rig.host.topmost as? UIAlertController)
        let destructive = try #require(confirm.actions.first { $0.style == .destructive })
        destructive.fire()
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) == nil }
        #expect(try await rig.store.trashContents().isEmpty)
        #expect(rig.restored.values.isEmpty)
    }

    @Test("Empty Trash asks to confirm, and confirming empties the trash")
    func emptyTrashConfirmed() async throws {
        let rig = try await makeRig(trashing: ["a.txt", "b.txt"])
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) != nil }
        rig.host.tap("recentlyDeleted.emptyTrashButton")
        let confirm = try #require(await rig.host.alert())
        #expect(try await rig.store.trashContents().count == 2)
        confirm.fire("Empty Trash")
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) == nil && self.row("b.txt", rig) == nil }
        #expect(try await rig.store.trashContents().isEmpty)
        #expect(rig.host.isEnabled("recentlyDeleted.emptyTrashButton") == false)
    }

    @Test("Cancelling Empty Trash keeps every item")
    func emptyTrashCancelled() async throws {
        let rig = try await makeRig(trashing: ["a.txt"])
        await SettingsTestSupport.waitUntil { self.row("a.txt", rig) != nil }
        rig.host.tap("recentlyDeleted.emptyTrashButton")
        try #require(await rig.host.alert()).fire("Cancel")
        await SettingsTestSupport.settle()
        #expect(try await rig.store.trashContents().count == 1)
    }

    @Test("A store error loading the trash is shown as an error alert")
    func loadErrorShown() async throws {
        let store = MockVaultStoring(withSampleContent: false)
        store.errorToThrow = .locked
        let controller = RecentlyDeletedViewController(store: store, onRestore: {})
        let host = SettingsViewHost(content: UINavigationController(rootViewController: controller))
        let alert = await host.alert()
        #expect(alert?.title == "Error")
    }
}

/// Views of Recently Deleted's unreadable-trash prompt (spec: RecentlyDeletedViewModel, unreadable trash).
@MainActor
@Suite struct RecentlyDeletedUnreadablePromptTests {
    private static let title = "Some Deleted Items Can't Be Read"
    private static let message =
        "They were encrypted with a key this vault no longer has, so they can never be restored or opened. "
        + "Clear them now?"

    private struct Rig {
        let host: SettingsViewHost
        let store: MockVaultStoring
    }

    private func makeRig(unreadable: Bool) -> Rig {
        let store = MockVaultStoring(withSampleContent: false)
        store.unreadableTrash = unreadable
        let controller = RecentlyDeletedViewController(store: store, onRestore: {})
        let host = SettingsViewHost(content: UINavigationController(rootViewController: controller))
        return Rig(host: host, store: store)
    }

    private func clearCalls(_ rig: Rig) -> Int {
        rig.store.calls.filter { $0 == .clearUnreadableTrash }.count
    }

    @Test("Opening with unreadable trash shows the prompt with the spec's title and message")
    func promptWording() async throws {
        let rig = makeRig(unreadable: true)
        let alert = try #require(await rig.host.alert())
        #expect(alert.title == Self.title)
        #expect(alert.message == Self.message)
    }

    @Test("The prompt offers Clear (destructive) and Not Now")
    func promptActions() async throws {
        let rig = makeRig(unreadable: true)
        let alert = try #require(await rig.host.alert())
        #expect(alert.actionTitles == ["Clear", "Not Now"])
        #expect(alert.actions.first { $0.title == "Clear" }?.style == .destructive)
    }

    @Test("Clear clears the store's unreadable trash and reloads the list")
    func clearReloads() async throws {
        let rig = makeRig(unreadable: true)
        try #require(await rig.host.alert()).fire("Clear")
        await SettingsTestSupport.waitUntil { self.clearCalls(rig) == 1 }
        #expect(clearCalls(rig) == 1)
        let calls = rig.store.calls
        let clearAt = try #require(calls.firstIndex(of: .clearUnreadableTrash))
        await SettingsTestSupport.waitUntil {
            rig.store.calls.suffix(from: clearAt + 1).contains(.trashContents)
        }
        #expect(rig.store.calls.suffix(from: clearAt + 1).contains(.trashContents))
    }

    @Test("Not Now leaves the trash alone and the prompt gone")
    func notNow() async throws {
        let rig = makeRig(unreadable: true)
        try #require(await rig.host.alert()).fire("Not Now")
        #expect(await rig.host.noAlert())
        #expect(clearCalls(rig) == 0)
    }

    @Test("No prompt appears when the trash has nothing unreadable")
    func noPromptWhenReadable() async {
        let rig = makeRig(unreadable: false)
        await SettingsTestSupport.waitUntil { rig.store.calls.contains(.hasUnreadableTrash) }
        #expect(await rig.host.noAlert())
        #expect(clearCalls(rig) == 0)
    }
}
