//
//  FileBrowserViewController.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit
import PhotosUI
import UniformTypeIdentifiers

final class FileBrowserViewController: UIViewController {
    
    // MARK: - Properties
    private let directory: URL
    private var items: [FileItem] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, FileItem>!
    private var itemPendingMove: FileItem?
    private var pendingAction: (() -> Void)?
    private var isSelectMode = false
    private var selectedItems: Set<FileItem> = []
    private var itemsPendingBulkAction: [FileItem]?
    
    // MARK: - Init
    init(directory: URL) {
        self.directory = directory
        super.init(nibName: nil, bundle: nil)
        self.title = directory.lastPathComponent
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
        
        NotificationCenter.default.addObserver(self, selector: #selector(triggerFolderPicker), name: NSNotification.Name("TriggerFolderPicker"), object: nil)
    }
    
    @objc private func triggerFolderPicker() {
        guard let item = itemPendingMove else { return }
        let picker = FolderPickerViewController(rootURL: FileStoreService.shared.rootURL, currentDirectory: FileStoreService.shared.rootURL)
        picker.delegate = self
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }
    
    //MARK: - Navigation Bar
    private func setupNavigationBar() {
        if isSelectMode {
            let cancel       = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(exitSelectMode))
            let deleteButton = UIBarButtonItem(image: UIImage(systemName: "trash"), style: .plain, target: self, action: #selector(bulkDelete))
                deleteButton.tintColor = .systemRed
            let moveButton   = UIBarButtonItem(image: UIImage(systemName: "arrow.right.circle"), style: .plain, target: self, action: #selector(bulkMove))
            let exportButton = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(bulkExport))
            let copyButton   = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain, target: self, action: #selector(bulkCopy))

            navigationItem.leftBarButtonItem = cancel
            navigationItem.title = selectedItems.isEmpty ? "Select Items" : "\(selectedItems.count) Selected"
            navigationItem.rightBarButtonItems = [deleteButton, moveButton, exportButton, copyButton]
        } else {
            if directory.path == FileStoreService.shared.rootURL.path {
                let settingsButton = UIBarButtonItem(image: UIImage(systemName: "gear"), style: .plain, target: self, action: #selector(openSettings))
                navigationItem.leftBarButtonItem = settingsButton
            } else {
                navigationItem.leftBarButtonItem = nil
            }
            
            let selectButton    = UIBarButtonItem(title: "Select", style: .plain, target: self, action: #selector(enterSelectMode))
            let importButton    = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain, target: self, action: #selector(promptImport))
            let newDocButton    = UIBarButtonItem(image: UIImage(systemName: "doc.badge.plus"), style: .plain, target: self, action: #selector(promptNewDocument))
            let newFolderButton = UIBarButtonItem(image: UIImage(systemName: "folder.badge.plus"), style: .plain, target: self, action: #selector(promptNewFolder))
            
            navigationItem.title = directory.lastPathComponent
            navigationItem.rightBarButtonItems = [newFolderButton, newDocButton, importButton, selectButton]
        }
    }
    
    //MARK: - Collection View Setup
    private func setupCollectionView() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.register(FileCell.self, forCellWithReuseIdentifier: FileCell.reuseID)
        view.addSubview(collectionView)
    }
    
    private func makeLayout() -> UICollectionViewLayout {
        let screenWidth   = view.bounds.width
        let minItemWidth: CGFloat = 100
        let count         = max(2, Int(screenWidth / minItemWidth))
        let itemWidth     = screenWidth / CGFloat(count)
        
        let itemSize          = NSCollectionLayoutSize(widthDimension: .absolute(itemWidth), heightDimension: .absolute(itemWidth * 1.4))
        let item              = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets    = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let groupSize         = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(itemWidth * 1.4))
        let group             = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        let section           = NSCollectionLayoutSection(group: group)
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
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FileCell.reuseID, for: indexPath) as! FileCell
            cell.configure(with: item, gridMode: true)
            cell.configure(with: item, gridMode: true)
            cell.setSelected(self.selectedItems.contains(item), inSelectMode: self.isSelectMode)
            return cell
        }
    }
    
    private func loadContents() {
        do {
            items = try FileStoreService.shared.contents(of: directory)
            applySnapshot()
        } catch {
            showError(error)
        }
    }
    
    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, FileItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        dataSource.apply(snapshot,animatingDifferences: true)
        collectionView.backgroundView = items.isEmpty ? emptyStateLabel() : nil
    }
    
