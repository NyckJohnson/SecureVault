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
@Suite struct FileBrowserViewModelTests {
    @MainActor
    private final class Recorder {
        var routes: [FileBrowserViewModel.Route] = []
        var shared: [[URL]] = []
        var pickerRequests: [[String]] = []
    }

    private struct Rig {
        let viewModel: FileBrowserViewModel
        let store: MockVaultStoring
        let preferences: MockPreferencesStoring
        let exporter: MockVaultExporting
        let alerts: MockAlertPresenting
        let recorder: Recorder
    }

    private func makeRig(
        inFolder folderName: String? = nil,
        lockMode: LockMode = .none,
        pendingMigration: PendingMigration? = nil,
        withSampleContent: Bool = true
    ) throws -> Rig {
        let store = MockVaultStoring(withSampleContent: withSampleContent)
        let directory: VaultDirectory
        if let folderName {
            let folder = try #require(store.allItems.first { $0.name == folderName && $0.isDirectory })
            directory = try #require(folder.asDirectory)
        } else {
            directory = store.root
        }
        let preferences = MockPreferencesStoring(lockMode: lockMode, pendingMigration: pendingMigration)
        let exporter = MockVaultExporting()
        let alerts = MockAlertPresenting()
        let recorder = Recorder()
        let viewModel = FileBrowserViewModel(
            directory: directory, store: store, preferences: preferences, exporter: exporter, alerts: alerts)
        viewModel.onRoute = { recorder.routes.append($0) }
        viewModel.onShare = { recorder.shared.append($0.urls) }
        viewModel.onPresentPicker = { recorder.pickerRequests.append($0.map(\.id)) }
        return Rig(
            viewModel: viewModel, store: store, preferences: preferences, exporter: exporter, alerts: alerts,
            recorder: recorder)
    }

    private func item(_ name: String, in store: MockVaultStoring) throws -> VaultItem {
        try #require(store.allItems.first { $0.name == name })
    }

    /// An item the store doesn't hold, so store calls on it throw `notFound`.
    private func ghost(_ name: String, store: MockVaultStoring, encrypted: Bool = false) -> VaultItem {
        VaultItem(
            id: "ghost/\(name)", name: name, isDirectory: false, dateModified: Date(), fileSize: 1,
            deletedAt: nil, diskURL: store.root.diskURL.appendingPathComponent("ghost/\(name)"),
            rootURL: store.root.rootURL, isEncrypted: encrypted)
    }

    private func errorMessages(_ alerts: MockAlertPresenting) -> [String] {
        alerts.alerts.compactMap { alert in
            if case .error(let message) = alert { return message }
            return nil
        }
    }

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

    @Test("A failed load after a good one does not keep showing the old items as current without an alert")
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

    @Test("Opening another file routes to the viewer with the folder's files starting at the tapped one")
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

    // MARK: - Bulk delete

