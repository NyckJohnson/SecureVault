import Combine
import UIKit

/// Recently Deleted: binds `RecentlyDeletedViewModel` to the trash list, the empty message, Empty Trash and the
/// confirmations.
final class RecentlyDeletedViewController: UIViewController, AlertPresenting {
    private let store: any VaultStoring
    private let onRestore: @MainActor () -> Void
    private lazy var viewModel = RecentlyDeletedViewModel(store: store, alerts: self, onRestore: onRestore)
    private var subscriptions = Set<AnyCancellable>()
    /// The rows on screen; the table reads these, so it never sees a change before it is told to reload.
    private var rows: [RecentlyDeletedRow] = []

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyStateLabel = UILabel()
    private let emptyTrashButton = UIButton(type: .system)

    /// - Parameters:
    ///   - store: the vault store, which holds the trash.
    ///   - onRestore: called after an item is restored, to refresh the browser.
    init(store: any VaultStoring, onRestore: @escaping @MainActor () -> Void) {
        self.store = store
        self.onRestore = onRestore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Recently Deleted"
        view.backgroundColor = .systemBackground
        configureTable()
        configureNavigationBar()
        bindViewModel()
        Task { [viewModel] in await viewModel.load() }
    }

    private func configureTable() {
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.accessibilityIdentifier = "recentlyDeleted.list"

        emptyStateLabel.text = viewModel.emptyMessage
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.font = .preferredFont(forTextStyle: .body)
        emptyStateLabel.accessibilityIdentifier = "recentlyDeleted.emptyStateLabel"
        tableView.backgroundView = emptyStateLabel
        view.addSubview(tableView)
    }

    private func configureNavigationBar() {
        // A button as the bar item's view, so the identifier and enabled state sit on a real control.
        emptyTrashButton.setTitle("Empty Trash", for: .normal)
        emptyTrashButton.setTitleColor(.systemRed, for: .normal)
        emptyTrashButton.setTitleColor(.tertiaryLabel, for: .disabled)
        emptyTrashButton.addTarget(self, action: #selector(emptyTrashTapped), for: .touchUpInside)
        emptyTrashButton.accessibilityIdentifier = "recentlyDeleted.emptyTrashButton"
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: emptyTrashButton)
        render()
    }

    private func bindViewModel() {
        // Published values arrive before the view model changes; render its whole state on the next turn.
        viewModel.$rows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
        viewModel.$confirmation
            .compactMap { $0 }
            .sink { [weak self] confirmation in self?.present(confirmation) }
            .store(in: &subscriptions)
    }

    private func render() {
        rows = viewModel.rows
        // Cells left over from before keep no identifier, and the new ones are laid out at once.
        for cell in tableView.visibleCells { cell.accessibilityIdentifier = nil }
        tableView.reloadData()
        tableView.layoutIfNeeded()
        emptyStateLabel.isHidden = !viewModel.isEmpty
        emptyTrashButton.isEnabled = viewModel.canEmptyTrash
        navigationItem.rightBarButtonItem?.isEnabled = viewModel.canEmptyTrash
    }

    // MARK: - Actions

    @objc private func emptyTrashTapped() {
        viewModel.requestEmptyTrash()
    }

    private func presentActions(for row: RecentlyDeletedRow, from sourceView: UIView?) {
        let item = row.item
        let sheet = UIAlertController(title: row.name, message: nil, preferredStyle: .actionSheet)
        sheet.addClosingAction(title: "Restore", style: .default) { [viewModel] in
            Task { await viewModel.restore(item) }
        }
        // The confirmation follows at once; it goes over the sheet should the sheet still be up.
        sheet.addAction(
            UIAlertAction(title: "Delete Permanently", style: .destructive) { [viewModel] _ in
                viewModel.requestDelete(item)
            })
        sheet.addClosingAction(title: "Cancel", style: .cancel)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView ?? view
        }
        presentFromSettings(sheet, animated: false)
    }

    private func present(_ confirmation: RecentlyDeletedConfirmation) {
        let alert: UIAlertController
        let confirmTitle: String
        switch confirmation {
        case .deletePermanently(let item):
            alert = UIAlertController(
                title: "Delete Permanently?", message: "\"\(item.name)\" will be deleted. This can't be undone.",
                preferredStyle: .alert)
            confirmTitle = "Delete"
        case .emptyTrash:
            alert = UIAlertController(
                title: "Empty Trash?", message: "All recently deleted files will be permanently deleted.",
                preferredStyle: .alert)
            confirmTitle = "Empty Trash"
        }
        alert.addClosingAction(title: "Cancel", style: .cancel) { [viewModel] in viewModel.cancelConfirmation() }
        alert.addClosingAction(title: confirmTitle, style: .destructive) { [viewModel] in
            Task { await viewModel.confirmPending() }
        }
        presentFromSettings(alert, animated: false)
    }

    // MARK: - Icons

    /// The image and tint for a row: the folder asset when the bundle has it, otherwise the SF Symbol (the
    /// folder fallback symbol at 24 pt).
    private static func imageAndTint(for row: RecentlyDeletedRow) -> (image: UIImage?, tint: UIColor) {
        var icon = row.icon
        if icon.usesFolderAsset {
            if let asset = UIImage(named: icon.symbolName) {
                return (asset, tintColor(named: icon.tintName))
            }
            icon = FileIconMapping.icon(
                for: row.item.kind, isDirectory: row.item.isDirectory, folderAssetAvailable: false)
        }
        var image = UIImage(systemName: icon.symbolName)
        if row.item.isDirectory {
            image = image?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 24, weight: .regular))
        }
        return (image, tintColor(named: icon.tintName))
    }

    /// The `UIColor` a `FileIcon.tintName` names.
    private static func tintColor(named name: String) -> UIColor {
        switch name {
        case "clear": .clear
        case "systemYellow": .systemYellow
        case "systemGreen": .systemGreen
        case "systemPurple": .systemPurple
        case "systemPink": .systemPink
        case "systemRed": .systemRed
        case "systemBlue": .systemBlue
        case "systemOrange": .systemOrange
        case "systemBrown": .systemBrown
        default: .systemGray
        }
    }
}

// MARK: - UITableViewDataSource

extension RecentlyDeletedViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        guard rows.indices.contains(indexPath.row) else { return cell }
        let row = rows[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = row.name
        config.secondaryText = row.detail
        let (image, tint) = Self.imageAndTint(for: row)
        config.image = image
        config.imageProperties.tintColor = tint
        cell.contentConfiguration = config
        cell.accessibilityIdentifier = "recentlyDeleted.row.\(row.name)"
        return cell
    }
}

// MARK: - UITableViewDelegate

extension RecentlyDeletedViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row) else { return }
        presentActions(for: rows[indexPath.row], from: tableView.cellForRow(at: indexPath))
    }
}
