//
//  LegacyFileBrowserViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit

final class LegacyFileBrowserViewController: UIViewController, AlertPresenting {

    // MARK: - Properties
    private let directory: VaultDirectory
    private let services: LegacyBrowserServices
    private var vaultStore: any VaultStoring { services.vaultStore }
    private var items: [VaultItem] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, VaultItem>!
    private var itemPendingMove: VaultItem?
    private var pendingAction: (() -> Void)?
    private var isSelectMode = false
    /// The multi-select, by item id: ids stay equal across listings, so the selection survives a reload
    /// (items whose content or date changed are new values but keep their id).
    private var selectedItemIDs: Set<VaultItem.ID> = []
    private var itemsPendingBulkAction: [VaultItem]?
    /// Bumped by each `loadContents`; a listing that finishes after a newer one started is dropped.
    private var loadGeneration = 0

    /// The selected items of the current listing, in listing order.
    private var selectedItems: [VaultItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    // MARK: - Init
    /// - Parameters:
    ///   - directory: the folder this screen lists.
    ///   - services: the vault store and the other services, from the composition root.
    init(directory: VaultDirectory, services: LegacyBrowserServices) {
        self.directory = directory
        self.services = services
        super.init(nibName: nil, bundle: nil)
        self.title = directory.name
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupNavigationBar()
        setupCollectionView()
        configureDataSource()
        loadContents()
        NotificationCenter.default.addObserver(self, selector: #selector(reloadAfterRestore), name: .fileRestored, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let tempFiles = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let totalSize = tempFiles.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)

#if DEBUG
        print("Temp files: \(tempFiles.count), total size: \(totalSize / 1024 / 1024)MB")
#endif
    }

    // MARK: - Navigation Bar
    private func setupNavigationBar() {
        if isSelectMode {
            let cancel = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(exitSelectMode))
            let deleteButton = UIBarButtonItem(
                image: UIImage(systemName: "trash"), style: .plain, target: self, action: #selector(bulkDelete))
            deleteButton.tintColor = .systemRed
            let moveButton = UIBarButtonItem(
                image: UIImage(systemName: "arrow.right.circle"), style: .plain, target: self, action: #selector(bulkMove))
            let exportButton = UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(bulkExport))
            let copyButton = UIBarButtonItem(
                image: UIImage(systemName: "doc.on.doc"), style: .plain, target: self, action: #selector(bulkCopy))

            navigationItem.leftBarButtonItem = cancel
            navigationItem.title = selectedItemIDs.isEmpty ? "Select Items" : "\(selectedItemIDs.count) Selected"
            navigationItem.rightBarButtonItems = [deleteButton, moveButton, exportButton, copyButton]

            // for ui tests
            cancel.accessibilityIdentifier       = "browser.cancelSelectButton"
            deleteButton.accessibilityIdentifier = "browser.bulkDeleteButton"
            moveButton.accessibilityIdentifier   = "browser.bulkMoveButton"
            exportButton.accessibilityIdentifier = "browser.bulkExportButton"
            copyButton.accessibilityIdentifier   = "browser.bulkCopyButton"
        } else {
            // Left side
            if directory.diskURL == vaultStore.root.diskURL {
                let settingsButton = UIBarButtonItem(
                    image: UIImage(systemName: "gear"), style: .plain, target: self, action: #selector(openSettings))
                navigationItem.leftBarButtonItem = settingsButton
            } else {
                navigationItem.leftBarButtonItem = nil
            }

            // Right side
            let selectButton    = UIBarButtonItem(title: "Select", style: .plain, target: self, action: #selector(enterSelectMode))
            let importButton    = UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.down"), style: .plain, target: self, action: #selector(promptImport))
            let newDocButton    = UIBarButtonItem(
                image: UIImage(systemName: "doc.badge.plus"), style: .plain, target: self, action: #selector(promptNewDocument))
            let newFolderButton = UIBarButtonItem(
                image: UIImage(systemName: "folder.badge.plus"), style: .plain, target: self, action: #selector(promptNewFolder))
            let sortButton      = UIBarButtonItem(
                image: UIImage(systemName: "arrow.up.arrow.down"), style: .plain, target: self, action: #selector(promptSort))

            navigationItem.title = directory.name
            navigationItem.rightBarButtonItems = [newFolderButton, newDocButton, importButton, sortButton, selectButton]

            // for ui tests
            navigationItem.leftBarButtonItem?.accessibilityIdentifier = "settingsButton"
            sortButton.accessibilityIdentifier      = "sortButton"
            newFolderButton.accessibilityIdentifier = "newFolderButton"
            importButton.accessibilityIdentifier    = "importButton"
            selectButton.accessibilityIdentifier    = "selectButton"
            newDocButton.accessibilityIdentifier    = "browser.newDocumentButton"
        }
    }

    // MARK: - Collection View Setup
    private func setupCollectionView() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.register(LegacyFileCell.self, forCellWithReuseIdentifier: LegacyFileCell.reuseID)
        view.addSubview(collectionView)

        // for ui tests
        collectionView.accessibilityIdentifier = "fileGrid"
    }

    private func makeLayout() -> UICollectionViewLayout {
        let sectionInset: CGFloat = 8
        let availableWidth = view.bounds.width - (sectionInset * 2)
        let minItemWidth: CGFloat = 100
        let count = max(2, Int(availableWidth / minItemWidth))
        let itemWidth = availableWidth / CGFloat(count)
        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(itemWidth), heightDimension: .absolute(itemWidth * 1.4))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(itemWidth * 1.4))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        return UICollectionViewCompositionalLayout(section: section)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { _ in
            self.collectionView.setCollectionViewLayout(self.makeLayout(), animated: true)
        }
    }

    // MARK: - Data Source
    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LegacyFileCell.reuseID, for: indexPath) as? LegacyFileCell else {
                fatalError("FileCell not registered for reuse ID \(LegacyFileCell.reuseID)")
            }
            if let self {
                cell.configure(with: item, gridMode: true, thumbnails: services.thumbnails)
                cell.setSelected(selectedItemIDs.contains(item.id), inSelectMode: isSelectMode)
            }
            cell.accessibilityIdentifier = "browser.cell.\(item.name)"
            return cell
        }
    }

    private func loadContents() {
        loadGeneration += 1
        let generation = loadGeneration
        let option = services.preferences.sortOption
        let direction = services.preferences.sortDirection
        let directory = directory
        let vaultStore = vaultStore
        Task { [weak self] in
            do {
                let listed = try await vaultStore.contents(of: directory, sortedBy: option, direction)
                guard let self, generation == self.loadGeneration else { return }
                self.items = listed
                // Keep the selection of items still listed; ids are stable across listings.
                self.selectedItemIDs.formIntersection(listed.map(\.id))
                if self.isSelectMode { self.setupNavigationBar() }
                self.applySnapshot()
            } catch {
                guard let self, generation == self.loadGeneration else { return }
                // Suppress errors while locked: the lock screen handles the locked state.
                guard self.services.vaultLock.state != .locked else { return }
                self.showError(error)
            }
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, VaultItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.backgroundView = items.isEmpty ? emptyStateLabel() : nil
    }

    func reloadAfterAuth() {
        loadContents()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reloadSections([0])
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    // MARK: - Actions
    @objc private func openSettings() {
        let settings = LegacySecuritySettingsViewController(
            vaultStore: vaultStore, vaultLock: services.vaultLock, lockMigrator: services.lockMigrator)
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    @objc private func promptNewFolder() {
        let alert = UIAlertController(title: "New Folder", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Folder name"
            $0.accessibilityIdentifier = "browser.newFolderNameField"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            Task {
                do {
                    _ = try await self.vaultStore.createFolder(named: name, in: self.directory)
                    self.loadContents()
                } catch {
                    self.showError(error)
                }
            }
        })
        present(alert, animated: true)
    }

    @objc private func promptNewDocument() {
        let alert = UIAlertController(title: "New Document", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Document name"
            $0.accessibilityIdentifier = "browser.newDocumentNameField"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self,
                  let name = alert.textFields?.first?.text,
                  !name.isEmpty else { return }
            Task {
                let vaultItem: VaultItem
                do {
                    vaultItem = try await self.vaultStore.createDocument(named: name, in: self.directory)
                } catch {
                    self.showError(error)
                    return
                }
                let editor = LegacyTextEditorViewController(item: vaultItem, vaultStore: self.vaultStore)
                let nav = UINavigationController(rootViewController: editor)
                nav.modalPresentationStyle = .fullScreen
                self.present(nav, animated: true) {
                    self.loadContents()
                }
            }
        })
        present(alert, animated: true)
    }

    // MARK: - Select Mode
    @objc private func enterSelectMode() {
        isSelectMode = true
        selectedItemIDs = []
        setupNavigationBar()
        collectionView.reloadData()
    }

    @objc private func exitSelectMode() {
        isSelectMode = false
        selectedItemIDs = []
        setupNavigationBar()
        collectionView.reloadData()
    }

    // MARK: - Bulk Actions
    @objc private func bulkDelete() {
        guard !selectedItemIDs.isEmpty else { return }
        let alert = UIAlertController(title: "Delete \(selectedItemIDs.count) items?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let itemsToDelete = self.selectedItems
            Task {
                for item in itemsToDelete {
                    try? await self.vaultStore.moveToTrash(item)
                }
                self.exitSelectMode()
                self.loadContents()
            }
        })
        present(alert, animated: true)
    }

    @objc private func bulkMove() {
        guard !selectedItemIDs.isEmpty else { return }
        let itemsToMove = selectedItems
        itemPendingMove = nil
        itemsPendingBulkAction = itemsToMove
        guard let firstItem = itemsToMove.first else { return }
        presentFolderPicker(for: firstItem)
    }

    @objc private func bulkExport() {
        guard !selectedItemIDs.isEmpty else { return }
        services.exportService.exportMultiple(selectedItems, from: self, barButtonItem: navigationItem.rightBarButtonItems?.first)
    }

    @objc private func bulkCopy() {
        guard !selectedItemIDs.isEmpty else { return }
        let itemsToCopy = selectedItems
        let directory = directory
        Task {
            for item in itemsToCopy {
                _ = try? await vaultStore.copy(item, to: directory)
            }
            exitSelectMode()
            loadContents()
        }
    }

    // MARK: - Helpers
    @objc private func reloadAfterRestore() {
        loadContents()
    }

    private func presentFolderPicker(for item: VaultItem) {
        let picker = LegacyFolderPickerViewController(
            rootDirectory: vaultStore.root, currentDirectory: vaultStore.root,
            vaultStore: vaultStore, preferences: services.preferences)
        picker.delegate = self
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .formSheet
        // Swipe-down dismissal clears the pending move like Cancel does.
        nav.presentationController?.delegate = self
        navigationController?.present(nav, animated: true)
    }
    
    @objc private func promptSort() {
        let sheet = UIAlertController(title: "Sort By", message: nil, preferredStyle: .actionSheet)

        let preferences = services.preferences
        for option in SortOption.allCases {
            let isCurrent = preferences.sortOption == option
            let direction = preferences.sortDirection
            let dirSymbol = direction == .ascending ? "↑" : "↓"
            let title = isCurrent ? "\(option.displayName) \(dirSymbol)" : option.displayName
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                if isCurrent {
                    // toggle direction if same option tapped
                    preferences.sortDirection = direction == .ascending ? .descending : .ascending
                } else {
                    preferences.sortOption = option
                    preferences.sortDirection = .ascending
                }
                self?.loadContents()
            })
        }

        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first(where: { $0.action == #selector(promptSort) })
        }
        present(sheet, animated: true)
    }

    private func emptyStateLabel() -> UILabel {
        let label = UILabel()
        label.text = "No files yet"
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.accessibilityIdentifier = "browser.emptyStateLabel"
        return label
    }

    private func promptRename(item: VaultItem) {
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.text = item.name
            $0.accessibilityIdentifier = "browser.renameField"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            Task {
                do {
                    _ = try await self.vaultStore.rename(item, to: name)
                    self.loadContents()
                } catch {
                    self.showError(error)
                }
            }
        })
        present(alert, animated: true)
    }

    private func confirmDelete(item: VaultItem) {
        let alert = UIAlertController(
            title: "Delete \"\(item.name)\"?",
            message: item.isDirectory ? "This will delete the folder and all its contents." : nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await self.vaultStore.moveToTrash(item)
                    self.loadContents()
                } catch {
                    self.showError(error)
                }
            }
        })
        present(alert, animated: true)
    }

    // MARK: - Import
    @objc private func promptImport() {
        services.importService.promptImport(
            into: directory, from: self, barButtonItem: navigationItem.rightBarButtonItems?.last
        ) { [weak self] in
            self?.loadContents()
        }
    }
}

