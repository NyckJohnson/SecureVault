import Combine
import Foundation

/// The logic of one file browser screen: the folder's items, sorting, opening, New Folder / New Document,
/// select mode with bulk actions, the context menu, moving through the folder picker, drag and drop, and
/// the refreshes after restore, import, editor close and unlock.
@MainActor
final class FileBrowserViewModel: ObservableObject {
    /// Where the browser asks its view controller to go.
    enum Route: Equatable {
        /// Push a browser on this folder.
        case folder(VaultDirectory)
        /// Present the text editor on this `.rtf` item.
        case editor(VaultItem)
        /// Present the viewer on these files, starting at the given index.
        case viewer(items: [VaultItem], startingAt: Int)
        /// Present Settings.
        case settings
    }

    /// An entry of an item's context menu.
    enum ContextAction: Equatable {
        case export, move, copy, rename, delete
    }

    /// The text of a delete confirmation alert.
    struct Confirmation: Equatable {
        var title: String
        var message: String
    }

    /// Called when the browser should navigate.
    var onRoute: (Route) -> Void = { _ in }
    /// Called with a prepared export bundle for the share sheet.
    var onShare: (ExportBundle) -> Void = { _ in }
    /// Called when the folder picker should open for the given items.
    var onPresentPicker: (_ moving: [VaultItem]) -> Void = { _ in }

    /// The folder's items, in the saved sort.
    @Published private(set) var items: [VaultItem] = []
    /// Whether select mode is on.
    @Published private(set) var isSelecting = false
    /// The chosen items in select mode, in the order they were chosen.
    @Published var selectedItems: [VaultItem] = []
    @Published private var hasLoaded = false

    /// The folder this browser shows.
    let directory: VaultDirectory

    private let store: any VaultStoring
    private let preferences: any PreferencesStoring
    private let exporter: any VaultExporting
    private weak var alerts: (any AlertPresenting)?
    /// The items waiting for the folder picker's choice; only one move is pending at a time.
    private var pendingMove: [VaultItem]?
    /// Bumped by each load so an older, slower load can't overwrite a newer one.
    private var loadGeneration = 0

    /// - Parameters:
    ///   - directory: the folder to show.
    ///   - store: the vault store.
    ///   - preferences: holds the sort and the lock state the drag-out rule reads.
    ///   - exporter: prepares items for the share sheet.
    ///   - alerts: shows errors (held weakly; usually the view controller that owns this).
    init(
        directory: VaultDirectory, store: any VaultStoring, preferences: any PreferencesStoring,
        exporter: any VaultExporting, alerts: any AlertPresenting
    ) {
        self.directory = directory
        self.store = store
        self.preferences = preferences
        self.exporter = exporter
        self.alerts = alerts
    }

    // MARK: - State

    /// "No files yet" once a load found the folder empty; nil otherwise.
    var emptyStateMessage: String? {
        hasLoaded && items.isEmpty ? "No files yet" : nil
    }

    /// The settings button shows at the vault root only.
    var showsSettingsButton: Bool { directory == store.root }

    /// The folder's name, or "Select Items" / "N Selected" in select mode.
    var title: String {
        guard isSelecting else { return directory.name }
        return selectedItems.isEmpty ? "Select Items" : "\(selectedItems.count) Selected"
    }

    // MARK: - Load and sort

    /// Lists the folder with the saved sort. Errors are shown, except `locked`: the lock screen covers
    /// that state, and the unlock refresh loads again.
    func load() async {
        await load(showingErrors: true)
    }

