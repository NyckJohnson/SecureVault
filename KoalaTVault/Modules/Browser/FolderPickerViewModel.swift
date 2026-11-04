import Combine
import Foundation

/// The logic of one level of the folder picker: the current folder's subfolders, minus the items being
/// moved (so their subfolders can't be reached either), and the "Move Here" choice.
@MainActor
final class FolderPickerViewModel: ObservableObject {
    /// The folder this level of the picker shows.
    let directory: VaultDirectory
    /// The subfolders of `directory`, in the saved sort, without the items being moved.
    @Published private(set) var folders: [VaultItem] = []

    private let store: any VaultStoring
    private let preferences: any PreferencesStoring
    private let excludedIDs: Set<String>
    private weak var alerts: (any AlertPresenting)?

    /// - Parameters:
    ///   - store: the vault store, which lists the folders.
    ///   - preferences: holds the saved sort the folders are listed in.
    ///   - excluding: the items being moved; folders among them are left out.
    ///   - alerts: shows errors (held weakly; usually the view controller that owns this).
    ///   - directory: the folder to show; nil means the vault root.
    init(
        store: any VaultStoring, preferences: any PreferencesStoring, excluding: [VaultItem],
        alerts: any AlertPresenting,
        directory: VaultDirectory? = nil
    ) {
        self.store = store
        self.preferences = preferences
        self.excludedIDs = Set(excluding.map(\.id))
        self.alerts = alerts
        self.directory = directory ?? store.root
    }

    /// Lists the subfolders in the saved sort; an error is shown and leaves the list empty.
    func load() async {
        do {
            let listed = try await store.contents(
                of: directory, sortedBy: preferences.sortOption, preferences.sortDirection)
            folders = listed.filter { $0.isDirectory && !excludedIDs.contains($0.id) }
        } catch {
            folders = []
            alerts?.showError(error)
        }
    }

    /// The destination "Move Here" chooses: the current folder.
    func moveHereDestination() -> VaultDirectory {
        directory
    }
}
