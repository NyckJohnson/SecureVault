import Combine
import UIKit

extension UIViewController {
    /// The controller a Settings screen presents from: the end of the `presentedViewController` chain of the
    /// outermost container (e.g. the navigation controller), skipping one that is already going away.
    private var settingsPresentationAnchor: UIViewController {
        var top: UIViewController = self
        while let parent = top.parent { top = parent }
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }

    /// Presents `controller` over everything this screen shows, once any presentation under way has finished
    /// (UIKit drops a presentation made while another is in progress). Settings presents its own alerts without
    /// animation, so an alert is fully up or gone before whatever its action shows next.
    func presentFromSettings(_ controller: UIViewController, animated: Bool) {
        let anchor = settingsPresentationAnchor
        if anchor.isBeingPresented, let coordinator = anchor.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.presentFromSettings(controller, animated: animated)
            }
            return
        }
        anchor.present(controller, animated: animated)
    }
}

extension UIAlertController {
    /// Adds an action that closes this alert, then runs `handler`. A tap has closed it already; this also
    /// covers an action run another way, so whatever the handler presents next isn't stacked on the alert.
    func addClosingAction(
        title: String, style: UIAlertAction.Style = .default, handler: @escaping @MainActor () -> Void = {}
    ) {
        addAction(
            UIAlertAction(title: title, style: style) { [weak self] _ in
                guard let self, self.presentingViewController != nil, !self.isBeingDismissed else {
                    handler()
                    return
                }
                // The alert stays alive until the handler has read its text fields.
                self.dismiss(animated: false) { withExtendedLifetime(self) { handler() } }
            })
    }
}

/// The security settings screen for the open vault: binds `SecuritySettingsViewModel` to its table and
/// prompts, and presents the paywall and Recently Deleted.
final class SecuritySettingsViewController: UIViewController, AlertPresenting {
    private enum Section {
        case pro, vault, storage
    }

    private enum VaultRow {
        case changePassword, biometrics, delete
    }

    private let lock: any VaultLocking
    private let store: any VaultStoring
    private let pro: any ProUnlocking
    private let onRestore: @MainActor () -> Void

    private lazy var viewModel = SecuritySettingsViewModel(
        lock: lock, pro: pro, alerts: self,
        onVaultDeleted: { [weak self] in self?.closeAfterDeletingVault() })
    private var subscriptions = Set<AnyCancellable>()
    private var proObservation: Task<Void, Never>?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let busyIndicator = UIActivityIndicatorView(style: .large)
    private let biometricSwitch = UISwitch()

    /// - Parameters:
    ///   - lock: the vaults; Settings is for `lock.current`.
    ///   - store: the open vault's store (Recently Deleted).
    ///   - pro: the "Unlock Pro" entitlement.
    ///   - onRestore: called after Recently Deleted restores an item, to refresh the browser.
    init(
        lock: any VaultLocking, store: any VaultStoring, pro: any ProUnlocking,
        onRestore: @escaping @MainActor () -> Void = {}
    ) {
        self.lock = lock
        self.store = store
        self.pro = pro
        self.onRestore = onRestore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        proObservation?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Security"
        view.backgroundColor = .systemBackground
        configureDoneButton()
        configureBiometricSwitch()
        configureTable()
        configureBusyIndicator()
        bindViewModel()
        proObservation = Task { [viewModel] in await viewModel.observeProUpdates() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.reload()
    }

    /// A "Done" button at the top right closes Settings: it dismisses the navigation controller Settings is
    /// presented in (and anything still shown over it). Swipe-down keeps working as before.
    private func configureDoneButton() {
        let done = UIBarButtonItem(
            title: "Done", style: .done, target: self, action: #selector(closeSettings))
        done.accessibilityIdentifier = "settingsDoneButton"
        navigationItem.rightBarButtonItem = done
    }

    @objc private func closeSettings() {
        let presented: UIViewController = navigationController ?? self
        presented.presentingViewController?.dismiss(animated: true)
    }

    /// The vault is gone: Settings is done. The shell's vault change also replaces the browser; closing
    /// here does nothing if that already took Settings away.
    private func closeAfterDeletingVault() {
        let presented: UIViewController = navigationController ?? self
        guard presented.presentingViewController != nil, !presented.isBeingDismissed else { return }
        presented.presentingViewController?.dismiss(animated: true)
    }

    private func configureBiometricSwitch() {
        biometricSwitch.accessibilityIdentifier = "settings.biometricSwitch"
        biometricSwitch.addTarget(self, action: #selector(biometricSwitchChanged), for: .valueChanged)
    }

    @objc private func biometricSwitchChanged() {
        let enabled = biometricSwitch.isOn
        Task { [viewModel] in await viewModel.setUsesBiometrics(enabled) }
    }

    private func configureTable() {
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.accessibilityIdentifier = "settings.table"
        view.addSubview(tableView)
    }

    private func configureBusyIndicator() {
        busyIndicator.hidesWhenStopped = true
        busyIndicator.accessibilityIdentifier = "settings.busyIndicator"
        busyIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(busyIndicator)
        var constraints: [NSLayoutConstraint] = []
        constraints.append(busyIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor))
        constraints.append(busyIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor))
        NSLayoutConstraint.activate(constraints)
    }

    private func bindViewModel() {
        // Fires before a change; the table is redrawn once the change is in place.
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadTable() }
            .store(in: &subscriptions)
        viewModel.$prompt
            .compactMap { $0 }
            .sink { [weak self] prompt in self?.present(prompt) }
            .store(in: &subscriptions)
        viewModel.$isBusy
            .removeDuplicates()
            .sink { [weak self] isBusy in self?.showBusy(isBusy) }
            .store(in: &subscriptions)
    }

