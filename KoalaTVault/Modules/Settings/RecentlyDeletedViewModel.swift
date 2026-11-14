import Combine
import Foundation

/// One row of Recently Deleted.
struct RecentlyDeletedRow: Identifiable, Sendable, Equatable {
    /// The trashed item.
    let item: VaultItem
    /// The item's name.
    let name: String
    /// The item's icon.
    let icon: FileIcon
    /// "Deletes in N days".
    let detail: String

    var id: String { item.id }
}

/// A destructive action waiting for the user to confirm it.
enum RecentlyDeletedConfirmation: Sendable, Equatable {
    case deletePermanently(VaultItem)
    case emptyTrash
}

/// The logic of Recently Deleted: the trash's rows, Restore, Delete Permanently and Empty Trash.
@MainActor
final class RecentlyDeletedViewModel: ObservableObject {
    /// What the screen says when the trash is empty.
    let emptyMessage = "No recently deleted files"
    /// The trash, most recently deleted first.
    @Published private(set) var rows: [RecentlyDeletedRow] = []
    /// The action waiting for confirmation, if any.
    @Published private(set) var confirmation: RecentlyDeletedConfirmation?
    /// True while the screen asks whether to clear trash that can never be read.
    @Published private(set) var isAskingToClearUnreadableTrash = false
    /// The unreadable-trash prompt's title.
    let unreadableTrashPromptTitle = "Some Deleted Items Can't Be Read"
    /// The unreadable-trash prompt's message.
    let unreadableTrashPromptMessage =
        "They were encrypted with a key this vault no longer has, so they can never be restored or opened. "
        + "Clear them now?"

    private static let trashDays = 30
    private static let secondsPerDay: TimeInterval = 86_400
    /// Absorbs the rounding of date arithmetic, which can leave an exact day a hair short of a whole one.
    private static let dayRoundingTolerance: TimeInterval = 0.001

    private let store: any VaultStoring
    private weak var alerts: (any AlertPresenting)?
    private let now: @Sendable () -> Date
    private let folderAssetAvailable: Bool
    private let onRestore: @MainActor () -> Void
    /// The store is asked about unreadable trash at most once per opening of the screen (one instance).
    private var hasCheckedUnreadableTrash = false
    /// True only while the rows come from a listing that succeeded and was empty: the empty state shows
    /// then and never after a listing error.
    private var lastListingWasEmpty = false
    /// Counts list changes. A reload applies its result only if nothing changed the list (another reload,
    /// or a row removed after an action) while it waited, so the newest result wins.
    private var listGeneration = 0

    /// - Parameters:
    ///   - store: the vault store, which holds the trash.
    ///   - alerts: shows errors (held weakly; usually the view controller that owns this).
    ///   - now: the clock.
    ///   - folderAssetAvailable: whether the bundle has the folder image.
    ///   - onRestore: called after an item is restored, to refresh the browser.
    init(
        store: any VaultStoring, alerts: any AlertPresenting,
        now: @escaping @Sendable () -> Date = RecentlyDeletedViewModel.liveNow,
        folderAssetAvailable: Bool = true, onRestore: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.alerts = alerts
        self.now = now
        self.folderAssetAvailable = folderAssetAvailable
        self.onRestore = onRestore
    }

    /// The real clock.
    nonisolated static func liveNow() -> Date {
        Date()
    }

    /// True when the last listing succeeded and the trash held nothing (never after a listing error).
    var isEmpty: Bool { rows.isEmpty && lastListingWasEmpty }

    /// Whether Empty Trash can be chosen.
    var canEmptyTrash: Bool { !rows.isEmpty }

    /// Reads the trash; on the first load of this screen, also asks whether to clear unreadable trash.
    func load() async {
        await reloadRows()
        guard !hasCheckedUnreadableTrash else { return }
        hasCheckedUnreadableTrash = true
        if await store.hasUnreadableTrash() {
            isAskingToClearUnreadableTrash = true
        }
    }

