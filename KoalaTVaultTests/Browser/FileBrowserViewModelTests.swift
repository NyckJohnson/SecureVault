import Foundation
import Testing

@testable import KoalaTVault

// API under test (chosen by the test-writer; the code-writer implements it):
//
// @MainActor final class FileBrowserViewModel {
//     init(directory: VaultDirectory, store: VaultStoring, preferences: PreferencesStoring,
//          exporter: VaultExporting, alerts: AlertPresenting)
//     enum Route: Equatable { case folder(VaultDirectory), editor(VaultItem),
//                             viewer(items: [VaultItem], startingAt: Int), settings }
//     enum ContextAction: Equatable { case export, move, copy, rename, delete }
//     struct Confirmation: Equatable { var title: String; var message: String }
//     var onRoute: (Route) -> Void                       // settable, default no-op
//     var onShare: (ExportBundle) -> Void                // settable, default no-op
//     var onPresentPicker: (_ moving: [VaultItem]) -> Void // settable, default no-op
//     private(set) var items: [VaultItem]
//     var emptyStateMessage: String?                     // "No files yet" once loaded and empty
//     var showsSettingsButton: Bool                      // directory == store.root
//     var title: String                                  // directory.name, or select-mode title
//     private(set) var isSelecting: Bool; var selectedItems: [VaultItem]
//     func load() async; func selectSort(_ option: SortOption) async
//     func open(_ item: VaultItem); func openSettings()
//     func createFolder(named:) async; func createDocument(named:) async
//     func toggleSelectMode(); func toggleSelection(of:); func cancelSelection()
//     func deleteConfirmation(for: [VaultItem]) -> Confirmation
//     func delete(_:) async; func copy(_:) async; func export(_:) async
//     func beginMove(_ items: [VaultItem]); func pickerChose(_ destination: VaultDirectory) async
//     func pickerCancelled()
//     func contextActions(for item: VaultItem) -> [ContextAction]
//     func renamePrefill(for item: VaultItem) -> String; func rename(_:to:) async
//     func canDrop(onto target: VaultItem) -> Bool
//     func drop(_ dragged: VaultItem?, onto target: VaultItem) async   // nil = not from this app
//     func canDragOut(_ item: VaultItem?) -> Bool                      // nil = unknown drag item
//     func restoreCompleted() async; func importCompleted() async
//     func editorClosed() async; func vaultUnlocked() async
// }

@MainActor
@Suite struct FileBrowserViewModelTests: FileBrowserTestSupport {
    // MARK: - Load