    /// Redraws the rows at once. Cells left over from before keep no identifier.
    private func reloadTable() {
        for cell in tableView.visibleCells { cell.accessibilityIdentifier = nil }
        tableView.reloadData()
        tableView.layoutIfNeeded()
    }

    private func showBusy(_ isBusy: Bool) {
        view.isUserInteractionEnabled = !isBusy
        // Closing Settings mid-operation would drop its result alert.
        navigationItem.rightBarButtonItem?.isEnabled = !isBusy
        if isBusy {
            view.bringSubviewToFront(busyIndicator)
            busyIndicator.startAnimating()
        } else {
            busyIndicator.stopAnimating()
        }
    }

    // MARK: - Layout of the table

    private var sections: [Section] {
        viewModel.showsVaultSection ? [.pro, .vault, .storage] : [.pro, .storage]
    }

    private var vaultRows: [VaultRow] {
        viewModel.showsBiometricSwitch ? [.changePassword, .biometrics, .delete] : [.changePassword, .delete]
    }

    private func section(at index: Int) -> Section? {
        sections.indices.contains(index) ? sections[index] : nil
    }

    private func vaultRow(at index: Int) -> VaultRow? {
        vaultRows.indices.contains(index) ? vaultRows[index] : nil
    }

    // MARK: - Navigation

    private func showPaywall() {
        let paywall = PaywallViewController(pro: pro, onUnlock: {})
        paywall.modalPresentationStyle = .formSheet
        presentFromSettings(paywall, animated: true)
    }

    private func showRecentlyDeleted() {
        let controller = RecentlyDeletedViewController(store: store, onRestore: onRestore)
        navigationController?.pushViewController(controller, animated: true)
    }

    // MARK: - Prompts

    private func present(_ prompt: SecuritySettingsPrompt) {
        switch prompt {
        case .deleteVault:
            let alert = UIAlertController(
                title: SecuritySettingsViewModel.deleteVaultTitle, message: viewModel.deleteVaultMessage,
                preferredStyle: .alert)
            addSecureField(to: alert, placeholder: "Password", identifier: "settings.deleteVaultPasswordField")
            alert.addClosingAction(title: "Cancel", style: .cancel) { [viewModel] in viewModel.cancelPrompt() }
            alert.addClosingAction(title: "Delete", style: .destructive) { [viewModel, weak alert] in
                let password = alert?.textFields?.first?.text ?? ""
                Task { await viewModel.confirmDeleteVault(password: password) }
            }
            presentFromSettings(alert, animated: false)
        }
    }

    private func addSecureField(to alert: UIAlertController, placeholder: String, identifier: String) {
        alert.addTextField { field in
            field.placeholder = placeholder
            field.isSecureTextEntry = true
            field.accessibilityLabel = placeholder
            field.accessibilityIdentifier = identifier
        }
    }

