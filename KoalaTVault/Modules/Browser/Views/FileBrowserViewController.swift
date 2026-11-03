import Combine
import UIKit

/// The vault grid for one folder: binds `FileBrowserViewModel` to a collection view and the bar buttons, and
/// presents what the view model asks for (subfolder browsers, the viewer and editor, Settings, the folder
/// picker) and the Import and Export flows. Every decision is the view model's.
@MainActor
final class FileBrowserViewController: UIViewController, AlertPresenting {
    private let directory: VaultDirectory
    private let store: any VaultStoring
    private let preferences: any PreferencesStoring
    private let thumbnails: any ThumbnailProviding
    private let exporter: any VaultExporting
    private let exportPresenter: ExportPresenter
    private let importPresenter: ImportPresenter
    private let viewerFactory: any ViewerFactory
    private let settingsFactory: any SettingsFactory

    private lazy var viewModel = FileBrowserViewModel(
        directory: directory, store: store, preferences: preferences, exporter: exporter, alerts: self)

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
    private let emptyStateLabel = UILabel()

    private lazy var settingsButton = makeButton(
        image: "gear", id: "settingsButton", action: #selector(settingsTapped))
    private lazy var sortButton = makeButton(
        image: "arrow.up.arrow.down", id: "sortButton", action: #selector(sortTapped))
    private lazy var newFolderButton = makeButton(
        image: "folder.badge.plus", id: "newFolderButton", action: #selector(newFolderTapped))
    private lazy var newDocumentButton = makeButton(
        image: "doc.badge.plus", id: "newDocumentButton", action: #selector(newDocumentTapped))
    private lazy var importButton = makeButton(
        image: "square.and.arrow.down", id: "importButton", action: #selector(importTapped))
    private lazy var selectButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Select", style: .plain, target: self, action: #selector(selectTapped))
        button.accessibilityIdentifier = "selectButton"
        return button
    }()
    private lazy var bulkDeleteButton: UIBarButtonItem = {
        let button = makeButton(image: "trash", id: "bulkDeleteButton", action: #selector(bulkDeleteTapped))
        button.tintColor = .systemRed
        return button
    }()
    private lazy var bulkMoveButton = makeButton(
        image: "arrow.right.circle", id: "bulkMoveButton", action: #selector(bulkMoveTapped))
    private lazy var bulkExportButton = makeButton(
        image: "square.and.arrow.up", id: "bulkExportButton", action: #selector(bulkExportTapped))
    private lazy var bulkCopyButton = makeButton(
        image: "doc.on.doc", id: "bulkCopyButton", action: #selector(bulkCopyTapped))

    /// The items the grid shows: the view model's items as of the last render, so the grid's counts and
    /// cells always agree with each other.
    private var shownItems: [VaultItem] = []
    /// Whether the bundle has the folder image the icons prefer.
    private let folderAssetAvailable: Bool
    private var hasAppeared = false
    /// Set while the editor is up, so coming back to this screen reloads.
    private var isEditorPresented = false
    /// Set while a context menu is on screen; a picker asked for from the menu waits for it to close.
    private var isContextMenuShown = false
    private var actionAfterContextMenu: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - directory: the folder this browser shows.
    ///   - store: the vault store.
    ///   - preferences: holds the sort and the lock state the drag-out rule reads.
    ///   - thumbnails: makes the cells' thumbnails.
    ///   - exporter: prepares items for sharing.
    ///   - exportPresenter: presents the Export flow.
    ///   - importPresenter: presents the Import flow.
    ///   - viewerFactory: makes the viewer and the editor.
    ///   - settingsFactory: makes Settings and the paywall.
    init(
        directory: VaultDirectory, store: any VaultStoring, preferences: any PreferencesStoring,
        thumbnails: any ThumbnailProviding, exporter: any VaultExporting, exportPresenter: ExportPresenter,
        importPresenter: ImportPresenter, viewerFactory: any ViewerFactory, settingsFactory: any SettingsFactory
    ) {
        self.directory = directory
        self.store = store
        self.preferences = preferences
        self.thumbnails = thumbnails
        self.exporter = exporter
        self.exportPresenter = exportPresenter
        self.importPresenter = importPresenter
        self.viewerFactory = viewerFactory
        self.settingsFactory = settingsFactory
        let folderIcon = FileIconMapping.icon(for: .other, isDirectory: true, folderAssetAvailable: true)
        self.folderAssetAvailable = UIImage(named: folderIcon.symbolName) != nil
        super.init(nibName: nil, bundle: nil)
        title = directory.name
        navigationItem.title = directory.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setUpCollectionView()
        bindViewModel()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !hasAppeared {
            hasAppeared = true
            Task { [weak self] in await self?.viewModel.load() }
        } else if isEditorPresented {
            isEditorPresented = false
            Task { [weak self] in await self?.viewModel.editorClosed() }
        }
    }

    /// Lists the folder again; the browser factory calls this after unlock and after a restore.
    func reload() {
        Task { [weak self] in await self?.viewModel.vaultUnlocked() }
    }

    private func setUpCollectionView() {
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.register(FileCell.self, forCellWithReuseIdentifier: FileCell.reuseID)
        collectionView.accessibilityIdentifier = "fileGrid"

        emptyStateLabel.textAlignment = .center
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.font = .preferredFont(forTextStyle: .body)
        emptyStateLabel.accessibilityIdentifier = "emptyStateLabel"
        emptyStateLabel.isHidden = true
        collectionView.backgroundView = emptyStateLabel

        view.addSubview(collectionView)
    }

    /// Columns of at least 100 pt (two at least), cells 1.4 times as tall as wide.
    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let inset: CGFloat = 8
            let available = environment.container.effectiveContentSize.width - inset * 2
            let columns = max(2, Int(available / 100))
            let width = available / CGFloat(columns)
            let size = NSCollectionLayoutSize(
                widthDimension: .absolute(width), heightDimension: .absolute(width * 1.4))
            let item = NSCollectionLayoutItem(layoutSize: size)
            item.contentInsets = NSDirectionalEdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .absolute(width * 1.4))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(
                top: inset, leading: inset, bottom: inset, trailing: inset)
            return section
        }
    }

    private func makeButton(image: String, id: String, action: Selector) -> UIBarButtonItem {
        let button = UIBarButtonItem(image: UIImage(systemName: image), style: .plain, target: self, action: action)
        button.accessibilityIdentifier = id
        return button
    }

    // MARK: - Binding

    private func bindViewModel() {
        viewModel.onRoute = { [weak self] route in self?.go(to: route) }
        viewModel.onPresentPicker = { [weak self] moving in self?.presentPickerWhenReady(for: moving) }
        // Fires before a change; render once the change is in place.
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
    }

    private func render() {
        navigationItem.title = viewModel.title
        if viewModel.isSelecting {
            selectButton.title = "Cancel"
            navigationItem.leftBarButtonItems = [selectButton]
            navigationItem.rightBarButtonItems = [bulkDeleteButton, bulkMoveButton, bulkExportButton, bulkCopyButton]
            let hasSelection = !viewModel.selectedItems.isEmpty
            for button in [bulkDeleteButton, bulkMoveButton, bulkExportButton, bulkCopyButton] {
                button.isEnabled = hasSelection
            }
        } else {
            selectButton.title = "Select"
            navigationItem.leftBarButtonItems = viewModel.showsSettingsButton ? [settingsButton] : []
            navigationItem.rightBarButtonItems = [
                newFolderButton, newDocumentButton, importButton, sortButton, selectButton,
            ]
        }

        shownItems = viewModel.items
        collectionView.reloadData()
        collectionView.layoutIfNeeded()

        emptyStateLabel.text = viewModel.emptyStateMessage
        emptyStateLabel.isHidden = viewModel.emptyStateMessage == nil
    }

    private func item(at indexPath: IndexPath?) -> VaultItem? {
        guard let indexPath, shownItems.indices.contains(indexPath.item) else { return nil }
        return shownItems[indexPath.item]
    }

    // MARK: - Routes

    private func go(to route: FileBrowserViewModel.Route) {
        switch route {
        case .folder(let folder):
            let browser = FileBrowserViewController(
                directory: folder, store: store, preferences: preferences, thumbnails: thumbnails,
                exporter: exporter, exportPresenter: exportPresenter, importPresenter: importPresenter,
                viewerFactory: viewerFactory, settingsFactory: settingsFactory)
            navigationController?.pushViewController(browser, animated: true)
        case .editor(let item):
            isEditorPresented = true
            present(viewerFactory.makeEditor(for: item), animated: true)
        case .viewer(let items, let index):
            present(viewerFactory.makeViewer(items: items, startingAt: index), animated: true)
        case .settings:
            present(settingsFactory.makeSettings(), animated: true)
        }
    }

    // MARK: - Bar button actions

    @objc private func settingsTapped() {
        viewModel.openSettings()
    }

    @objc private func sortTapped() {
        let sheet = UIAlertController(title: "Sort By", message: nil, preferredStyle: .actionSheet)
        for option in SortOption.allCases {
            var title = option.displayName
            if preferences.sortOption == option {
                title += preferences.sortDirection == .ascending ? " ↑" : " ↓"
            }
            sheet.addAction(
                UIAlertAction(title: title, style: .default) { [weak self] _ in
                    Task { await self?.viewModel.selectSort(option) }
                })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = sortButton
        present(sheet, animated: true)
    }

    @objc private func newFolderTapped() {
        presentNamePrompt(
            title: "New Folder", placeholder: "Folder name", fieldID: "browser.newFolderNameField"
        ) { [weak self] name in
            Task { await self?.viewModel.createFolder(named: name) }
        }
    }

    @objc private func newDocumentTapped() {
        presentNamePrompt(
            title: "New Document", placeholder: "Document name", fieldID: "browser.newDocumentNameField"
        ) { [weak self] name in
            Task { await self?.viewModel.createDocument(named: name) }
        }
    }

    @objc private func importTapped() {
        importPresenter.presentImportSheet(
            into: directory, from: self, anchor: .barButton(importButton),
            onLimitReached: { [weak self] in
                guard let self else { return }
                self.present(self.settingsFactory.makePaywall(onUnlock: {}), animated: true)
            },
            completion: { [weak self] in
                Task { await self?.viewModel.importCompleted() }
            })
    }

    @objc private func selectTapped() {
        viewModel.toggleSelectMode()
    }

    @objc private func bulkDeleteTapped() {
        let selected = viewModel.selectedItems
        guard !selected.isEmpty else { return }
        confirmDelete(selected)
    }

    @objc private func bulkMoveTapped() {
        let selected = viewModel.selectedItems
        guard !selected.isEmpty else { return }
        viewModel.beginMove(selected)
    }

    @objc private func bulkExportTapped() {
        let selected = viewModel.selectedItems
        guard !selected.isEmpty else { return }
        exportPresenter.presentExportSheet(for: selected, from: self, anchor: .barButton(bulkExportButton))
    }

    @objc private func bulkCopyTapped() {
        let selected = viewModel.selectedItems
        guard !selected.isEmpty else { return }
        Task { await viewModel.copy(selected) }
    }

    // MARK: - Prompts

    /// An alert with one text field, Cancel and Create; Create hands over the field's text.
    private func presentNamePrompt(
        title: String, placeholder: String, fieldID: String, onCreate: @escaping (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = placeholder
            field.accessibilityIdentifier = fieldID
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Create", style: .default) { [weak alert] _ in
                onCreate(alert?.textFields?.first?.text ?? "")
            })
        present(alert, animated: true)
    }

    private func presentRename(_ item: VaultItem) {
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        let prefill = viewModel.renamePrefill(for: item)
        alert.addTextField { field in
            field.text = prefill
            field.accessibilityIdentifier = "browser.renameField"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
                let name = alert?.textFields?.first?.text ?? ""
                Task { await self?.viewModel.rename(item, to: name) }
            })
        present(alert, animated: true)
    }

    private func confirmDelete(_ items: [VaultItem]) {
        let confirmation = viewModel.deleteConfirmation(for: items)
        let alert = UIAlertController(
            title: confirmation.title, message: confirmation.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                Task { await self?.viewModel.delete(items) }
            })
        present(alert, animated: true)
    }

    // MARK: - Folder picker

    /// Presents the picker now, or once the context menu it was asked from has closed (UIKit can't present
    /// a sheet while the menu is still dismissing).
    private func presentPickerWhenReady(for moving: [VaultItem]) {
        if isContextMenuShown {
            actionAfterContextMenu = { [weak self] in self?.presentPicker(for: moving) }
        } else {
            presentPicker(for: moving)
        }
    }

    private func presentPicker(for moving: [VaultItem]) {
        let picker = FolderPickerViewController(
            store: store, preferences: preferences, excluding: moving, directory: nil,
            onChoose: { [weak self] destination in
                self?.closePicker { await self?.viewModel.pickerChose(destination) }
            },
            onCancel: { [weak self] in
                self?.closePicker { self?.viewModel.pickerCancelled() }
            })
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .formSheet
        // A swipe-down closes the picker as Cancel does.
        navigation.presentationController?.delegate = self
        present(navigation, animated: true)
    }

    /// Dismisses the picker, then runs `then`, so an error it shows appears over this screen.
    private func closePicker(then: @escaping @MainActor () async -> Void) {
        guard presentedViewController != nil else {
            Task { await then() }
            return
        }
        dismiss(animated: true) {
            Task { await then() }
        }
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

extension FileBrowserViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        viewModel.pickerCancelled()
    }
}

// MARK: - UICollectionViewDataSource

extension FileBrowserViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        shownItems.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let dequeued = collectionView.dequeueReusableCell(withReuseIdentifier: FileCell.reuseID, for: indexPath)
        guard let cell = dequeued as? FileCell, let item = item(at: indexPath) else { return dequeued }
        cell.configure(with: item, thumbnails: thumbnails, folderAssetAvailable: folderAssetAvailable)
        cell.setSelected(
            viewModel.selectedItems.contains { $0.id == item.id }, inSelectMode: viewModel.isSelecting)
        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension FileBrowserViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = item(at: indexPath) else { return }
        if viewModel.isSelecting {
            viewModel.toggleSelection(of: item)
        } else {
            viewModel.open(item)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = item(at: indexPath) else { return nil }
        let actions = viewModel.contextActions(for: item)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let children = actions.compactMap { self?.menuAction($0, for: item, at: indexPath) }
            return UIMenu(title: item.name, children: children)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        isContextMenuShown = true
    }

    func collectionView(
        _ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        if let animator {
            animator.addCompletion { [weak self] in self?.contextMenuClosed() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.contextMenuClosed() }
        }
    }

    /// Runs what was waiting for the context menu to close.
    private func contextMenuClosed() {
        isContextMenuShown = false
        let action = actionAfterContextMenu
        actionAfterContextMenu = nil
        action?()
    }

    private func menuAction(
        _ action: FileBrowserViewModel.ContextAction, for item: VaultItem, at indexPath: IndexPath
    ) -> UIAction {
        switch action {
        case .export:
            return UIAction(
                title: "Export", image: UIImage(systemName: "square.and.arrow.up"),
                identifier: UIAction.Identifier("browser.contextMenu.export")
            ) { [weak self] _ in
                guard let self else { return }
                // The cell is gone if it scrolled away or the grid reloaded under the menu.
                let anchor: UIView = self.collectionView.cellForItem(at: indexPath) ?? self.collectionView
                self.exportPresenter.presentExportSheet(for: [item], from: self, anchor: .sourceView(anchor))
            }
        case .move:
            return UIAction(
                title: "Move", image: UIImage(systemName: "folder"),
                identifier: UIAction.Identifier("browser.contextMenu.move")
            ) { [weak self] _ in
                self?.viewModel.beginMove([item])
            }
        case .copy:
            return UIAction(
                title: "Copy", image: UIImage(systemName: "doc.on.doc"),
                identifier: UIAction.Identifier("browser.contextMenu.copy")
            ) { [weak self] _ in
                Task { await self?.viewModel.copy([item]) }
            }
        case .rename:
            return UIAction(
                title: "Rename", image: UIImage(systemName: "pencil"),
                identifier: UIAction.Identifier("browser.contextMenu.rename")
            ) { [weak self] _ in
                self?.presentRename(item)
            }
        case .delete:
            return UIAction(
                title: "Delete", image: UIImage(systemName: "trash"),
                identifier: UIAction.Identifier("browser.contextMenu.delete"), attributes: .destructive
            ) { [weak self] _ in
                self?.confirmDelete([item])
            }
        }
    }
}

// MARK: - Drag and drop

extension FileBrowserViewController {
    /// Whether a drop onto the item at `indexPath` (nil: empty space) is accepted: folder cells only.
    func dropTargetAllowed(at indexPath: IndexPath?) -> Bool {
        guard let target = item(at: indexPath) else { return false }
        return viewModel.canDrop(onto: target)
    }

    /// Drops `dragged` (nil for a drop from another app) onto the item at `indexPath`.
    func drop(_ dragged: VaultItem?, at indexPath: IndexPath) async {
        guard let target = item(at: indexPath) else { return }
        await viewModel.drop(dragged, onto: target)
    }

    /// The drag item for the cell at `indexPath`: its `localObject` is the `VaultItem`, and its provider
    /// offers the file to other apps only when the view model's drag-out rule allows it.
    func dragItems(at indexPath: IndexPath) -> [UIDragItem] {
        guard let item = item(at: indexPath) else { return [] }
        let provider = viewModel.canDragOut(item) ? NSItemProvider(object: item.diskURL as NSURL) : NSItemProvider()
        let dragItem = UIDragItem(itemProvider: provider)
        dragItem.localObject = item
        return [dragItem]
    }
}

extension FileBrowserViewController: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath
    ) -> [UIDragItem] {
        dragItems(at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dragSessionIsRestrictedToDraggingApplication session: UIDragSession
    ) -> Bool {
        session.items.contains { !viewModel.canDragOut($0.localObject as? VaultItem) }
    }
}

extension FileBrowserViewController: UICollectionViewDropDelegate {
    func collectionView(
        _ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard dropTargetAllowed(at: destinationIndexPath) else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let destination = coordinator.destinationIndexPath else { return }
        for dropItem in coordinator.items {
            let dragged = dropItem.dragItem.localObject as? VaultItem
            Task { [weak self] in await self?.drop(dragged, at: destination) }
            if dragged != nil {
                coordinator.drop(dropItem.dragItem, toItemAt: destination)
            }
        }
    }
}