    @Test("Load lists the folder's items sorted with the saved sort")
    func loadListsSortedItems() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        #expect(
            rig.viewModel.items.map(\.name)
                == ["Documents", "Photos", "Beach.jpg", "Holiday.mov", "Notes.rtf", "Tax Return 2025.pdf"])
        #expect(rig.store.calls.contains(.contents(directory: "", .name, .ascending)))
    }

    @Test("Load uses the saved sort option and direction")
    func loadUsesSavedSort() async throws {
        let rig = try makeRig()
        rig.preferences.sortOption = .dateModified
        rig.preferences.sortDirection = .descending
        await rig.viewModel.load()
        #expect(rig.store.calls.last == .contents(directory: "", .dateModified, .descending))
    }

    @Test("Load inside a folder lists only that folder's items")
    func loadInsideFolder() async throws {
        let rig = try makeRig(inFolder: "Photos")
        await rig.viewModel.load()
        #expect(rig.viewModel.items.map(\.name) == ["Birthday.mp4", "Sunset.heic"])
    }

    @Test("A load error is shown to the user once")
    func loadErrorShownOnce() async throws {
        let rig = try makeRig()
        rig.store.errorToThrow = .io("boom")
        await rig.viewModel.load()
        #expect(rig.alerts.alerts == [.error("boom")])
    }

    @Test(
        "A failed load after a good one does not keep showing the old items as current without an alert"
    )
    func loadErrorAfterGoodLoadStillAlerts() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        rig.store.errorToThrow = .indexUnreadable(folder: "")
        await rig.viewModel.load()
        #expect(errorMessages(rig.alerts).count == 1)
    }

    @Test("A successful load shows no alert")
    func loadSuccessShowsNoAlert() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("An empty folder shows the No files yet message")
    func emptyFolderShowsMessage() async throws {
        let rig = try makeRig(withSampleContent: false)
        await rig.viewModel.load()
        #expect(rig.viewModel.items.isEmpty)
        #expect(rig.viewModel.emptyStateMessage == "No files yet")
    }

    @Test("A folder with items shows no empty message")
    func nonEmptyFolderHasNoMessage() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        #expect(rig.viewModel.emptyStateMessage == nil)
    }

    @Test("The settings button shows at the root only")
    func settingsButtonOnlyAtRoot() async throws {
        let root = try makeRig()
        let nested = try makeRig(inFolder: "Photos")
        #expect(root.viewModel.showsSettingsButton)
        #expect(!nested.viewModel.showsSettingsButton)
    }

    @Test("Opening settings routes to settings")
    func openSettingsRoutes() async throws {
        let rig = try makeRig()
        rig.viewModel.openSettings()
        #expect(rig.recorder.routes == [.settings])
    }

    // MARK: - Sort

    @Test("Choosing the current sort option flips its direction")
    func sortSameOptionFlipsDirection() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        await rig.viewModel.selectSort(.name)
        #expect(rig.preferences.sortOption == .name)
        #expect(rig.preferences.sortDirection == .descending)
        await rig.viewModel.selectSort(.name)
        #expect(rig.preferences.sortDirection == .ascending)
    }

    @Test("Choosing another sort option sorts ascending")
    func sortOtherOptionIsAscending() async throws {
        let rig = try makeRig()
        rig.preferences.sortDirection = .descending
        await rig.viewModel.load()
        await rig.viewModel.selectSort(.type)
        #expect(rig.preferences.sortOption == .type)
        #expect(rig.preferences.sortDirection == .ascending)
    }

    @Test("Choosing a sort saves it in Preferences and reloads with it")
    func sortSavedAndReloaded() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        await rig.viewModel.selectSort(.dateModified)
        #expect(rig.preferences.writes.contains(.sortOption(.dateModified)))
        #expect(rig.store.calls.last == .contents(directory: "", .dateModified, .ascending))
    }

    // MARK: - Open

    @Test("Opening a folder routes to a browser on that folder")
    func openFolder() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let photos = try item("Photos", in: rig.store)
        rig.viewModel.open(photos)
        #expect(rig.recorder.routes == [.folder(try #require(photos.asDirectory))])
    }

    @Test("Opening an rtf file routes to the editor")
    func openRTF() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let notes = try item("Notes.rtf", in: rig.store)
        rig.viewModel.open(notes)
        #expect(rig.recorder.routes == [.editor(notes)])
    }

    @Test(
        "Opening another file routes to the viewer with the folder's files starting at the tapped one")
    func openFileRoutesToViewer() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let holiday = try item("Holiday.mov", in: rig.store)
        rig.viewModel.open(holiday)
        let names = ["Beach.jpg", "Holiday.mov", "Notes.rtf", "Tax Return 2025.pdf"]
        let files = try names.map { try item($0, in: rig.store) }
        #expect(rig.recorder.routes == [.viewer(items: files, startingAt: 1)])
    }

    @Test("The viewer's item list leaves out folders")
    func viewerExcludesFolders() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        rig.viewModel.open(try item("Beach.jpg", in: rig.store))
        guard case .viewer(let items, let index)? = rig.recorder.routes.first else {
            Issue.record("expected a viewer route")
            return
        }
        #expect(items.allSatisfy { !$0.isDirectory })
        #expect(index == 0)
    }

    // MARK: - New Folder / New Document

    @Test("New Folder trims the name and creates it in the current folder")
    func newFolderTrims() async throws {
        let rig = try makeRig()
        await rig.viewModel.createFolder(named: "  Taxes \n")
        #expect(rig.store.calls.contains(.createFolder("Taxes", parent: "")))
    }

    @Test("New Folder reloads so the folder appears")
    func newFolderReloads() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        await rig.viewModel.createFolder(named: "Taxes")
        #expect(rig.viewModel.items.map(\.name).contains("Taxes"))
    }

    @Test("New Folder with an empty or blank name does nothing", arguments: ["", "   ", "\n\t "])
    func newFolderEmptyIgnored(name: String) async throws {
        let rig = try makeRig()
        await rig.viewModel.createFolder(named: name)
        #expect(!rig.store.calls.contains { if case .createFolder = $0 { true } else { false } })
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("New Document trims the name, creates it and opens the editor on it")
    func newDocumentOpensEditor() async throws {
        let rig = try makeRig()
        await rig.viewModel.createDocument(named: " Draft ")
        #expect(rig.store.calls.contains(.createDocument("Draft", parent: "")))
        guard case .editor(let created)? = rig.recorder.routes.last else {
            Issue.record("expected an editor route")
            return
        }
        #expect(created.name == "Draft.rtf")
    }

    @Test("New Document with an empty or blank name does nothing", arguments: ["", "  "])
    func newDocumentEmptyIgnored(name: String) async throws {
        let rig = try makeRig()
        await rig.viewModel.createDocument(named: name)
        #expect(!rig.store.calls.contains { if case .createDocument = $0 { true } else { false } })
        #expect(rig.recorder.routes.isEmpty)
    }

    @Test("A New Folder name containing a slash shows the store's error")
    func newFolderSlashShowsError() async throws {
        let rig = try makeRig()
        await rig.viewModel.createFolder(named: "a/b")
        let messages = errorMessages(rig.alerts)
        #expect(messages.count == 1)
        #expect(messages.first?.contains("Names can't contain /") == true)
    }

    @Test("A New Document name containing a slash shows the error and opens no editor")
    func newDocumentSlashShowsError() async throws {
        let rig = try makeRig()
        await rig.viewModel.createDocument(named: "a/b")
        #expect(errorMessages(rig.alerts).first?.contains("Names can't contain /") == true)
        #expect(rig.recorder.routes.isEmpty)
    }

    // MARK: - Select mode

    @Test("Select mode starts off with the folder's name as title")
    func titleOutsideSelectMode() async throws {
        let rig = try makeRig()
        #expect(!rig.viewModel.isSelecting)
        #expect(rig.viewModel.title == "KoalaTVault")
    }

    @Test("Select mode with nothing chosen is titled Select Items")
    func titleSelectItems() async throws {
        let rig = try makeRig()
        rig.viewModel.toggleSelectMode()
        #expect(rig.viewModel.isSelecting)
        #expect(rig.viewModel.title == "Select Items")
    }

    @Test("Select mode titles the count as N Selected")
    func titleCountSelected() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        rig.viewModel.toggleSelectMode()
        rig.viewModel.toggleSelection(of: try item("Beach.jpg", in: rig.store))
        #expect(rig.viewModel.title == "1 Selected")
        rig.viewModel.toggleSelection(of: try item("Notes.rtf", in: rig.store))
        #expect(rig.viewModel.title == "2 Selected")
        #expect(rig.viewModel.selectedItems.map(\.name) == ["Beach.jpg", "Notes.rtf"])
    }

    @Test("Selecting an item again deselects it")
    func toggleSelectionTwice() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let beach = try item("Beach.jpg", in: rig.store)
        rig.viewModel.toggleSelectMode()
        rig.viewModel.toggleSelection(of: beach)
        rig.viewModel.toggleSelection(of: beach)
        #expect(rig.viewModel.selectedItems.isEmpty)
        #expect(rig.viewModel.title == "Select Items")
    }

    @Test("Cancel clears the selection and leaves select mode")
    func cancelClearsSelection() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        rig.viewModel.toggleSelectMode()
        rig.viewModel.toggleSelection(of: try item("Beach.jpg", in: rig.store))
        rig.viewModel.cancelSelection()
        #expect(!rig.viewModel.isSelecting)
        #expect(rig.viewModel.selectedItems.isEmpty)
        #expect(rig.viewModel.title == "KoalaTVault")
    }

    @Test("Toggling select mode off clears the selection")
    func toggleOffClearsSelection() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        rig.viewModel.toggleSelectMode()
        rig.viewModel.toggleSelection(of: try item("Beach.jpg", in: rig.store))
        rig.viewModel.toggleSelectMode()
        #expect(!rig.viewModel.isSelecting)
        #expect(rig.viewModel.selectedItems.isEmpty)
    }

    // MARK: - Context menu

    @Test(
        "The context menu offers Export, Move, Copy, Rename and Delete",
        arguments: ["Beach.jpg", "Photos"])
    func contextActions(name: String) async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let target = try item(name, in: rig.store)
        #expect(rig.viewModel.contextActions(for: target) == [.export, .move, .copy, .rename, .delete])
    }

    @Test("Rename is prefilled with the item's current name")
    func renamePrefilled() async throws {
        let rig = try makeRig()
        #expect(rig.viewModel.renamePrefill(for: try item("Beach.jpg", in: rig.store)) == "Beach.jpg")
    }

    @Test("Rename renames through the store and reloads")
    func renameThroughStore() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        await rig.viewModel.rename(try item("Beach.jpg", in: rig.store), to: "Shore.jpg")
        #expect(rig.store.calls.contains(.rename("Beach.jpg", newName: "Shore.jpg")))
        #expect(rig.viewModel.items.map(\.name).contains("Shore.jpg"))
    }

    @Test("Renaming to a name with a slash shows the store's error")
    func renameSlashShowsError() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        await rig.viewModel.rename(try item("Beach.jpg", in: rig.store), to: "a/b")
        #expect(errorMessages(rig.alerts).first?.contains("Names can't contain /") == true)
    }

    @Test("The single-item delete confirmation mentions Recently Deleted")
    func deleteConfirmationMentionsRecentlyDeleted() async throws {
        let rig = try makeRig()
        let confirmation = rig.viewModel.deleteConfirmation(for: [try item("Beach.jpg", in: rig.store)])
        #expect(confirmation.message.contains("Recently Deleted"))
    }

    // MARK: - Drag and drop

    @Test("A folder cell accepts drops")
    func folderAcceptsDrops() async throws {
        let rig = try makeRig()
        #expect(rig.viewModel.canDrop(onto: try item("Photos", in: rig.store)))
    }

    @Test("A file cell is not a drop target")
    func fileIsNotDropTarget() async throws {
        let rig = try makeRig()
        #expect(!rig.viewModel.canDrop(onto: try item("Beach.jpg", in: rig.store)))
    }

    @Test("Dropping an item on a folder moves it there")
    func dropOnFolderMoves() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        await rig.viewModel.drop(
            try item("Beach.jpg", in: rig.store), onto: try item("Photos", in: rig.store))
        #expect(rig.store.calls.contains(.move("Beach.jpg", destination: "Photos")))
        #expect(!rig.viewModel.items.map(\.name).contains("Beach.jpg"))
    }

    @Test("A drop whose move fails shows the error once and still reloads the folder")
    func dropMoveFailureShowsErrorAndReloads() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let loadsBefore = rig.store.calls.filter { if case .contents = $0 { true } else { false } }
            .count
        let missing = ghost("Missing.jpg", store: rig.store)
        await rig.viewModel.drop(missing, onto: try item("Photos", in: rig.store))
        #expect(errorMessages(rig.alerts).count == 1)
        let loadsAfter = rig.store.calls.filter { if case .contents = $0 { true } else { false } }.count
        #expect(loadsAfter == loadsBefore + 1)
    }

    @Test("Dropping on a file moves nothing")
    func dropOnFileIgnored() async throws {
        let rig = try makeRig()
        await rig.viewModel.drop(
            try item("Beach.jpg", in: rig.store), onto: try item("Notes.rtf", in: rig.store))
        #expect(!rig.store.calls.contains { if case .move = $0 { true } else { false } })
    }

    @Test("A drop that is not one of this app's items is ignored")
    func dropFromOtherAppIgnored() async throws {
        let rig = try makeRig()
        await rig.viewModel.drop(nil, onto: try item("Photos", in: rig.store))
        #expect(!rig.store.calls.contains { if case .move = $0 { true } else { false } })
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test(
        "Dragging out is allowed only for a plain item in a no-lock vault with no migration pending")
    func dragOutAllowed() async throws {
        let rig = try makeRig(lockMode: .none, pendingMigration: nil)
        #expect(rig.viewModel.canDragOut(try item("Beach.jpg", in: rig.store)))
    }

    @Test(
        "Dragging out is refused when the vault has a password lock",
        arguments: [LockMode.password, .passwordAndBiometrics])
    func dragOutRefusedWithLock(mode: LockMode) async throws {
        let rig = try makeRig(lockMode: mode)
        #expect(!rig.viewModel.canDragOut(try item("Beach.jpg", in: rig.store)))
    }

    @Test(
        "Dragging out is refused while a migration is pending",
        arguments: [MigrationKind.encrypt, .decrypt])
    func dragOutRefusedWithMigration(kind: MigrationKind) async throws {
        let rig = try makeRig(
            lockMode: .none, pendingMigration: PendingMigration(kind: kind, targetLockMode: nil))
        #expect(!rig.viewModel.canDragOut(try item("Beach.jpg", in: rig.store)))
    }

    @Test("Dragging out is refused for an encrypted item even with no lock")
    func dragOutRefusedForEncryptedItem() async throws {
        let rig = try makeRig(lockMode: .none, pendingMigration: nil)
        #expect(!rig.viewModel.canDragOut(ghost("Secret.txt", store: rig.store, encrypted: true)))
    }

    @Test("An unknown drag item stays in the app")
    func dragOutRefusedForUnknownItem() async throws {
        let rig = try makeRig(lockMode: .none, pendingMigration: nil)
        #expect(!rig.viewModel.canDragOut(nil))
    }

    @Test("The drag-out rule follows the current lock mode")
    func dragOutFollowsLockModeChanges() async throws {
        let rig = try makeRig()
        let beach = try item("Beach.jpg", in: rig.store)
        #expect(rig.viewModel.canDragOut(beach))
        rig.preferences.lockMode = .password
        #expect(!rig.viewModel.canDragOut(beach))
    }

    // MARK: - Refresh triggers

    private func expectRefresh(
        _ trigger: (FileBrowserViewModel) async -> Void
    ) async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        _ = try await rig.store.createFolder(named: "Arrived", in: rig.store.root)
        let before = rig.store.calls.filter { if case .contents = $0 { true } else { false } }.count
        await trigger(rig.viewModel)
        let after = rig.store.calls.filter { if case .contents = $0 { true } else { false } }.count
        #expect(after == before + 1)
        #expect(rig.viewModel.items.map(\.name).contains("Arrived"))
    }

    @Test("The browser reloads after a restore from Recently Deleted")
    func refreshAfterRestore() async throws {
        try await expectRefresh { await $0.restoreCompleted() }
    }

    @Test("The browser reloads after an import")
    func refreshAfterImport() async throws {
        try await expectRefresh { await $0.importCompleted() }
    }

    @Test("The browser reloads after the editor closes")
    func refreshAfterEditorClose() async throws {
        try await expectRefresh { await $0.editorClosed() }
    }

    @Test("The browser reloads after unlock, replacing stale items")
    func refreshAfterUnlock() async throws {
        try await expectRefresh { await $0.vaultUnlocked() }
    }

    // MARK: - Locked load, load ordering, selection pruning

    @Test("A load while the vault is locked shows no alert and leaves the state unchanged")
    func lockedLoadIsSilent() async throws {
        let rig = try makeRig()
        rig.store.errorToThrow = .locked
        await rig.viewModel.load()
        #expect(rig.alerts.alerts.isEmpty)
        #expect(rig.viewModel.items.isEmpty)
        #expect(rig.viewModel.emptyStateMessage == nil)
    }

    @Test("A locked load keeps the items listed before")
    func lockedLoadKeepsItems() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let before = rig.viewModel.items
        rig.store.errorToThrow = .locked
        await rig.viewModel.load()
        #expect(rig.alerts.alerts.isEmpty)
        #expect(rig.viewModel.items == before)
    }

    @Test("Unlocking after a locked load lists the items")
    func unlockAfterLockedLoadLists() async throws {
        let rig = try makeRig()
        rig.store.errorToThrow = .locked
        await rig.viewModel.load()
        rig.store.errorToThrow = nil
        await rig.viewModel.vaultUnlocked()
        #expect(rig.viewModel.items.count == 6)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A slow older load cannot overwrite a newer one")
    func olderLoadDoesNotOverwriteNewer() async throws {
        let mock = MockVaultStoring()
        let gated = GatedVaultStore(mock, holding: .firstContents)
        let alerts = MockAlertPresenting()
        let viewModel = FileBrowserViewModel(
            directory: gated.root, store: gated, preferences: MockPreferencesStoring(),
            exporter: MockVaultExporting(), alerts: alerts)
        let older = Task { await viewModel.load() }
        while gated.waitingCount == 0 { await Task.yield() }
        _ = try await mock.createFolder(named: "Newer", in: mock.root)
        await viewModel.load()
        #expect(viewModel.items.map(\.name).contains("Newer"))
        gated.releaseAll()
        await older.value
        #expect(viewModel.items.map(\.name).contains("Newer"))
    }

    @Test("Load drops selected items that are no longer listed")
    func loadDropsMissingSelection() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let beach = try item("Beach.jpg", in: rig.store)
        let notes = try item("Notes.rtf", in: rig.store)
        rig.viewModel.toggleSelectMode()
        rig.viewModel.toggleSelection(of: beach)
        rig.viewModel.toggleSelection(of: notes)
        try await rig.store.moveToTrash(beach)
        await rig.viewModel.load()
        #expect(rig.viewModel.selectedItems.map(\.name) == ["Notes.rtf"])
        #expect(rig.viewModel.title == "1 Selected")
    }

    // MARK: - Drop on itself

    @Test("Dropping a folder onto itself is ignored")
    func dropFolderOnItselfIgnored() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let photos = try item("Photos", in: rig.store)
        await rig.viewModel.drop(photos, onto: photos)
        #expect(!rig.store.calls.contains { if case .move = $0 { true } else { false } })
        #expect(rig.alerts.alerts.isEmpty)
    }
}