    private func promptChangePassword() {
        let alert = UIAlertController(title: "Change Password", message: nil, preferredStyle: .alert)
        addSecureField(to: alert, placeholder: "Current password", identifier: "settings.currentPasswordField")
        addSecureField(to: alert, placeholder: "New password", identifier: "settings.newPasswordField")
        addSecureField(to: alert, placeholder: "Confirm new password", identifier: "settings.confirmNewPasswordField")
        alert.addClosingAction(title: "Cancel", style: .cancel)
        alert.addClosingAction(title: "Change", style: .default) { [viewModel, weak alert] in
            let current = alert?.textFields?[0].text ?? ""
            let new = alert?.textFields?[1].text ?? ""
            let confirm = alert?.textFields?[2].text ?? ""
            Task { await viewModel.changePassword(current: current, new: new, confirm: confirm) }
        }
        presentFromSettings(alert, animated: false)
    }
}

// MARK: - UITableViewDataSource

extension SecuritySettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch self.section(at: section) {
        case .pro, .storage: 1
        case .vault: vaultRows.count
        case nil: 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch self.section(at: section) {
        case .vault: viewModel.vaultSectionTitle
        case .storage: "Storage"
        case .pro, nil: nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .default
        cell.accessibilityTraits = .button
        cell.textLabel?.textColor = .label
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        switch section(at: indexPath.section) {
        case .pro:
            configureProCell(cell)
        case .vault:
            configureVaultCell(cell, row: vaultRow(at: indexPath.row))
        case .storage:
            cell.textLabel?.text = "Recently Deleted"
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "settings.recentlyDeletedRow"
        case nil:
            break
        }
        return cell
    }

    private func configureProCell(_ cell: UITableViewCell) {
        cell.textLabel?.text = viewModel.proTitle
        cell.accessibilityIdentifier = "upgradeToProCell"
        if viewModel.isProUnlocked {
            cell.textLabel?.textColor = .secondaryLabel
            cell.accessoryType = .checkmark
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
        } else {
            cell.textLabel?.textColor = .systemBlue
            cell.accessoryType = .disclosureIndicator
        }
    }

    private func configureVaultCell(_ cell: UITableViewCell, row: VaultRow?) {
        switch row {
        case .changePassword?:
            cell.textLabel?.text = "Change Password"
            cell.textLabel?.textColor = .systemBlue
            cell.accessibilityIdentifier = "settings.changePasswordRow"
        case .biometrics?:
            cell.textLabel?.text = viewModel.biometricTitle
            cell.selectionStyle = .none
            cell.accessibilityTraits = .none
            biometricSwitch.isOn = viewModel.usesBiometrics
            biometricSwitch.accessibilityLabel = viewModel.biometricTitle
            cell.accessoryView = biometricSwitch
            cell.accessibilityIdentifier = "settings.biometricRow"
        case .delete?:
            cell.textLabel?.text = "Delete This Vault"
            cell.textLabel?.textColor = .systemRed
            cell.accessibilityIdentifier = "settings.deleteVaultRow"
        case nil:
            break
        }
    }
}

// MARK: - UITableViewDelegate

extension SecuritySettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch section(at: indexPath.section) {
        case .pro:
            guard !viewModel.isProUnlocked else { return }
            showPaywall()
        case .vault:
            switch vaultRow(at: indexPath.row) {
            case .changePassword?: promptChangePassword()
            case .delete?: viewModel.requestDeleteVault()
            case .biometrics?, nil: break
            }
        case .storage:
            showRecentlyDeleted()
        case nil:
            break
        }
    }
}