    @Test("Bulk delete asks Delete N items?")
    func bulkDeleteConfirmTitle() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let three = try ["Beach.jpg", "Notes.rtf", "Holiday.mov"].map { try item($0, in: rig.store) }
        #expect(rig.viewModel.deleteConfirmation(for: three).title == "Delete 3 items?")
    }

    @Test("Delete moves every item to the trash and reloads")
    func deleteMovesToTrash() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let two = try ["Beach.jpg", "Notes.rtf"].map { try item($0, in: rig.store) }
        await rig.viewModel.delete(two)
        #expect(rig.store.calls.contains(.moveToTrash("Beach.jpg")))
        #expect(rig.store.calls.contains(.moveToTrash("Notes.rtf")))
        #expect(!rig.viewModel.items.map(\.name).contains("Beach.jpg"))
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Bulk delete reports N of M failed when some fail and still deletes the rest")
    func deletePartialFailure() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let items = [try item("Beach.jpg", in: rig.store), ghost("Missing.txt", store: rig.store)]
        await rig.viewModel.delete(items)
        #expect(rig.store.calls.contains(.moveToTrash("Beach.jpg")))
        #expect(errorMessages(rig.alerts).contains { $0.contains("1 of 2 failed") })
    }

    @Test("Bulk delete reports every item failing")
    func deleteAllFail() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let items = [try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)]
        rig.store.errorToThrow = .io("disk")
        await rig.viewModel.delete(items)
        #expect(errorMessages(rig.alerts).contains { $0.contains("2 of 2 failed") })
    }

    // MARK: - Copy

    @Test("Copy puts a copy of each item into the current folder")
    func copyIntoCurrentFolder() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        await rig.viewModel.copy([try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)])
        #expect(rig.store.calls.contains(.copy("Beach.jpg", destination: "")))
        #expect(rig.store.calls.contains(.copy("Notes.rtf", destination: "")))
        #expect(rig.viewModel.items.map(\.name).contains("Beach 1.jpg"))
    }

    @Test("Bulk copy reports N of M failed when some fail")
    func copyPartialFailure() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let items = [
            try item("Beach.jpg", in: rig.store), ghost("A.txt", store: rig.store), ghost("B.txt", store: rig.store),
        ]
        await rig.viewModel.copy(items)
        #expect(errorMessages(rig.alerts).contains { $0.contains("2 of 3 failed") })
    }

    // MARK: - Export

    @Test("Export prepares the items and hands the bundle to the share sheet")
    func exportShares() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let beach = try item("Beach.jpg", in: rig.store)
        await rig.viewModel.export([beach])
        #expect(rig.exporter.calls == [.prepareForSharing(["Beach.jpg"])])
        #expect(rig.recorder.shared == [[beach.diskURL]])
    }

    @Test("An export failure is shown and nothing is shared")
    func exportFailureShown() async throws {
        let rig = try makeRig()
        await rig.viewModel.export([])
        #expect(errorMessages(rig.alerts).count == 1)
        #expect(rig.recorder.shared.isEmpty)
    }

    // MARK: - Move and the picker

    @Test("Move asks for the picker with the items to move")
    func moveOpensPicker() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)])
        #expect(rig.recorder.pickerRequests == [["Beach.jpg", "Notes.rtf"]])
    }

    @Test("The picker's choice moves exactly the pending items")
    func pickerChoiceMovesPending() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)])
        await rig.viewModel.pickerChose(documents)
        let moves = rig.store.calls.filter { if case .move = $0 { true } else { false } }
        #expect(moves == [.move("Beach.jpg", destination: "Documents"), .move("Notes.rtf", destination: "Documents")])
        #expect(!rig.viewModel.items.map(\.name).contains("Beach.jpg"))
    }

    @Test("Only one move is pending at a time: a new move replaces the old")
    func newMoveReplacesPending() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store)])
        rig.viewModel.beginMove([try item("Notes.rtf", in: rig.store)])
        await rig.viewModel.pickerChose(documents)
        let moves = rig.store.calls.filter { if case .move = $0 { true } else { false } }
        #expect(moves == [.move("Notes.rtf", destination: "Documents")])
    }

    @Test("Cancelling the picker clears the pending move")
    func cancelClearsPendingMove() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store)])
        rig.viewModel.pickerCancelled()
        await rig.viewModel.pickerChose(documents)
        #expect(!rig.store.calls.contains { if case .move = $0 { true } else { false } })
    }

    @Test("After a cancel, the next move moves only its own items")
    func moveAfterCancelIgnoresOldSelection() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)])
        rig.viewModel.pickerCancelled()
        rig.viewModel.beginMove([try item("Holiday.mov", in: rig.store)])
        await rig.viewModel.pickerChose(documents)
        let moves = rig.store.calls.filter { if case .move = $0 { true } else { false } }
        #expect(moves == [.move("Holiday.mov", destination: "Documents")])
    }

    @Test("A picker choice is used once; choosing again moves nothing")
    func pendingMoveConsumed() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store)])
        await rig.viewModel.pickerChose(documents)
        await rig.viewModel.pickerChose(documents)
        let moves = rig.store.calls.filter { if case .move = $0 { true } else { false } }
        #expect(moves.count == 1)
    }

    @Test("Bulk move reports N of M failed when some fail")
    func movePartialFailure() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store), ghost("Gone.txt", store: rig.store)])
        await rig.viewModel.pickerChose(documents)
        #expect(errorMessages(rig.alerts).contains { $0.contains("1 of 2 failed") })
    }

    @Test("Moving a folder into itself shows an error and moves nothing")
    func moveFolderIntoItselfShowsError() async throws {
        let rig = try makeRig()
        let photos = try item("Photos", in: rig.store)
        let inner = try await rig.store.createFolder(named: "Inner", in: try #require(photos.asDirectory))
        await rig.viewModel.load()
        rig.viewModel.beginMove([photos])
        await rig.viewModel.pickerChose(try #require(inner.asDirectory))
        #expect(!errorMessages(rig.alerts).isEmpty)
        #expect(try item("Photos", in: rig.store).diskURL == photos.diskURL)
    }

    // MARK: - Context menu

    @Test("The context menu offers Export, Move, Copy, Rename and Delete", arguments: ["Beach.jpg", "Photos"])
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
        await rig.viewModel.drop(try item("Beach.jpg", in: rig.store), onto: try item("Photos", in: rig.store))
        #expect(rig.store.calls.contains(.move("Beach.jpg", destination: "Photos")))
        #expect(!rig.viewModel.items.map(\.name).contains("Beach.jpg"))
    }

    @Test("Dropping on a file moves nothing")
    func dropOnFileIgnored() async throws {
        let rig = try makeRig()
        await rig.viewModel.drop(try item("Beach.jpg", in: rig.store), onto: try item("Notes.rtf", in: rig.store))
        #expect(!rig.store.calls.contains { if case .move = $0 { true } else { false } })
    }

    @Test("A drop that is not one of this app's items is ignored")
    func dropFromOtherAppIgnored() async throws {
        let rig = try makeRig()
        await rig.viewModel.drop(nil, onto: try item("Photos", in: rig.store))
        #expect(!rig.store.calls.contains { if case .move = $0 { true } else { false } })
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Dragging out is allowed only for a plain item in a no-lock vault with no migration pending")
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

    @Test("Dragging out is refused while a migration is pending", arguments: [MigrationKind.encrypt, .decrypt])
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
}
