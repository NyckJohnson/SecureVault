import Foundation
import Testing
import os

@testable import KoalaTVault

@MainActor
@Suite struct RecentlyDeletedViewModelTests {
    private static let day: TimeInterval = 24 * 60 * 60
    nonisolated private static let earlyCases: [(Double, String)] =
        [(0, "Deletes in 30 days"), (0.5, "Deletes in 30 days")]
    nonisolated private static let midCases: [(Double, String)] =
        [(1, "Deletes in 29 days"), (10, "Deletes in 20 days")]
    nonisolated private static let nearCases: [(Double, String)] =
        [(28, "Deletes in 2 days"), (29, "Deletes in 1 day")]
    nonisolated private static let overCases: [(Double, String)] =
        [(45, "Deletes in 0 days"), (400, "Deletes in 0 days")]
    nonisolated private static let lateCases: [(Double, String)] =
        [(29.9, "Deletes in 1 day"), (30, "Deletes in 0 days")]

    nonisolated private static let dayCases: [(Double, String)] =
        earlyCases + midCases + nearCases + lateCases + overCases

    private struct Rig {
        let viewModel: RecentlyDeletedViewModel
        let store: MockVaultStoring
        let alerts: MockAlertPresenting
        let restored: SettingsRecorder<Void>
    }

    /// A view model over a vault whose trash holds `files` (names ending in "/" are folders), with the
    /// clock set `daysSince` days after the last deletion.
    private func makeRig(
        trashing files: [String] = [], daysSince: Double = 0, spacedOut: Bool = false
    ) async throws -> Rig {
        let store = MockVaultStoring(withSampleContent: false)
        var lastDeleted = Date.distantPast
        for name in files {
            let item: VaultItem
            if name.hasSuffix("/") {
                item = try await store.createFolder(named: String(name.dropLast()), in: store.root)
            } else {
                let source = URL(fileURLWithPath: "/nonexistent/source")
                item = try await store.addFile(from: source, named: name, to: store.root)
            }
            try await store.moveToTrash(item)
            if spacedOut { try await Task.sleep(for: .milliseconds(10)) }
        }
        for trashed in try await store.trashContents() {
            if let deletedAt = trashed.deletedAt { lastDeleted = max(lastDeleted, deletedAt) }
        }
        if lastDeleted == .distantPast { lastDeleted = Date() }
        let clock = lastDeleted.addingTimeInterval(daysSince * Self.day)
        let alerts = MockAlertPresenting()
        let restored = SettingsRecorder<Void>()
        let viewModel = RecentlyDeletedViewModel(
            store: store, alerts: alerts, now: { clock }, folderAssetAvailable: true,
            onRestore: { restored.record(()) })
        return Rig(viewModel: viewModel, store: store, alerts: alerts, restored: restored)
    }

    // MARK: - Rows

    @Test("Each trashed item becomes a row with its name")
    func rowsShowNames() async throws {
        let rig = try await makeRig(trashing: ["Beach.jpg", "Notes.pdf"])
        await rig.viewModel.load()
        #expect(rig.viewModel.rows.map(\.name).sorted() == ["Beach.jpg", "Notes.pdf"])
    }

    @Test("Rows are ordered most recently deleted first, not by name or by listing order")
    func rowsNewestFirst() async throws {
        let rig = try await makeRig(trashing: ["B.pdf", "C.pdf", "A.pdf"], spacedOut: true)
        await rig.viewModel.load()
        #expect(rig.viewModel.rows.map(\.name) == ["A.pdf", "C.pdf", "B.pdf"])
    }

    @Test("Each row's id is its item's id, in the rows' order")
    func rowIdsMatchItems() async throws {
        let rig = try await makeRig(trashing: ["B.pdf", "C.pdf", "A.pdf"], spacedOut: true)
        await rig.viewModel.load()
        let trashIds = try await rig.store.trashContents().map(\.id)
        let rows = rig.viewModel.rows
        #expect(rows.map(\.id) == rows.map(\.item.id))
        #expect(Set(rows.map(\.id)) == Set(trashIds))
        #expect(rows.count == 3)
    }