// MARK: - UICollectionViewDelegate
extension LegacyFileBrowserViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let item = items[indexPath.item]

        if isSelectMode {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
            setupNavigationBar()
            if let cell = collectionView.cellForItem(at: indexPath) as? LegacyFileCell {
                cell.setSelected(selectedItemIDs.contains(item.id), inSelectMode: true)
            }
            return
        }

        if let subDir = item.asDirectory {
            let browser = LegacyFileBrowserViewController(directory: subDir, services: services)
            navigationController?.pushViewController(browser, animated: true)
        } else {
            let ext = (item.name as NSString).pathExtension.lowercased()
            if ext == "rtf" {
                let editor = LegacyTextEditorViewController(item: item, vaultStore: vaultStore)
                let nav = UINavigationController(rootViewController: editor)
                nav.modalPresentationStyle = .fullScreen
                present(nav, animated: true)
            } else {
                let nonDirectories = items.filter { !$0.isDirectory }
                let startIndex = nonDirectories.firstIndex(where: { $0.id == item.id }) ?? 0
                let viewer = LegacyFileViewerViewController(
                    items: nonDirectories, startingAt: startIndex,
                    vaultStore: vaultStore, videoAssets: services.videoAssets,
                    exportService: services.exportService)
                present(viewer, animated: true)
            }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let item = items[indexPath.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let rename = UIAction(
                title: "Rename", image: UIImage(systemName: "pencil"),
                identifier: UIAction.Identifier("browser.contextMenu.rename")
            ) { [weak self] _ in
                self?.promptRename(item: item)
            }
            let delete = UIAction(
                title: "Delete", image: UIImage(systemName: "trash"),
                identifier: UIAction.Identifier("browser.contextMenu.delete"), attributes: .destructive
            ) { [weak self] _ in
                self?.confirmDelete(item: item)
            }
            let export = UIAction(
                title: "Export", image: UIImage(systemName: "square.and.arrow.up"),
                identifier: UIAction.Identifier("browser.contextMenu.export")
            ) { [weak self] _ in
                guard let self else { return }
                let cell = collectionView.cellForItem(at: indexPath)
                self.services.exportService.export(item, from: self, sourceView: cell)
            }
            let move = UIAction(
                title: "Move", image: UIImage(systemName: "folder"),
                identifier: UIAction.Identifier("browser.contextMenu.move")
            ) { [weak self] _ in
                guard let self else { return }
                self.itemsPendingBulkAction = nil
                self.itemPendingMove = item
                self.pendingAction = { self.presentFolderPicker(for: item) }
            }
            let copy = UIAction(
                title: "Copy", image: UIImage(systemName: "doc.on.doc"),
                identifier: UIAction.Identifier("browser.contextMenu.copy")
            ) { [weak self] _ in
                guard let self else { return }
                Task {
                    do {
                        _ = try await self.vaultStore.copy(item, to: self.directory)
                        self.loadContents()
                    } catch {
                        self.showError(error)
                    }
                }
            }
            return UIMenu(title: item.name, children: [export, move, copy, rename, delete])
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        guard let action = pendingAction else { return }
        pendingAction = nil
        if let animator {
            animator.addCompletion { action() }
        } else {
            // animator is nil when UIKit skips the dismissal animation; present immediately.
            DispatchQueue.main.async { action() }
        }
    }
}