    /// Lists the folder; `showingErrors` false keeps a reload quiet when the operation before it has
    /// already shown its error, so one failure shows one alert.
    private func load(showingErrors: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let listed = try await store.contents(
                of: directory, sortedBy: preferences.sortOption, preferences.sortDirection)
            guard generation == loadGeneration else { return }
            items = listed
            hasLoaded = true
            // Keep the selection of items still listed; ids are stable across listings.
            let listedIDs = Set(listed.map(\.id))
            selectedItems = selectedItems.filter { listedIDs.contains($0.id) }
        } catch {
            guard generation == loadGeneration, !(error is CancellationError) else { return }
            // Not shown while locked: the lock screen covers that state, and the unlock refresh
            // (`vaultUnlocked`) reloads and shows any error that remains.
            if let storeError = error as? VaultStoreError, storeError == .locked { return }
            if showingErrors { alerts?.showError(error) }
        }
    }

    /// The current option flips its direction; another option sorts ascending. Saved, then reloaded.
    func selectSort(_ option: SortOption) async {
        if preferences.sortOption == option {
            preferences.sortDirection = preferences.sortDirection == .ascending ? .descending : .ascending
        } else {
            preferences.sortOption = option
            preferences.sortDirection = .ascending
        }
        await load()
    }

    // MARK: - Open

    /// Folder → its browser; `.rtf` → the editor; any other file → the viewer on the folder's files.
    func open(_ item: VaultItem) {
        if let folder = item.asDirectory {
            onRoute(.folder(folder))
        } else if (item.name as NSString).pathExtension.lowercased() == "rtf" {
            onRoute(.editor(item))
        } else {
            let files = items.filter { !$0.isDirectory }
            let index = files.firstIndex { $0.id == item.id } ?? 0
            onRoute(.viewer(items: files, startingAt: index))
        }
    }

    /// Asks for Settings.
    func openSettings() {
        onRoute(.settings)
    }

    // MARK: - New Folder / New Document

    /// Creates a folder with the trimmed name; a blank name does nothing.
    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await store.createFolder(named: trimmed, in: directory)
        } catch {
            alerts?.showError(error)
            return
        }
        await load()
    }

    /// Creates a document with the trimmed name and opens the editor on it; a blank name does nothing.
    func createDocument(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let created: VaultItem
        do {
            created = try await store.createDocument(named: trimmed, in: directory)
        } catch {
            alerts?.showError(error)
            return
        }
        onRoute(.editor(created))
        await load()
    }

    // MARK: - Select mode

    /// Turns select mode on or off; turning it off clears the selection.
    func toggleSelectMode() {
        isSelecting.toggle()
        selectedItems = []
    }

    /// Chooses the item, or un-chooses it if already chosen.
    func toggleSelection(of item: VaultItem) {
        if let index = selectedItems.firstIndex(where: { $0.id == item.id }) {
            selectedItems.remove(at: index)
        } else {
            selectedItems.append(item)
        }
    }

    /// Leaves select mode and clears the selection.
    func cancelSelection() {
        isSelecting = false
        selectedItems = []
    }

    // MARK: - Delete, copy, export

    /// The confirmation for deleting these items: one item by name, several as "Delete N items?".
    func deleteConfirmation(for items: [VaultItem]) -> Confirmation {
        if items.count == 1, let item = items.first {
            let message =
                item.isDirectory
                ? "The folder and all its contents move to Recently Deleted."
                : "The item moves to Recently Deleted."
            return Confirmation(title: "Delete \"\(item.name)\"?", message: message)
        }
        return Confirmation(
            title: "Delete \(items.count) items?", message: "The items move to Recently Deleted.")
    }

    /// Moves each item to the trash, leaves select mode and reloads.
    func delete(_ items: [VaultItem]) async {
        let store = store
        await perform(on: items) { try await store.moveToTrash($0) }
    }

    /// Copies each item into this folder, leaves select mode and reloads.
    func copy(_ items: [VaultItem]) async {
        let store = store
        let directory = directory
        await perform(on: items) { _ = try await store.copy($0, to: directory) }
    }

    /// Prepares the items and hands the bundle to the share sheet.
    func export(_ items: [VaultItem]) async {
        do {
            let bundle = try await exporter.prepareForSharing(items)
            onShare(bundle)
        } catch {
            alerts?.showError(error)
        }
    }

    // MARK: - Move

    /// Remembers the items to move (replacing any earlier pending move) and asks for the picker.
    func beginMove(_ items: [VaultItem]) {
        pendingMove = items
        onPresentPicker(items)
    }

    /// Moves exactly the pending items into the chosen folder; the pending move is used once.
    func pickerChose(_ destination: VaultDirectory) async {
        guard let moving = pendingMove else { return }
        pendingMove = nil
        let store = store
        await perform(on: moving) { try await store.move($0, to: destination) }
    }

    /// Drops the pending move.
    func pickerCancelled() {
        pendingMove = nil
    }

    // MARK: - Context menu

    /// Every item's menu: Export, Move, Copy, Rename, Delete.
    func contextActions(for item: VaultItem) -> [ContextAction] {
        [.export, .move, .copy, .rename, .delete]
    }

    /// The Rename field starts with the current name.
    func renamePrefill(for item: VaultItem) -> String {
        item.name
    }

    /// Renames through the store and reloads.
    func rename(_ item: VaultItem, to name: String) async {
        do {
            _ = try await store.rename(item, to: name)
        } catch {
            alerts?.showError(error)
            return
        }
        await load()
    }

    // MARK: - Drag and drop

    /// Only folder cells take drops.
    func canDrop(onto target: VaultItem) -> Bool {
        target.isDirectory
    }

    /// Moves a dragged item of this app into the target folder. Drops from other apps (nil), onto files,
    /// or of a folder onto itself are ignored.
    func drop(_ dragged: VaultItem?, onto target: VaultItem) async {
        guard let dragged, dragged.id != target.id, let folder = target.asDirectory else { return }
        do {
            try await store.move(dragged, to: folder)
        } catch {
            alerts?.showError(error)
        }
        await load()
    }

    /// A drag may leave the app only for a known, unencrypted item in a no-lock vault with no
    /// migration pending: otherwise the on-disk file could be ciphertext.
    func canDragOut(_ item: VaultItem?) -> Bool {
        guard let item else { return false }
        return preferences.lockMode == .none && preferences.pendingMigration == nil && !item.isEncrypted
    }

    // MARK: - Refresh triggers

    /// Reloads after an item was restored from Recently Deleted.
    func restoreCompleted() async { await load() }
    /// Reloads after an import.
    func importCompleted() async { await load() }
    /// Reloads after the editor closed.
    func editorClosed() async { await load() }
    /// Reloads after unlock, replacing items listed before the lock.
    func vaultUnlocked() async { await load() }

    // MARK: - Helpers

    /// Runs `operation` on each item, then leaves select mode and reloads. One failure shows its error;
    /// failures among several items show "N of M failed." with the first error. Cancellation (of the
    /// calling task, or a `CancellationError` from the store) stops before the remaining items and is
    /// not counted as a failure.
    private func perform(
        on items: [VaultItem], _ operation: (VaultItem) async throws -> Void
    ) async {
        var errors: [Error] = []
        for item in items {
            if Task.isCancelled { break }
            do {
                try await operation(item)
            } catch is CancellationError {
                break
            } catch {
                errors.append(error)
            }
        }
        cancelSelection()
        await load(showingErrors: errors.isEmpty)
        guard let firstError = errors.first else { return }
        if items.count == 1 {
            alerts?.showError(firstError)
        } else {
            alerts?.showError("\(errors.count) of \(items.count) failed. \(firstError.localizedDescription)")
        }
    }
}
