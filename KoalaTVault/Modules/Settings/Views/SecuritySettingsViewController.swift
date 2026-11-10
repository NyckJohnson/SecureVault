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

/// The security settings screen: binds `SecuritySettingsViewModel` to its table and prompts, and presents the
/// paywall, the migration screen and Recently Deleted.
final class SecuritySettingsViewController: UIViewController, AlertPresenting {
    private enum Section: Int, CaseIterable {
        case pro, lockMode, password, storage
    }

    private enum LockModeRow: Int {
        case none, password, biometric, reencrypt
    }

    private let lock: any VaultLocking
    private let migrator: any LockMigrating
    private let store: any VaultStoring
    private let pro: any ProUnlocking
    private let onRestore: @MainActor () -> Void

    private lazy var viewModel = SecuritySettingsViewModel(
        lock: lock, migrator: migrator, store: store, pro: pro, alerts: self,
        onShowMigration: { [weak self] in self?.showMigration() })
    private var subscriptions = Set<AnyCancellable>()
    private var proObservation: Task<Void, Never>?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let busyIndicator = UIActivityIndicatorView(style: .large)

    /// - Parameters:
    ///   - lock: the app's vault lock.
    ///   - migrator: the app's one lock migration.
    ///   - store: the vault store (unencrypted-file check, trash).
    ///   - pro: the "Unlock Pro" entitlement.
    ///   - onRestore: called after Recently Deleted restores an item, to refresh the browser.
    init(
        lock: any VaultLocking, migrator: any LockMigrating, store: any VaultStoring, pro: any ProUnlocking,
        onRestore: @escaping @MainActor () -> Void = {}
    ) {
        self.lock = lock
        self.migrator = migrator
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
        configureTable()
        configureBusyIndicator()
        bindViewModel()
        proObservation = Task { [viewModel] in await viewModel.observeProUpdates() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { [viewModel] in await viewModel.reload() }
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
        // Closing Settings mid-operation would drop its result alert or the migration screen.
        navigationItem.rightBarButtonItem?.isEnabled = !isBusy
        if isBusy {
            view.bringSubviewToFront(busyIndicator)
            busyIndicator.startAnimating()
        } else {
            busyIndicator.stopAnimating()
        }
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

    /// Makes the migration screen (and so its view model) at once: the view model starts the migration
    /// as soon as this returns.
    private func showMigration() {
        let migration = MigrationViewController(
            kind: viewModel.migrationKind, migrator: migrator, waitsForNewRun: true,
            onFinish: { [weak self] completedFully in
                guard let viewModel = self?.viewModel else { return }
                Task { await viewModel.migrationFinished(completedFully: completedFully) }
            })
        presentFromSettings(migration, animated: true)
    }

    // MARK: - Prompts

    private func present(_ prompt: SecuritySettingsPrompt) {
        let alert: UIAlertController
        switch prompt {
        case .removeLock:
            alert = UIAlertController(
                title: SecuritySettingsViewModel.removeLockTitle, message: SecuritySettingsViewModel.removeLockMessage,
                preferredStyle: .alert)
            addCancelAction(to: alert)
            alert.addClosingAction(title: "Remove", style: .destructive) { [viewModel] in
                Task { await viewModel.confirmRemoveLock() }
            }
        case .newPassword:
            alert = UIAlertController(title: "Set Password", message: nil, preferredStyle: .alert)
            addSecureField(to: alert, placeholder: "Password", identifier: "settings.passwordField")
            addSecureField(to: alert, placeholder: "Confirm password", identifier: "settings.confirmPasswordField")
            addCancelAction(to: alert)
            alert.addClosingAction(title: "Set", style: .default) { [viewModel, weak alert] in
                let password = alert?.textFields?[0].text ?? ""
                let confirm = alert?.textFields?[1].text ?? ""
                Task { await viewModel.submitNewPassword(password, confirm: confirm) }
            }
        case .existingPassword:
            fatalError(
                "Not implemented: SecuritySettingsViewController existing-password prompt "
                    + "(feature multiple-vaults-duress-password)")
        }
        presentFromSettings(alert, animated: false)
    }

    private func addCancelAction(to alert: UIAlertController) {
        alert.addClosingAction(title: "Cancel", style: .cancel) { [viewModel] in viewModel.cancelPrompt() }
    }

    private func addSecureField(to alert: UIAlertController, placeholder: String, identifier: String) {
        alert.addTextField { field in
            field.placeholder = placeholder
            field.isSecureTextEntry = true
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
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .pro, .storage: 1
        case .lockMode: viewModel.showsReencrypt ? 4 : 3
        case .password: viewModel.showsChangePassword ? 1 : 0
        case nil: 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .lockMode: "Lock Mode"
        case .password: viewModel.showsChangePassword ? "Password" : nil
        case .storage: "Storage"
        case .pro, nil: nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.isUserInteractionEnabled = true
        cell.accessibilityTraits = .button
        cell.textLabel?.textColor = .label
        switch Section(rawValue: indexPath.section) {
        case .pro:
            configureProCell(cell)
        case .lockMode:
            configureLockModeCell(cell, row: LockModeRow(rawValue: indexPath.row))
        case .password:
            cell.textLabel?.text = "Change Password"
            cell.textLabel?.textColor = .systemBlue
            cell.accessibilityIdentifier = "settings.changePasswordRow"
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
        } else {
            cell.textLabel?.textColor = .systemBlue
            cell.accessoryType = .disclosureIndicator
        }
    }

    private func configureLockModeCell(_ cell: UITableViewCell, row: LockModeRow?) {
        let mode: LockMode
        switch row {
        case .none?:
            mode = .none
            cell.accessibilityIdentifier = "settings.lockMode.noLockRow"
        case .password?:
            mode = .password
            cell.accessibilityIdentifier = "settings.lockMode.passwordRow"
        case .biometric?:
            mode = .passwordAndBiometrics
            cell.accessibilityIdentifier = "settings.lockMode.biometricRow"
        case .reencrypt?:
            cell.textLabel?.text = "Re-encrypt Everything"
            cell.textLabel?.textColor = .systemBlue
            cell.accessibilityIdentifier = "settings.lockMode.reEncryptRow"
            return
        case nil:
            return
        }
        cell.textLabel?.text = viewModel.title(for: mode)
        cell.accessoryType = viewModel.currentMode == mode ? .checkmark : .none
        if !viewModel.isEnabled(mode) {
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            cell.isUserInteractionEnabled = false
            cell.accessibilityTraits = [.button, .notEnabled]
        }
    }
}

// MARK: - UITableViewDelegate

extension SecuritySettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .pro:
            guard !viewModel.isProUnlocked else { return }
            showPaywall()
        case .lockMode:
            switch LockModeRow(rawValue: indexPath.row) {
            case .none?: select(LockMode.none)
            case .password?: select(.password)
            case .biometric?: select(.passwordAndBiometrics)
            case .reencrypt?: Task { [viewModel] in await viewModel.reencryptEverything() }
            case nil: break
            }
        case .password:
            promptChangePassword()
        case .storage:
            showRecentlyDeleted()
        case nil:
            break
        }
    }

    private func select(_ mode: LockMode) {
        Task { [viewModel] in await viewModel.select(mode) }
    }
}