// MARK: - FolderPickerDelegate
extension LegacyFileBrowserViewController: FolderPickerDelegate {
    func folderPicker(_ picker: LegacyFolderPickerViewController, didSelectFolder directory: VaultDirectory) {
        let vaultStore = vaultStore
        if let items = itemsPendingBulkAction {
            itemsPendingBulkAction = nil
            Task {
                var errors: [Error] = []
                for item in items {
                    do {
                        try await vaultStore.move(item, to: directory)
                    } catch {
                        errors.append(error)
                    }
                }
                exitSelectMode()
                loadContents()
                // Bulk results report how many failed, with the first error.
                if let firstError = errors.first {
                    showError("\(errors.count) of \(items.count) failed. \(firstError.localizedDescription)")
                }
            }
        } else if let item = itemPendingMove {
            itemPendingMove = nil
            Task {
                do {
                    try await vaultStore.move(item, to: directory)
                } catch {
                    loadContents()
                    showError(error)
                    return
                }
                loadContents()
            }
        } else {
            loadContents()
        }
    }

    func folderPickerDidCancel(_ picker: LegacyFolderPickerViewController) {
        clearPendingMove()
    }

    /// One pending move at a time: cancelling the picker drops it (select mode and its selection stay).
    private func clearPendingMove() {
        itemPendingMove = nil
        itemsPendingBulkAction = nil
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate
extension LegacyFileBrowserViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        clearPendingMove()
    }
}

