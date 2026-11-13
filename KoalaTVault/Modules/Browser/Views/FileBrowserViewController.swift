import Combine
import UIKit

/// The vault grid for one folder: binds `FileBrowserViewModel` to a collection view and the bar buttons, and
/// presents what the view model asks for (subfolder browsers, the viewer and editor, Settings, the folder
/// picker), the Import and Export flows, the Lock action, and Move/Copy to Vault through the vault picker
/// (feature multiple-vaults-duress-password). Every decision is the view model's.
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
    private let vaultServices: BrowserVaultServices

    private lazy var viewModel = FileBrowserViewModel(
        directory: directory, store: store, preferences: preferences, exporter: exporter, alerts: self,
        lock: vaultServices.lock, transfer: vaultServices.transfer)

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
    private let emptyStateLabel = UILabel()

    private lazy var settingsButton = makeButton(
        image: "gear", id: "settingsButton", action: #selector(settingsTapped))
    /// The title row under the navigation bar: the back arrow, then the folder's name (memo, Browser "Bar
    /// layout"). Pinned above the grid, so it does not scroll.
    private let titleRow = UIStackView()
    private let nameLabel = UILabel()
    /// "<" (Back, pops one folder) in a subfolder; "< lock" (Lock, calls `onLock`) on a vault's root.
    private lazy var arrowButton = BrowserTitleArrow(showsLock: viewModel.showsLockButton)
    private lazy var sortButton = makeButton(
        image: "arrow.up.arrow.down", id: "sortButton", action: #selector(sortTapped))
    private lazy var newFolderButton = makeButton(
        image: "folder.badge.plus", id: "newFolderButton", action: #selector(newFolderTapped))
    private lazy var newDocumentButton = makeButton(
        image: "doc.badge.plus", id: "browser.newDocumentButton", action: #selector(newDocumentTapped))
    private lazy var importButton = makeButton(
        image: "square.and.arrow.down", id: "importButton", action: #selector(importTapped))
    private lazy var selectButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Select", style: .plain, target: self, action: #selector(selectTapped))
        button.accessibilityIdentifier = "selectButton"
        return button
    }()
    /// Shown only in select mode, in place of the Select button; leaves select mode.
    private lazy var cancelSelectButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            title: "Cancel", style: .plain, target: self, action: #selector(cancelSelectTapped))
        button.accessibilityIdentifier = "browser.cancelSelectButton"
        return button
    }()
    private lazy var bulkDeleteButton: UIBarButtonItem = {
        let button = makeButton(image: "trash", id: "browser.bulkDeleteButton", action: #selector(bulkDeleteTapped))
        button.tintColor = .systemRed
        return button
    }()
    private lazy var bulkMoveButton = makeButton(
        image: "arrow.right.circle", id: "browser.bulkMoveButton", action: #selector(bulkMoveTapped))
    private lazy var bulkExportButton = makeButton(
        image: "square.and.arrow.up", id: "browser.bulkExportButton", action: #selector(bulkExportTapped))
    private lazy var bulkCopyButton = makeButton(
        image: "doc.on.doc", id: "browser.bulkCopyButton", action: #selector(bulkCopyTapped))
    private lazy var bulkVaultButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            title: "To Vault", style: .plain, target: self, action: #selector(bulkVaultTapped))
        button.accessibilityIdentifier = "browser.bulkVaultButton"
        return button
    }()
    /// The transfer's progress overlay while one runs.
    private var transferOverlay: ProgressOverlayView?

    /// The items the grid shows: the view model's items as of the last render, so the grid's counts and
    /// cells always agree with each other.
    private var shownItems: [VaultItem] = []
    /// Whether the bundle has the folder image the icons prefer.
    private let folderAssetAvailable: Bool
    private var hasAppeared = false
    /// The navigation controller whose edge-swipe back gesture this browser answers for, and the gesture's
    /// delegate from before any browser took it over (put back when this browser leaves the stack).
    private weak var popGestureNavigation: UINavigationController?
    private weak var originalPopGestureDelegate: UIGestureRecognizerDelegate?
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
    ///   - vaultServices: the app's vaults, the transfer and the Lock action, for the Lock button and
    ///     Move/Copy to Vault.
    init(
        directory: VaultDirectory, store: any VaultStoring, preferences: any PreferencesStoring,
        thumbnails: any ThumbnailProviding, exporter: any VaultExporting, exportPresenter: ExportPresenter,
        importPresenter: ImportPresenter, viewerFactory: any ViewerFactory, settingsFactory: any SettingsFactory,
        vaultServices: BrowserVaultServices
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
        self.vaultServices = vaultServices
        let folderIcon = FileIconMapping.icon(for: .other, isDirectory: true, folderAssetAvailable: true)
        self.folderAssetAvailable = UIImage(named: folderIcon.symbolName) != nil
        super.init(nibName: nil, bundle: nil)
        // Bar layout: no bar title or large title and no system back button; the title row's arrow is the
        // way back (the edge-swipe back gesture stays, see `viewWillAppear`).
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.hidesBackButton = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setUpTitleRow()
        setUpCollectionView()
        layOutTitleRowAndGrid()
        bindViewModel()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Hiding the system back button turns off the edge-swipe back gesture's default rule; this browser
        // answers for it while it is on screen (see `gestureRecognizerShouldBegin`).
        installPopGestureDelegate()
        if !hasAppeared {
            hasAppeared = true
            Task { [weak self] in await self?.viewModel.load() }
        } else if isEditorPresented {
            isEditorPresented = false
            Task { [weak self] in await self?.viewModel.editorClosed() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        restorePopGestureDelegateIfRemoved()
    }

    /// Makes this browser the edge-swipe gesture's delegate, remembering the system's own delegate. When
    /// another browser holds it, that browser's remembered original is inherited, so every browser in the
    /// stack points at the system's delegate, never at another browser.
    private func installPopGestureDelegate() {
        guard let navigation = navigationController,
            let gesture = navigation.interactivePopGestureRecognizer
        else { return }
        popGestureNavigation = navigation
        guard gesture.delegate !== self else { return }
        if let browser = gesture.delegate as? FileBrowserViewController {
            originalPopGestureDelegate = browser.originalPopGestureDelegate
        } else {
            originalPopGestureDelegate = gesture.delegate
        }
        gesture.delegate = self
    }

    /// Once this browser has left the stack for good, it hands the gesture back to the system's delegate,
    /// unless another browser has already taken it over (a pop makes the parent take it in `viewWillAppear`,
    /// before this runs).
    private func restorePopGestureDelegateIfRemoved() {
        guard let navigation = popGestureNavigation,
            !navigation.viewControllers.contains(self),
            let gesture = navigation.interactivePopGestureRecognizer,
            gesture.delegate === self
        else { return }
        gesture.delegate = originalPopGestureDelegate
        popGestureNavigation = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        matchTitleRowDirection()
    }

    /// A layout direction forced on the screen's view reaches the title row too, so the arrow stays on the
    /// name's reading-direction side and the chevron points backward.
    private func matchTitleRowDirection() {
        let attribute = view.semanticContentAttribute
        guard titleRow.semanticContentAttribute != attribute else { return }
        var views: [UIView] = [titleRow]
        while let next = views.popLast() {
            next.semanticContentAttribute = attribute
            views += next.subviews
        }
    }

    /// Lists the folder again; the browser factory calls this after unlock, a restore and a completed migration.
    func reload() {
        Task { [weak self] in await self?.viewModel.vaultUnlocked() }
    }

    private func setUpTitleRow() {
        nameLabel.font = Self.titleFont()
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.textAlignment = .natural
        nameLabel.accessibilityTraits = .header
        nameLabel.accessibilityIdentifier = "browser.titleLabel"
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        arrowButton.addTarget(self, action: #selector(arrowTapped), for: .touchUpInside)
        arrowButton.setContentHuggingPriority(.required, for: .horizontal)
        arrowButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 2
        titleRow.addArrangedSubview(arrowButton)
        titleRow.addArrangedSubview(nameLabel)
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleRow)
    }

    /// The large-title text style, bold like the system large title, scaling with Dynamic Type.
    private static func titleFont() -> UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle)
        let descriptor = base.withSymbolicTraits(.traitBold) ?? base
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// The title row under the bar, then the grid filling the rest of the screen below it.
    private func layOutTitleRowAndGrid() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        let margins = view.layoutMarginsGuide
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: safeArea.topAnchor),
            // Chevron 16 pt in (8 pt here + the arrow's 8 pt padding); fixed, so it never shifts mid-push.
            titleRow.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 8),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: margins.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: titleRow.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setUpCollectionView() {
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
        emptyStateLabel.accessibilityIdentifier = "browser.emptyStateLabel"
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
        viewModel.onPresentVaultPicker = { [weak self] isMove in
            self?.whenContextMenuClosed { self?.presentVaultPicker(isMove: isMove) }
        }
        viewModel.onTransferProgress = { [weak self] progress in self?.showTransferProgress(progress) }
        viewModel.onNeedsPro = { [weak self] in self?.presentPaywall() }
        // Fires before a change; render once the change is in place.
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
    }

    private func render() {
        nameLabel.text = viewModel.title
        // Select mode shows "Select Items" / "N Selected" in the row and hides the arrow. The arrow keeps its
        // place in the row (clear, untappable, out of VoiceOver) so the title does not jump left.
        let selecting = viewModel.isSelecting
        arrowButton.alpha = selecting ? 0 : 1
        arrowButton.isUserInteractionEnabled = !selecting
        arrowButton.accessibilityElementsHidden = selecting
        arrowButton.isAccessibilityElement = !selecting
        if viewModel.isSelecting {
            navigationItem.leftBarButtonItems = [cancelSelectButton]
            let bulkButtons = [bulkDeleteButton, bulkMoveButton, bulkExportButton, bulkCopyButton, bulkVaultButton]
            navigationItem.rightBarButtonItems = bulkButtons
            let hasSelection = !viewModel.selectedItems.isEmpty
            for button in bulkButtons {
                button.isEnabled = hasSelection
            }
        } else {
            var leftButtons: [UIBarButtonItem] = []
            if viewModel.showsSettingsButton { leftButtons.append(settingsButton) }
            navigationItem.leftBarButtonItems = leftButtons
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
                viewerFactory: viewerFactory, settingsFactory: settingsFactory, vaultServices: vaultServices)
            navigationController?.pushViewController(browser, animated: true)
        case .editor(let item):
            isEditorPresented = true
            present(viewerFactory.makeEditor(for: item), animated: true)
        case .viewer(let items, let index):
            present(viewerFactory.makeViewer(items: items, startingAt: index), animated: true)
        case .settings:
            present(settingsFactory.makeSettings(), animated: true)
        case .lock:
            vaultServices.onLock()
        }
    }

    /// Presents the paywall over this screen.
    private func presentPaywall() {
        present(settingsFactory.makePaywall(onUnlock: {}), animated: true)
    }

    // MARK: - Bar button actions

    @objc private func settingsTapped() {
        viewModel.openSettings()
    }

    /// The title row's arrow: Lock on a vault's root, otherwise back to the parent folder.
    @objc private func arrowTapped() {
        if viewModel.showsLockButton {
            viewModel.lockTapped()
        } else {
            goBack()
        }
    }

    /// Pops to the parent folder. UIKit ignores a pop while a push is still running, so a tap during this
    /// browser's own push animation pops once the push ends.
    private func goBack() {
        guard let navigation = navigationController else { return }
        if let coordinator = navigation.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak navigation] _ in
                navigation?.popViewController(animated: true)
            }
        } else {
            navigation.popViewController(animated: true)
        }
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

    @objc private func cancelSelectTapped() {
        viewModel.cancelSelection()
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

    @objc private func bulkVaultTapped() {
        let selected = viewModel.selectedItems
        guard !selected.isEmpty else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: "Move to Vault…", style: .default) { [weak self] _ in
                self?.viewModel.beginVaultTransfer(selected, isMove: true)
            })
        sheet.addAction(
            UIAlertAction(title: "Copy to Vault…", style: .default) { [weak self] _ in
                self?.viewModel.beginVaultTransfer(selected, isMove: false)
            })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = bulkVaultButton
        present(sheet, animated: true)
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
        whenContextMenuClosed { [weak self] in self?.presentPicker(for: moving) }
    }

    /// Runs `action` now, or once the context menu on screen has closed.
    private func whenContextMenuClosed(_ action: @escaping () -> Void) {
        if isContextMenuShown {
            actionAfterContextMenu = action
        } else {
            action()
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

    // MARK: - Vault picker and transfer progress

    private func presentVaultPicker(isMove: Bool) {
        let pickerModel = VaultPickerViewModel(lock: vaultServices.lock, isMove: isMove)
        pickerModel.onFinish = { [weak self] target in
            self?.closePicker { await self?.viewModel.vaultPickerFinished(target) }
        }
        let sheet = VaultPickerViewController.makeSheet(viewModel: pickerModel)
        // A swipe-down closes the picker as Cancel does.
        sheet.presentationController?.delegate = self
        present(sheet, animated: true)
    }

    /// Shows, updates or (for nil) removes the "Moving…" / "Copying…" overlay.
    private func showTransferProgress(_ progress: FileBrowserViewModel.TransferProgress?) {
        guard let progress else {
            transferOverlay?.dismiss()
            transferOverlay = nil
            return
        }
        if transferOverlay == nil {
            transferOverlay = ProgressOverlayView.show(in: self, title: progress.title, status: progress.status)
        }
        transferOverlay?.update(progress: progress.fraction, status: progress.status)
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

extension FileBrowserViewController: UIGestureRecognizerDelegate {
    /// The edge-swipe back gesture runs only when there is a screen to go back to, no push or pop is still
    /// animating (an interactive pop started mid-transition corrupts the stack), and the top screen is not a
    /// browser in select mode. The answer is about the navigation controller's current top screen, which may
    /// be another browser or a viewer/editor pushed above this one.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation = popGestureNavigation ?? navigationController,
            gestureRecognizer === navigation.interactivePopGestureRecognizer
        else { return true }
        guard navigation.viewControllers.count > 1, navigation.transitionCoordinator == nil else { return false }
        if let top = navigation.topViewController as? FileBrowserViewController {
            return !top.viewModel.isSelecting
        }
        return true
    }
}

extension FileBrowserViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        viewModel.pickerCancelled()
        viewModel.vaultPickerCancelled()
    }
}

// MARK: - UICollectionViewDataSource

extension FileBrowserViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        shownItems.count
    }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
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

    /// One item gets its context menu; an empty or multi-item press gets none (there is no
    /// multi-item menu). The willDisplay/willEnd methods below serve this API as well.
    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let item = item(at: indexPath) else {
            return nil
        }
        let actions = viewModel.contextActions(for: item)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: item, actions: actions, at: indexPath)
        }
    }

    /// The context menu for the item at `indexPath`, or nil when there is no item there.
    /// The grid's context-menu configuration builds the same menu through `menu(for:actions:at:)`.
    func contextMenu(at indexPath: IndexPath) -> UIMenu? {
        guard let item = item(at: indexPath) else { return nil }
        return menu(for: item, actions: viewModel.contextActions(for: item), at: indexPath)
    }

    /// Builds the context menu for `item` from the view model's actions.
    private func menu(
        for item: VaultItem, actions: [FileBrowserViewModel.ContextAction], at indexPath: IndexPath
    ) -> UIMenu {
        UIMenu(title: item.name, children: actions.map { menuAction($0, for: item, at: indexPath) })
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
        case .moveToVault, .copyToVault:
            let isMove = action == .moveToVault
            return UIAction(
                title: isMove ? "Move to Vault…" : "Copy to Vault…",
                image: UIImage(systemName: isMove ? "arrow.right.square" : "plus.square.on.square"),
                identifier: UIAction.Identifier(
                    isMove ? "browser.contextMenu.moveToVault" : "browser.contextMenu.copyToVault")
            ) { [weak self] _ in
                self?.viewModel.beginVaultTransfer([item], isMove: isMove)
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

    func collectionView(
        _ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
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

/// What the browser needs for the Lock button and Move/Copy to Vault (feature multiple-vaults-duress-password):
/// the app's vaults, the transfer between them, and the Lock action the shell gives.
@MainActor
struct BrowserVaultServices {
    let lock: any VaultLocking
    let transfer: any VaultTransferring
    let onLock: () -> Void
}

#if DEBUG
    @available(iOS 17.0, *)
    #Preview("Browser: root of an encrypted vault, Lock button") {
        let store = MockVaultStoring(name: "Travel", isEncrypted: true)
        let exporter = MockVaultExporting()
        let lock = MockVaultLocking(
            vaults: [MockVaultLocking.Vault(id: "primary", name: "My Vault", password: "correct horse")], isPro: true)
        let browser = FileBrowserViewController(
            directory: store.root, store: store, preferences: MockPreferencesStoring(),
            thumbnails: MockThumbnailProviding(), exporter: exporter,
            exportPresenter: ExportPresenter(exporter: exporter),
            importPresenter: ImportPresenter(
                importer: MockVaultImporting(), cameraRoll: MockCameraRollDeleting(), store: store),
            viewerFactory: MockViewerFactory(), settingsFactory: MockSettingsFactory(),
            vaultServices: BrowserVaultServices(
                lock: lock, transfer: MockVaultTransferring(), onLock: {}))
        let navigation = UINavigationController(rootViewController: browser)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }
#endif