    @Test("A row's icon follows the shared file icon mapping")
    func rowIcons() async throws {
        let rig = try await makeRig(trashing: ["Beach.jpg", "Photos/"])
        await rig.viewModel.load()
        let file = try #require(rig.viewModel.rows.first { $0.name == "Beach.jpg" })
        let folder = try #require(rig.viewModel.rows.first { $0.name == "Photos" })
        #expect(file.icon == FileIconMapping.icon(for: .image, isDirectory: false, folderAssetAvailable: true))
        #expect(folder.icon == FileIconMapping.icon(for: .other, isDirectory: true, folderAssetAvailable: true))
    }

    @Test(
        "A row says how many days remain before deletion",
        arguments: RecentlyDeletedViewModelTests.dayCases
    )
    func deletesInDays(daysSince: Double, expected: String) async throws {
        let rig = try await makeRig(trashing: ["Old.pdf"], daysSince: daysSince)
        await rig.viewModel.load()
        #expect(rig.viewModel.rows.first?.detail == expected)
    }

    @Test("The live clock returns the current time")
    func liveClock() {
        let before = Date()
        let now = RecentlyDeletedViewModel.liveNow()
        let after = Date()
        #expect(now >= before)
        #expect(now <= after)
    }

    // MARK: - Empty state

    @Test("An empty trash shows No recently deleted files and disables Empty Trash")
    func emptyState() async throws {
        let rig = try await makeRig()
        await rig.viewModel.load()
        #expect(rig.viewModel.rows.isEmpty)
        #expect(rig.viewModel.isEmpty)
        #expect(rig.viewModel.emptyMessage == "No recently deleted files")
        #expect(!rig.viewModel.canEmptyTrash)
    }