#if DEBUG
    /// Shows Settings once `prepare` has run (e.g. opening a vault on the mock), since Settings reads the open
    /// vault when it is made. Previews only.
    @MainActor
    private final class SettingsPreviewHost: UIViewController {
        private let prepare: @MainActor () async -> Void
        private let makeContent: @MainActor () -> UIViewController

        init(prepare: @escaping @MainActor () async -> Void, content: @escaping @MainActor () -> UIViewController) {
            self.prepare = prepare
            makeContent = content
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            Task {
                await prepare()
                let content = makeContent()
                addChild(content)
                content.view.frame = view.bounds
                content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(content.view)
                content.didMove(toParent: self)
            }
        }
    }

    /// Settings for the given mocks, in its navigation controller.
    @MainActor
    private func settingsPreview(
        lock: MockVaultLocking, pro: MockProUnlocking = MockProUnlocking(isUnlocked: false),
        openVault: Bool, afterShowing: @escaping @MainActor (SecuritySettingsViewController) -> Void = { _ in }
    ) -> UIViewController {
        SettingsPreviewHost(
            prepare: {
                if openVault { try? await lock.open(password: "correct horse") }
            },
            content: {
                let settings = SecuritySettingsViewController(lock: lock, store: lock.current.store, pro: pro)
                let navigation = UINavigationController(rootViewController: settings)
                Task { @MainActor in afterShowing(settings) }
                return navigation
            })
    }

    @available(iOS 17.0, *)
    #Preview("Settings: unencrypted vault (no Vault section)") {
        settingsPreview(lock: MockVaultLocking(), openVault: false)
    }

    @available(iOS 17.0, *)
    #Preview("Settings: encrypted vault, Face ID on") {
        settingsPreview(lock: MockVaultLocking(biometricVaultID: "primary"), openVault: true)
    }

    @available(iOS 17.0, *)
    #Preview("Settings: encrypted vault, Pro unlocked") {
        settingsPreview(
            lock: MockVaultLocking(), pro: MockProUnlocking(isUnlocked: true), openVault: true)
    }

    @available(iOS 17.0, *)
    #Preview("Settings: encrypted vault, no biometrics") {
        settingsPreview(lock: MockVaultLocking(biometricKind: .none, biometricsAvailable: false), openVault: true)
    }

    @available(iOS 17.0, *)
    #Preview("Settings: busy (deleting the vault)") {
        let lock = MockVaultLocking()
        return settingsPreview(lock: lock, openVault: true) { settings in
            // Swaps in a lock whose calls never return, after the vault is open, so Settings stays busy.
            settings.previewStartBusy(lock: PreviewStalledLock(wrapping: lock))
        }
    }

    extension SecuritySettingsViewController {
        /// Previews only: runs a deletion on a lock that never answers, so the busy state stays on screen.
        fileprivate func previewStartBusy(lock stalled: PreviewStalledLock) {
            let busyModel = SecuritySettingsViewModel(lock: stalled, pro: pro, alerts: self, onVaultDeleted: {})
            busyModel.$isBusy
                .removeDuplicates()
                .sink { [weak self] isBusy in self?.showBusy(isBusy) }
                .store(in: &subscriptions)
            busyModel.requestDeleteVault()
            Task { await busyModel.confirmDeleteVault(password: "correct horse") }
        }
    }

    /// A lock that forwards to a `MockVaultLocking` but never finishes deleting a vault. Previews only.
    @MainActor
    private final class PreviewStalledLock: VaultLocking {
        private let base: MockVaultLocking

        init(wrapping base: MockVaultLocking) {
            self.base = base
        }

        var current: OpenVault { base.current }
        var unencryptedVault: OpenVault { base.unencryptedVault }
        var biometricKind: BiometricKind { base.biometricKind }
        var biometricsAvailable: Bool { base.biometricsAvailable }
        var hasBiometricVault: Bool { base.hasBiometricVault }
        var currentUsesBiometrics: Bool { base.currentUsesBiometrics }
        func currentUpdates() -> AsyncStream<OpenVault> { base.currentUpdates() }
        func upgradeIfNeeded() async throws { try await base.upgradeIfNeeded() }
        func canCreateVault() async -> Bool { await base.canCreateVault() }
        func createVault(name: String, password: String) async throws {
            try await base.createVault(name: name, password: password)
        }
        func open(password: String) async throws { try await base.open(password: password) }
        func openWithBiometrics() async throws { try await base.openWithBiometrics() }
        func close() { base.close() }
        func appWillResignActive() -> Bool { base.appWillResignActive() }
        func appDidEnterBackground() { base.appDidEnterBackground() }
        func changePassword(current: String, new: String) async throws {
            try await base.changePassword(current: current, new: new)
        }
        func setUsesBiometrics(_ enabled: Bool) async throws { try await base.setUsesBiometrics(enabled) }
        func deleteCurrentVault(password: String) async throws {
            try await Task.sleep(for: .seconds(3600))
        }
        func openTransferTarget(password: String) async throws -> OpenVault {
            try await base.openTransferTarget(password: password)
        }
        func closeTransferTarget(_ vault: OpenVault) { base.closeTransferTarget(vault) }
    }
#endif
