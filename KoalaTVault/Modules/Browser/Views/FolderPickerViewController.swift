import Combine
import UIKit

/// One level of the folder picker: the folder's subfolders in a table, "Move Here" and "Cancel". Selecting a
/// row pushes the next level with the same callbacks. The picker never dismisses itself: whoever presented it
/// does, in `onChoose` and `onCancel`. What it lists comes from `FolderPickerViewModel`.
@MainActor
final class FolderPickerViewController: UIViewController, AlertPresenting {
    private static let rowReuseID = "FolderCell"

    private let store: any VaultStoring
    private let preferences: any PreferencesStoring
    private let excluding: [VaultItem]
    private let onChoose: @MainActor (VaultDirectory) -> Void
    private let onCancel: @MainActor () -> Void

    private lazy var viewModel = FolderPickerViewModel(
        store: store, preferences: preferences, excluding: excluding, alerts: self, directory: startDirectory)
    private let startDirectory: VaultDirectory?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private lazy var cancelButton = UIBarButtonItem(
        title: "Cancel", style: .plain, target: self, action: #selector(cancelTapped))
    private lazy var moveHereButton = UIBarButtonItem(
        title: "Move Here", style: .done, target: self, action: #selector(moveHereTapped))

    /// The folders the table shows: the view model's list as of its last change.
    private var shownFolders: [VaultItem] = []
    /// Set by the first Move Here or Cancel, so a double tap can't report twice.
    private var didFinish = false
    private var subscriptions: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - store: the vault store, which lists the folders.
    ///   - preferences: holds the saved sort the folders are listed in.
    ///   - excluding: the items being moved; they and their subfolders are left out.
    ///   - directory: the folder to show; nil means the vault root.
    ///   - onChoose: called with the chosen folder when Move Here is tapped (at any level).
    ///   - onCancel: called when Cancel is tapped (at any level).
    init(
        store: any VaultStoring, preferences: any PreferencesStoring, excluding: [VaultItem],
        directory: VaultDirectory?,
        onChoose: @escaping @MainActor (VaultDirectory) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.preferences = preferences
        self.excluding = excluding
        self.startDirectory = directory
        self.onChoose = onChoose
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        cancelButton.accessibilityIdentifier = "folderPickerCancel"
        moveHereButton.accessibilityIdentifier = "folderPickerMoveHere"
        navigationItem.leftItemsSupplementBackButton = true
        showBarButtons()

        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.rowReuseID)
        tableView.accessibilityIdentifier = "folderPicker.folderList"
        view.addSubview(tableView)

        viewModel.$folders
            .sink { [weak self] folders in self?.show(folders) }
            .store(in: &subscriptions)
        Task { [weak self] in await self?.viewModel.load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Back on top after the deeper level was popped.
        showBarButtons()
    }

    /// Only the top level offers Move Here and Cancel, so they always act on the folder on screen.
    private func showBarButtons() {
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItem = moveHereButton
    }

    private func hideBarButtons() {
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItem = nil
    }

    private func show(_ folders: [VaultItem]) {
        shownFolders = folders
        tableView.reloadData()
    }

    @objc private func cancelTapped() {
        guard !didFinish else { return }
        didFinish = true
        onCancel()
    }

    @objc private func moveHereTapped() {
        guard !didFinish else { return }
        didFinish = true
        onChoose(viewModel.moveHereDestination())
    }
}

// MARK: - UITableViewDataSource

extension FolderPickerViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        shownFolders.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.rowReuseID, for: indexPath)
        guard shownFolders.indices.contains(indexPath.row) else { return cell }
        let folder = shownFolders[indexPath.row]
        var configuration = cell.defaultContentConfiguration()
        configuration.text = folder.name
        configuration.image = UIImage(systemName: "folder.fill")
        configuration.imageProperties.tintColor = .systemYellow
        cell.contentConfiguration = configuration
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "folderPicker.row.\(folder.name)"
        return cell
    }
}

// MARK: - UITableViewDelegate

extension FolderPickerViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard shownFolders.indices.contains(indexPath.row),
            let folder = shownFolders[indexPath.row].asDirectory
        else { return }
        let next = FolderPickerViewController(
            store: store, preferences: preferences, excluding: excluding, directory: folder,
            onChoose: onChoose, onCancel: onCancel)
        hideBarButtons()
        navigationController?.pushViewController(next, animated: true)
    }
}