    @Test("A trash with files hides the empty state and enables Empty Trash")
    func nonEmptyState() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf"])
        await rig.viewModel.load()
        #expect(!rig.viewModel.isEmpty)
        #expect(rig.viewModel.canEmptyTrash)
    }

    // MARK: - Restore

    @Test("Restore puts the item back, drops the row and refreshes the browser")
    func restoreItem() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf", "Keep.pdf"])
        await rig.viewModel.load()
        let item = try #require(rig.viewModel.rows.first { $0.name == "Old.pdf" }?.item)
        await rig.viewModel.restore(item)
        #expect(rig.store.allItems.contains { $0.name == "Old.pdf" })
        #expect(rig.viewModel.rows.map(\.name) == ["Keep.pdf"])
        #expect(rig.restored.values.count == 1)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A failed restore shows the error, keeps the row and does not refresh the browser")
    func restoreFailure() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf"])
        await rig.viewModel.load()
        let item = try #require(rig.viewModel.rows.first?.item)
        rig.store.errorToThrow = .io("Disk error")
        await rig.viewModel.restore(item)
        #expect(rig.alerts.alerts == [.error(VaultStoreError.io("Disk error").localizedDescription)])
        #expect(rig.restored.values.isEmpty)
        #expect(rig.viewModel.rows.count == 1)
    }

    // MARK: - Delete Permanently

    @Test("Delete Permanently asks to confirm first and deletes nothing yet")
    func deleteAsksFirst() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf"])
        await rig.viewModel.load()
        let item = try #require(rig.viewModel.rows.first?.item)
        rig.viewModel.requestDelete(item)
        #expect(rig.viewModel.confirmation == .deletePermanently(item))
        let trash = try await rig.store.trashContents()
        #expect(trash.count == 1)
        #expect(!rig.store.calls.contains(.deletePermanently(item.id)))
    }

    @Test("Confirming Delete Permanently deletes the item and drops the row")
    func deleteConfirmed() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf", "Keep.pdf"])
        await rig.viewModel.load()
        let item = try #require(rig.viewModel.rows.first { $0.name == "Old.pdf" }?.item)
        rig.viewModel.requestDelete(item)
        await rig.viewModel.confirmPending()
        #expect(rig.store.calls.contains(.deletePermanently(item.id)))
        #expect(rig.viewModel.rows.map(\.name) == ["Keep.pdf"])
        #expect(rig.viewModel.confirmation == nil)
    }

    @Test("Cancelling Delete Permanently keeps the item")
    func deleteCancelled() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf"])
        await rig.viewModel.load()
        let item = try #require(rig.viewModel.rows.first?.item)
        rig.viewModel.requestDelete(item)
        rig.viewModel.cancelConfirmation()
        #expect(rig.viewModel.confirmation == nil)
        await rig.viewModel.confirmPending()
        #expect(!rig.store.calls.contains(.deletePermanently(item.id)))
        #expect(rig.viewModel.rows.count == 1)
    }

    @Test("A failed Delete Permanently shows the error and keeps the row")
    func deleteFailure() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf"])
        await rig.viewModel.load()
        let item = try #require(rig.viewModel.rows.first?.item)
        rig.viewModel.requestDelete(item)
        rig.store.errorToThrow = .io("Disk error")
        await rig.viewModel.confirmPending()
        #expect(rig.alerts.alerts == [.error(VaultStoreError.io("Disk error").localizedDescription)])
        #expect(rig.viewModel.rows.count == 1)
    }

    // MARK: - Empty Trash

    @Test("Empty Trash asks to confirm first and empties nothing yet")
    func emptyTrashAsksFirst() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf"])
        await rig.viewModel.load()
        rig.viewModel.requestEmptyTrash()
        #expect(rig.viewModel.confirmation == .emptyTrash)
        #expect(!rig.store.calls.contains(.emptyTrash))
    }

    @Test("Confirming Empty Trash empties the trash and shows the empty state")
    func emptyTrashConfirmed() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf", "Keep.pdf"])
        await rig.viewModel.load()
        rig.viewModel.requestEmptyTrash()
        await rig.viewModel.confirmPending()
        #expect(rig.store.calls.contains(.emptyTrash))
        #expect(rig.viewModel.rows.isEmpty)
        #expect(rig.viewModel.isEmpty)
        #expect(!rig.viewModel.canEmptyTrash)
        #expect(rig.viewModel.confirmation == nil)
    }

    @Test("Cancelling Empty Trash keeps every item")
    func emptyTrashCancelled() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf"])
        await rig.viewModel.load()
        rig.viewModel.requestEmptyTrash()
        rig.viewModel.cancelConfirmation()
        await rig.viewModel.confirmPending()
        #expect(!rig.store.calls.contains(.emptyTrash))
        #expect(rig.viewModel.rows.count == 1)
    }

    // MARK: - List updates (large trash)

    /// A view model over a gated store whose trash holds `files`; the gate is open until `hold()`.
    private func makeGatedRig(trashing files: [String]) async throws -> (
        viewModel: RecentlyDeletedViewModel, gated: GatedTrashStore, store: MockVaultStoring,
        alerts: MockAlertPresenting, restored: SettingsRecorder<Void>
    ) {
        let store = MockVaultStoring(withSampleContent: false)
        for name in files {
            let source = URL(fileURLWithPath: "/nonexistent/source")
            let item = try await store.addFile(from: source, named: name, to: store.root)
            try await store.moveToTrash(item)
        }
        let gated = GatedTrashStore(store)
        let alerts = MockAlertPresenting()
        let restored = SettingsRecorder<Void>()
        let viewModel = RecentlyDeletedViewModel(
            store: gated, alerts: alerts, folderAssetAvailable: true, onRestore: { restored.record(()) })
        await viewModel.load()
        return (viewModel, gated, store, alerts, restored)
    }

    @Test("A successful Restore removes the row before the list is read again, then the reload replaces rows")
    func restoreRemovesRowAtOnce() async throws {
        let rig = try await makeGatedRig(trashing: ["Old.pdf", "Keep.pdf"])
        let item = try #require(rig.viewModel.rows.first { $0.name == "Old.pdf" }?.item)
        rig.gated.hold()
        let viewModel = rig.viewModel
        let action = Task { await viewModel.restore(item) }
        await rig.gated.waitUntilReloadHeld()
        #expect(rig.viewModel.rows.map(\.name) == ["Keep.pdf"])
        // Make the reload differ from the local update, to show that its result replaces the rows.
        let extra = try await rig.store.addFile(
            from: URL(fileURLWithPath: "/nonexistent/source"), named: "Late.pdf", to: rig.store.root)
        try await rig.store.moveToTrash(extra)
        rig.gated.release()
        await action.value
        #expect(rig.viewModel.rows.map(\.name).sorted() == ["Keep.pdf", "Late.pdf"])
        #expect(rig.restored.values.count == 1)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A successful Delete Permanently removes the row before the list is read again")
    func deleteRemovesRowAtOnce() async throws {
        let rig = try await makeGatedRig(trashing: ["Old.pdf", "Keep.pdf"])
        let item = try #require(rig.viewModel.rows.first { $0.name == "Old.pdf" }?.item)
        rig.viewModel.requestDelete(item)
        rig.gated.hold()
        let viewModel = rig.viewModel
        let action = Task { await viewModel.confirmPending() }
        await rig.gated.waitUntilReloadHeld()
        #expect(rig.viewModel.rows.map(\.name) == ["Keep.pdf"])
        rig.gated.release()
        await action.value
        #expect(rig.viewModel.rows.map(\.name) == ["Keep.pdf"])
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A successful Empty Trash empties the rows before the list is read again")
    func emptyTrashEmptiesRowsAtOnce() async throws {
        let rig = try await makeGatedRig(trashing: ["Old.pdf", "Keep.pdf"])
        rig.viewModel.requestEmptyTrash()
        rig.gated.hold()
        let viewModel = rig.viewModel
        let action = Task { await viewModel.confirmPending() }
        await rig.gated.waitUntilReloadHeld()
        #expect(rig.viewModel.rows.isEmpty)
        rig.gated.release()
        await action.value
        #expect(rig.viewModel.rows.isEmpty)
    }

    @Test("Restore of an item that is already gone removes its row and shows no alert")
    func restoreNotFoundRemovesRowSilently() async throws {
        let rig = try await makeRig(trashing: ["Gone.pdf", "Keep.pdf"])
        await rig.viewModel.load()
        let item = try #require(rig.viewModel.rows.first { $0.name == "Gone.pdf" }?.item)
        try await rig.store.deletePermanently(item)
        await rig.viewModel.restore(item)
        #expect(rig.viewModel.rows.map(\.name) == ["Keep.pdf"])
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Delete Permanently of an item that is already gone removes its row and shows no alert")
    func deleteNotFoundRemovesRowSilently() async throws {
        let rig = try await makeRig(trashing: ["Gone.pdf", "Keep.pdf"])
        await rig.viewModel.load()
        let item = try #require(rig.viewModel.rows.first { $0.name == "Gone.pdf" }?.item)
        try await rig.store.deletePermanently(item)
        rig.viewModel.requestDelete(item)
        await rig.viewModel.confirmPending()
        #expect(rig.viewModel.rows.map(\.name) == ["Keep.pdf"])
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A listing error on a reload keeps the rows already shown and shows the error")
    func reloadErrorKeepsRows() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf", "Keep.pdf"])
        await rig.viewModel.load()
        rig.store.errorToThrow = .locked
        await rig.viewModel.load()
        #expect(rig.viewModel.rows.map(\.name).sorted() == ["Keep.pdf", "Old.pdf"])
        #expect(rig.alerts.alerts == [.error(VaultStoreError.locked.localizedDescription)])
        #expect(!rig.viewModel.isEmpty)
        #expect(rig.viewModel.canEmptyTrash)
    }

    @Test("A listing error on the first load does not show the empty state and keeps Empty Trash disabled")
    func firstLoadErrorIsNotEmpty() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf"])
        rig.store.errorToThrow = .locked
        await rig.viewModel.load()
        #expect(rig.alerts.alerts == [.error(VaultStoreError.locked.localizedDescription)])
        #expect(!rig.viewModel.isEmpty)
        #expect(!rig.viewModel.canEmptyTrash)
    }

    @Test("The empty state shows after a later successful empty listing following an error")
    func emptyStateAfterSuccessfulEmptyListing() async throws {
        let rig = try await makeRig()
        rig.store.errorToThrow = .locked
        await rig.viewModel.load()
        rig.store.errorToThrow = nil
        await rig.viewModel.load()
        #expect(rig.viewModel.isEmpty)
        #expect(!rig.viewModel.canEmptyTrash)
    }

    // MARK: - Errors

    @Test("A failure loading the trash shows the error")
    func loadFailure() async throws {
        let rig = try await makeRig(trashing: ["Old.pdf"])
        rig.store.errorToThrow = .locked
        await rig.viewModel.load()
        #expect(rig.alerts.alerts == [.error(VaultStoreError.locked.localizedDescription)])
        #expect(rig.viewModel.rows.isEmpty)
    }
}

@MainActor
@Suite struct RecentlyDeletedUnreadableTrashTests {
    private static let title = "Some Deleted Items Can't Be Read"
    private static let message =
        "They were encrypted with a key this vault no longer has, so they can never be restored or opened. "
        + "Clear them now?"

    private struct Rig {
        let viewModel: RecentlyDeletedViewModel
        let store: MockVaultStoring
        let alerts: MockAlertPresenting
    }

    private func makeRig(unreadable: Bool) -> Rig {
        let store = MockVaultStoring(withSampleContent: false)
        store.unreadableTrash = unreadable
        let alerts = MockAlertPresenting()
        let viewModel = RecentlyDeletedViewModel(store: store, alerts: alerts, onRestore: {})
        return Rig(viewModel: viewModel, store: store, alerts: alerts)
    }

    private func count(_ call: MockVaultStoring.Call, in rig: Rig) -> Int {
        rig.store.calls.filter { $0 == call }.count
    }

    // Assumed API: `isAskingToClearUnreadableTrash` (published Bool), `unreadableTrashPromptTitle` and
    // `unreadableTrashPromptMessage` (Strings), `clearUnreadableTrash() async`, `declineClearingUnreadableTrash()`.

    @Test("Loading with unreadable trash asks whether to clear it, with the spec's wording")
    func promptShown() async {
        let rig = makeRig(unreadable: true)
        await rig.viewModel.load()
        #expect(rig.viewModel.isAskingToClearUnreadableTrash)
        #expect(rig.viewModel.unreadableTrashPromptTitle == Self.title)
        #expect(rig.viewModel.unreadableTrashPromptMessage == Self.message)
    }

    @Test("Loading with no unreadable trash asks nothing")
    func noPrompt() async {
        let rig = makeRig(unreadable: false)
        await rig.viewModel.load()
        #expect(!rig.viewModel.isAskingToClearUnreadableTrash)
        #expect(count(.hasUnreadableTrash, in: rig) == 1)
    }

    @Test("Clear clears the store's unreadable trash and then reloads the list")
    func clearThenReload() async throws {
        let rig = makeRig(unreadable: true)
        await rig.viewModel.load()
        await rig.viewModel.clearUnreadableTrash()
        let calls = rig.store.calls
        let clearAt = try #require(calls.firstIndex(of: .clearUnreadableTrash))
        #expect(calls[(clearAt + 1)...].contains(.trashContents))
        #expect(!rig.viewModel.isAskingToClearUnreadableTrash)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A failure while clearing is shown")
    func clearErrorShown() async {
        let rig = makeRig(unreadable: true)
        await rig.viewModel.load()
        rig.store.errorToThrow = .io("The disk is full.")
        await rig.viewModel.clearUnreadableTrash()
        #expect(rig.alerts.alerts.contains(.error("The disk is full.")))
        #expect(!rig.viewModel.isAskingToClearUnreadableTrash)
    }

    @Test("Not Now changes nothing in the store and closes the prompt")
    func notNow() async {
        let rig = makeRig(unreadable: true)
        await rig.viewModel.load()
        rig.viewModel.declineClearingUnreadableTrash()
        #expect(!rig.viewModel.isAskingToClearUnreadableTrash)
        #expect(count(.clearUnreadableTrash, in: rig) == 0)
        #expect(rig.store.unreadableTrash)
    }

    @Test("Not Now leaves an unreadable trash index's error showing")
    func notNowKeepsIndexError() async {
        let rig = makeRig(unreadable: true)
        rig.store.errorToThrow = .indexUnreadable(folder: ".trash")
        await rig.viewModel.load()
        #expect(rig.alerts.alerts.count == 1)
        rig.viewModel.declineClearingUnreadableTrash()
        #expect(rig.alerts.alerts.count == 1)
        #expect(rig.viewModel.rows.isEmpty)
    }

    @Test("A second load in the same opening does not ask again")
    func askedOncePerOpening() async {
        let rig = makeRig(unreadable: true)
        await rig.viewModel.load()
        rig.viewModel.declineClearingUnreadableTrash()
        await rig.viewModel.load()
        #expect(!rig.viewModel.isAskingToClearUnreadableTrash)
        #expect(count(.hasUnreadableTrash, in: rig) == 1)
    }

    @Test("A new screen asks again")
    func newOpeningAsksAgain() async {
        let rig = makeRig(unreadable: true)
        await rig.viewModel.load()
        rig.viewModel.declineClearingUnreadableTrash()
        let reopened = RecentlyDeletedViewModel(store: rig.store, alerts: rig.alerts, onRestore: {})
        await reopened.load()
        #expect(reopened.isAskingToClearUnreadableTrash)
    }
}

/// Forwards every call to `base`; while held, `trashContents()` waits (after reading nothing) until released.
private final class GatedTrashStore: VaultStoring {
    private struct Gate {
        var held = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let base: MockVaultStoring
    private let gate = OSAllocatedUnfairLock(initialState: Gate())

    init(_ base: MockVaultStoring) { self.base = base }

    func hold() { gate.withLock { $0.held = true } }

    func release() {
        let waiting = gate.withLock { gate in
            gate.held = false
            defer { gate.waiting = [] }
            return gate.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Returns once a `trashContents()` call is waiting at the gate.
    func waitUntilReloadHeld() async {
        for _ in 0..<10_000 {
            if gate.withLock({ !$0.waiting.isEmpty }) { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func trashContents() async throws -> [VaultItem] {
        await withCheckedContinuation { continuation in
            let resumeNow = gate.withLock { gate -> Bool in
                if gate.held {
                    gate.waiting.append(continuation)
                    return false
                }
                return true
            }
            if resumeNow { continuation.resume() }
        }
        return try await base.trashContents()
    }

    var root: VaultDirectory { base.root }
    var isEncrypted: Bool { base.isEncrypted }
    func contents(of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection)
        async throws -> [VaultItem]
    { try await base.contents(of: directory, sortedBy: option, direction) }
    func open(_ item: VaultItem) async throws -> URL { try await base.open(item) }
    func write(_ data: Data, to item: VaultItem) async throws { try await base.write(data, to: item) }
    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await base.createFolder(named: name, in: directory)
    }
    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await base.createDocument(named: name, in: directory)
    }
    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem {
        try await base.addFile(from: source, named: name, to: directory)
    }
    func addFiles(_ files: [VaultFileToAdd], to directory: VaultDirectory) async throws -> [VaultItem] {
        try await base.addFiles(files, to: directory)
    }
    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem? {
        try await base.findItem(named: name, in: directory)
    }
    func move(_ item: VaultItem, to directory: VaultDirectory) async throws {
        try await base.move(item, to: directory)
    }
    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem {
        try await base.copy(item, to: directory)
    }
    func rename(_ item: VaultItem, to name: String) async throws -> VaultItem {
        try await base.rename(item, to: name)
    }
    func moveToTrash(_ item: VaultItem) async throws { try await base.moveToTrash(item) }
    func moveToTrash(_ items: [VaultItem]) async -> [VaultItem.ID: VaultStoreError] {
        await base.moveToTrash(items)
    }
    func remove(_ item: VaultItem) async throws { try await base.remove(item) }
    func restore(_ trashed: VaultItem) async throws -> VaultItem { try await base.restore(trashed) }
    func deletePermanently(_ trashed: VaultItem) async throws { try await base.deletePermanently(trashed) }
    func emptyTrash() async { await base.emptyTrash() }
    func purgeExpiredTrash(now: Date) async throws -> Int { try await base.purgeExpiredTrash(now: now) }
    func hasUnreadableTrash() async -> Bool { await base.hasUnreadableTrash() }
    func clearUnreadableTrash() async throws { try await base.clearUnreadableTrash() }
    func countFiles() async throws -> Int { try await base.countFiles() }
    func itemsToEncrypt() async throws -> [VaultItem] { try await base.itemsToEncrypt() }
    func migrateToEncrypted(_ item: VaultItem) async throws { try await base.migrateToEncrypted(item) }
    func finishEncryption() async throws { try await base.finishEncryption() }
    func hasUnencryptedFiles() async throws -> Bool { try await base.hasUnencryptedFiles() }
    func keyMatchesVault() async -> Bool { await base.keyMatchesVault() }
    func sweepOrphans() async { await base.sweepOrphans() }
    func makeTempDirectory() throws -> URL { try base.makeTempDirectory() }
    func removeTemporary(_ url: URL) { base.removeTemporary(url) }
    func removeAllTemporaryFiles() { base.removeAllTemporaryFiles() }
}