    // MARK: - Actions
    @objc private func openSettings() {
        let settings = SecuritySettingsViewController()
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }
    
    @objc private func toggleViewMode() {
        collectionView.setCollectionViewLayout(makeLayout(), animated: true)
        setupNavigationBar()
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
    
    @objc private func promptNewFolder() {
        let alert = UIAlertController(title: "New Folder", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Folder name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            do {
                try FileStoreService.shared.createFolder(named: name, in: self.directory)
                self.loadContents()
            } catch {
                self.showError(error)
            }
        })
        present(alert, animated: true)
    }
    
    @objc private func promptNewDocument() {
        let alert = UIAlertController(title: "New Document", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Document name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self,
                  let name = alert.textFields?.first?.text,
                  !name.isEmpty else { return }
            let fileName = name.hasSuffix(".rtf") ? name : "\(name).rtf"
            let fileURL = self.directory.appendingPathComponent(fileName)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let editor = TextEditorViewController(fileURL: fileURL)
            let nav = UINavigationController(rootViewController: editor)
            nav.modalPresentationStyle = .fullScreen
            self.present(nav, animated: true) {
                self.loadContents()
            }
        })
        present(alert, animated: true)
    }
    
    // MARK: - Select Mode Actions
    @objc private func enterSelectMode() {
        isSelectMode = true
        selectedItems = []
        setupNavigationBar()
        collectionView.reloadData()
    }

    @objc private func exitSelectMode() {
        isSelectMode = false
        selectedItems = []
        setupNavigationBar()
        collectionView.reloadData()
    }
    
    // MARK: - Bulk Actions
    @objc private func bulkDelete() {
        guard !selectedItems.isEmpty else { return }
        let alert = UIAlertController(title: "Delete \(selectedItems.count) items?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            for item in self.selectedItems {
                try? FileStoreService.shared.delete(item)
            }
            self.exitSelectMode()
            self.loadContents()
        })
        present(alert, animated: true)
    }

    @objc private func bulkMove() {
        guard !selectedItems.isEmpty else { return }
        itemsPendingBulkAction = Array(selectedItems)
        presentFolderPicker(for: itemsPendingBulkAction!.first!)
    }

    @objc private func bulkExport() {
        guard !selectedItems.isEmpty else { return }
        ExportService.shared.exportMultiple(Array(selectedItems), from: self, barButtonItem: navigationItem.rightBarButtonItems?.first)
    }

    @objc private func bulkCopy() {
        guard !selectedItems.isEmpty else { return }
        for item in selectedItems {
            try? FileStoreService.shared.copy(item, to: directory)
        }
        exitSelectMode()
        loadContents()
    }
    
    // MARK: - Helpers
    private func emptyStateLabel() -> UILabel {
        let label = UILabel()
        label.text = "No files yet"
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        return label
    }
    
    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    private func promptRename(item: FileItem) {
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = item.name }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            do {
                try FileStoreService.shared.rename(item, to: name)
                self.loadContents()
            } catch {
                self.showError(error)
            }
        })
        present(alert, animated: true)
    }
    
    private func confirmDelete(item: FileItem) {
        let alert = UIAlertController(
            title: "Delete \"\(item.name)\"?",
            message: item.isDirectory ? "This will delete the folder and all its contents." : nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try FileStoreService.shared.delete(item)
                self.loadContents()
            } catch {
                self.showError(error)
            }
        })
        present(alert, animated: true)
    }
    
    // MARK: - Import
    @objc private func promptImport() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Choose Files", style: .default) { [weak self] _ in
            self?.presentFilePicker()
        })
        sheet.addAction(UIAlertAction(title: "Choose Folder", style: .default) { [weak self] _ in
            self?.presentFolderPickerForImport()
        })
        sheet.addAction(UIAlertAction(title: "Choose Photos", style: .default) { [weak self] _ in
            self?.presentPhotoPicker()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.last
        }

        present(sheet, animated: true)
    }
    
    private func presentFilePicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }
    
    private func presentFolderPickerForImport() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }
    
    private func presentFolderPicker(for item: FileItem) {
        itemPendingMove = item
        let picker = FolderPickerViewController(rootURL: FileStoreService.shared.rootURL, currentDirectory: FileStoreService.shared.rootURL)
        picker.delegate = self
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .formSheet
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let root = windowScene?.windows.first?.rootViewController
            root?.present(nav, animated: true)
        }
    }

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0 // 0 = unlimited
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }
}