// MARK: - UICollectionViewDragDelegate
extension LegacyFileBrowserViewController: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        let item = items[indexPath.item]
        let provider = NSItemProvider(object: item.diskURL as NSURL)
        let dragItem = UIDragItem(itemProvider: provider)
        dragItem.localObject = item
        return [dragItem]
    }

    // The provider hands out the on-disk URL, which is ciphertext in an encrypted vault, so
    // such drags stay inside the app (move onto a folder); export goes through ExportService.
    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        session.items.contains { dragItem in
            guard let item = dragItem.localObject as? VaultItem else { return true }
            return services.exportService.needsDecryptedCopy(item)
        }
    }
}

// MARK: - UICollectionViewDropDelegate
extension LegacyFileBrowserViewController: UICollectionViewDropDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard let destinationIndexPath else {
            return UICollectionViewDropProposal(operation: .cancel)
        }
        let destinationItem = items[destinationIndexPath.item]
        if destinationItem.isDirectory {
            return UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
        } else {
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let destinationIndexPath = coordinator.destinationIndexPath else { return }
        for item in coordinator.items {
            guard let draggedItem = item.dragItem.localObject as? VaultItem else { continue }
            let destinationItem = items[destinationIndexPath.item]
            if let destDir = destinationItem.asDirectory {
                Task {
                    do {
                        try await vaultStore.move(draggedItem, to: destDir)
                        loadContents()
                    } catch {
                        showError(error)
                    }
                }
            }
            coordinator.drop(item.dragItem, toItemAt: destinationIndexPath)
        }
    }
}