    /// The user chose Clear on the unreadable-trash prompt: clears it, then reloads the list.
    func clearUnreadableTrash() async {
        isAskingToClearUnreadableTrash = false
        do {
            try await store.clearUnreadableTrash()
        } catch {
            alerts?.showError(error)
            return
        }
        await reloadRows()
    }

    /// The user chose Not Now on the unreadable-trash prompt: nothing changes.
    func declineClearingUnreadableTrash() {
        isAskingToClearUnreadableTrash = false
    }

    /// Puts the item back and refreshes the browser. Its row goes at once, before the list is read again;
    /// an item already gone (`.notFound`) loses its row with no alert.
    func restore(_ item: VaultItem) async {
        do {
            _ = try await store.restore(item)
        } catch VaultStoreError.notFound {
            removeRow(of: item)
            await load()
            return
        } catch {
            alerts?.showError(error)
            return
        }
        removeRow(of: item)
        await load()
        onRestore()
    }

    /// Asks to confirm deleting the item for good.
    func requestDelete(_ item: VaultItem) {
        confirmation = .deletePermanently(item)
    }

    /// Asks to confirm emptying the trash.
    func requestEmptyTrash() {
        confirmation = .emptyTrash
    }

    /// The user declined the action.
    func cancelConfirmation() {
        confirmation = nil
    }

    /// The user confirmed the action.
    func confirmPending() async {
        guard let pending = confirmation else { return }
        confirmation = nil
        switch pending {
        case .deletePermanently(let item):
            do {
                try await store.deletePermanently(item)
            } catch VaultStoreError.notFound {
                // Already gone: the row goes like after a success, with no alert.
            } catch {
                alerts?.showError(error)
                return
            }
            removeRow(of: item)
        case .emptyTrash:
            await store.emptyTrash()
            replaceRows(with: [])
        }
        await load()
    }

    // MARK: - Private

    /// Reads the trash. Success replaces the rows; a failure keeps the rows shown and shows the error.
    /// A result that a newer list change overtook is dropped.
    private func reloadRows() async {
        listGeneration += 1
        let generation = listGeneration
        do {
            let items = try await store.trashContents().sorted {
                ($0.deletedAt ?? $0.dateModified) > ($1.deletedAt ?? $1.dateModified)
            }
            guard generation == listGeneration else { return }
            lastListingWasEmpty = items.isEmpty
            rows = items.map(row(for:))
        } catch {
            guard generation == listGeneration else { return }
            if lastListingWasEmpty {
                // No longer known to be empty: republish the rows so the screen hides the empty state.
                lastListingWasEmpty = false
                rows = rows
            }
            alerts?.showError(error)
        }
    }

    /// Drops the item's row at once, ahead of the reload that follows an action.
    private func removeRow(of item: VaultItem) {
        replaceRows(with: rows.filter { $0.item.id != item.id })
    }

    /// Changes the rows locally; a reload already in flight was read before this change, so it is dropped.
    /// The empty state still waits for a listing.
    private func replaceRows(with newRows: [RecentlyDeletedRow]) {
        listGeneration += 1
        lastListingWasEmpty = false
        rows = newRows
    }

    private func row(for item: VaultItem) -> RecentlyDeletedRow {
        RecentlyDeletedRow(
            item: item, name: item.name,
            icon: FileIconMapping.icon(
                for: item.kind, isDirectory: item.isDirectory, folderAssetAvailable: folderAssetAvailable),
            detail: detail(for: item))
    }

    private func detail(for item: VaultItem) -> String {
        let elapsed = now().timeIntervalSince(item.deletedAt ?? item.dateModified)
        let wholeDays = Int((elapsed + Self.dayRoundingTolerance) / Self.secondsPerDay)
        let daysLeft = max(0, Self.trashDays - wholeDays)
        return "Deletes in \(daysLeft) day\(daysLeft == 1 ? "" : "s")"
    }
}