// MARK: - UICollectionViewDelegates
extension FileBrowserViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let item = items[indexPath.item]

        if isSelectMode {
            if selectedItems.contains(item) {
                selectedItems.remove(item)
            } else {
                selectedItems.insert(item)
            }
            setupNavigationBar()
            if let cell = collectionView.cellForItem(at: indexPath) as? FileCell {
                cell.setSelected(selectedItems.contains(item), inSelectMode: true)
            }
            return
        }

        if item.isDirectory {
            let vc = FileBrowserViewController(directory: item.url)
            navigationController?.pushViewController(vc, animated: true)
        } else {
            let ext = item.url.pathExtension.lowercased()
            if ext == "rtf" {
                let editor = TextEditorViewController(fileURL: item.url)
                let nav    = UINavigationController(rootViewController: editor)
                nav.modalPresentationStyle = .fullScreen
                present(nav, animated: true)
            } else {
                let nonDirectories = items.filter { !$0.isDirectory }
                let startIndex = nonDirectories.firstIndex(where: { $0.id == item.id }) ?? 0
                let viewer = FileViewerViewController(items: nonDirectories, startingAt: startIndex)
                present(viewer, animated: true)
            }
        }
    }
    
    func collectionView(_ collectionView: UICollectionView,
                       contextMenuConfigurationForItemAt indexPath: IndexPath,
                       point: CGPoint) -> UIContextMenuConfiguration? {
        let item = items[indexPath.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let rename = UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.promptRename(item: item)
            }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "Trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmDelete(item: item)
            }
            let export = UIAction(title: "Export", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self else { return }
                let cell = collectionView.cellForItem(at: indexPath)
                ExportService.shared.export(item, from: self, sourceView: cell)
            }
            let move = UIAction(title: "Move", image: UIImage(systemName: "folder")) { [weak self] _ in
                guard let self else { return }
                self.itemPendingMove = item
                self.presentFolderPicker(for: item)
            }
            return UIMenu(title: item.name, children: [export, move, rename, delete])
        }
    }
    
    func collectionView(_ collectionView: UICollectionView,
                        willEndContextMenuInteraction configuration:
                        UIContextMenuConfiguration,
                        animator: (any UIContextMenuInteractionAnimating)?) {
        animator?.addCompletion {
            self.pendingAction?()
            self.pendingAction = nil
        }
    }
}

extension FileBrowserViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            do {
                try FileStoreService.shared.importFile(from: url, to: directory)
            } catch {
                showError(error)
            }
        }
        loadContents()
    }
}

extension FileBrowserViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        let group = DispatchGroup()
        for result in results {
            let provider = result.itemProvider
            guard let typeID = provider.registeredTypeIdentifiers.first,
                  let utType = UTType(typeID) else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, error in
                defer { group.leave() }
                guard let self, let url else { return }
                do {
                    try FileStoreService.shared.importFile(from: url, to: self.directory)
                } catch {
                    DispatchQueue.main.async { self.showError(error) }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.loadContents()
        }
    }
}

extension FileBrowserViewController: FolderPickerDelegate {
    func folderPicker(_ picker: FolderPickerViewController, didSelectFolder url: URL) {
        if let items = itemsPendingBulkAction {
            for item in items {
                try? FileStoreService.shared.move(item, to: url)
            }
            itemsPendingBulkAction = nil
            exitSelectMode()
        } else if let item = itemPendingMove {
            try? FileStoreService.shared.move(item, to: url)
            itemPendingMove = nil
        }
        loadContents()
    }
}

extension FileBrowserViewController: UICollectionViewDragDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        let item = items[indexPath.item]
        let provider = NSItemProvider(object: item.url as NSURL)
        let dragItem = UIDragItem(itemProvider: provider)
        dragItem.localObject = item
        return [dragItem]
    }
}

extension FileBrowserViewController: UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
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
            guard let draggedItem = item.dragItem.localObject as? FileItem else { continue }
            let destinationItem = items[destinationIndexPath.item]

            if destinationItem.isDirectory {
                // move into folder
                do {
                    try FileStoreService.shared.move(draggedItem, to: destinationItem.url)
                    loadContents()
                } catch {
                    showError(error)
                }
            } else {
                // reorder
                guard let sourceIndexPath = item.sourceIndexPath else { continue }
                do {
                    try FileStoreService.shared.reorder(
                        in: directory,
                        from: sourceIndexPath.item,
                        to: destinationIndexPath.item
                    )
                    loadContents()
                } catch {
                    showError(error)
                }
            }
            coordinator.drop(item.dragItem, toItemAt: destinationIndexPath)
        }
    }
}
