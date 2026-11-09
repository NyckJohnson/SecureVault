import Combine
import UIKit

/// Recently Deleted: binds `RecentlyDeletedViewModel` to the trash list, the empty message, Empty Trash and the
/// confirmations, and the prompt to clear trash that can never be read.
final class RecentlyDeletedViewController: UIViewController, AlertPresenting {
    private let store: any VaultStoring
    private let onRestore: @MainActor () -> Void
    private lazy var viewModel = RecentlyDeletedViewModel(store: store, alerts: self, onRestore: onRestore)
    private var subscriptions = Set<AnyCancellable>()
    /// The rows on screen; the table reads these, so it never sees a change before it is told to reload.
    private var rows: [RecentlyDeletedRow] = []
    /// True once the screen has finished appearing; UIKit drops presentations made while it is still appearing.
    private var hasAppeared = false
    /// Waits for the screen to be free of other alerts, then shows the unreadable-trash prompt.
    private var unreadablePromptTask: Task<Void, Never>?

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

    deinit {
        unreadablePromptTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Recently Deleted"
        view.backgroundColor = .systemBackground
        configureTable()
        configureNavigationBar()
        bindViewModel()
        Task { [viewModel] in await viewModel.load() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
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
        // Read the state on the next turn, when the view model has changed.
        viewModel.$isAskingToClearUnreadableTrash
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showUnreadableTrashPromptWhenFree() }
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

    // MARK: - Unreadable trash

    /// Shows the unreadable-trash prompt once no other alert is up (an error from loading the trash comes
    /// first), so the prompt never sits on top of another alert. Checks again every 100 ms until then; stops
    /// when the screen goes away or no longer asks.
    private func showUnreadableTrashPromptWhenFree() {
        unreadablePromptTask?.cancel()
        unreadablePromptTask = Task { [weak self] in
            while self?.showUnreadableTrashPromptIfFree() == false {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    // Cancelled: a newer request or the screen's end took over.
                    return
                }
            }
        }
    }

    /// Shows the prompt if the screen has appeared and has no alert up. Returns false when it must wait, true
    /// when it is done (shown, or no longer wanted).
    private func showUnreadableTrashPromptIfFree() -> Bool {
        guard viewModel.isAskingToClearUnreadableTrash else { return true }
        guard hasAppeared, viewIfLoaded?.window != nil, !isShowingAlert else { return false }
        let alert = UIAlertController(
            title: viewModel.unreadableTrashPromptTitle, message: viewModel.unreadableTrashPromptMessage,
            preferredStyle: .alert)
        alert.addClosingAction(title: "Clear", style: .destructive) { [viewModel] in
            Task { await viewModel.clearUnreadableTrash() }
        }
        alert.addClosingAction(title: "Not Now", style: .cancel) { [viewModel] in
            viewModel.declineClearingUnreadableTrash()
        }
        presentFromSettings(alert, animated: false)
        return true
    }

    /// True while an alert or action sheet is up over this screen, or still going away.
    private var isShowingAlert: Bool {
        var top: UIViewController = self
        while let parent = top.parent { top = parent }
        while let next = top.presentedViewController {
            if next is UIAlertController { return true }
            top = next
        }
        return false
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
