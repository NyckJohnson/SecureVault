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

    /// True when the trash holds nothing.
    var isEmpty: Bool { rows.isEmpty }

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

    /// Puts the item back and refreshes the browser.
    func restore(_ item: VaultItem) async {
        do {
            _ = try await store.restore(item)
        } catch {
            alerts?.showError(error)
            return
        }
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
            } catch {
                alerts?.showError(error)
                return
            }
        case .emptyTrash:
            await store.emptyTrash()
        }
        await load()
    }

    // MARK: - Private

    private func reloadRows() async {
        do {
            let items = try await store.trashContents().sorted {
                ($0.deletedAt ?? $0.dateModified) > ($1.deletedAt ?? $1.dateModified)
            }
            rows = items.map(row(for:))
        } catch {
            rows = []
            alerts?.showError(error)
        }
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
