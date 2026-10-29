//
//  LegacySecuritySettingsViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

final class LegacySecuritySettingsViewController: UIViewController, AlertPresenting {

    private let vaultLock: any VaultLocking
    private let proUnlock: any ProUnlocking
    private let vaultStore: any VaultStoring
    private let lockMigrator: any LockMigrating
    private var tableView: UITableView!
    private var hasUnencryptedFiles = false
    private var entitlementObservation: Task<Void, Never>?

    /// - Parameters:
    ///   - vaultStore: the app's vault store (unencrypted-file check, trash).
    ///   - vaultLock: the app's vault lock (lock mode, password, biometrics).
    ///   - lockMigrator: the app's one lock migration, which adds and removes the lock's encryption.
    ///   - proUnlock: the "Unlock Pro" entitlement (the app's one, from the composition root, by default).
    init(
        vaultStore: any VaultStoring,
        vaultLock: any VaultLocking,
        lockMigrator: any LockMigrating,
        proUnlock: any ProUnlocking = LegacyStorage.current.proUnlock
    ) {
        self.vaultStore = vaultStore
        self.vaultLock = vaultLock
        self.lockMigrator = lockMigrator
        self.proUnlock = proUnlock
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        entitlementObservation?.cancel()
    }

    // MARK: - Sections
    private enum Section: Int, CaseIterable {
        case pro
        case lockMode
        case password
        case trash
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Security"
        view.backgroundColor = .systemBackground
        setupTableView()
        observeEntitlement()
        refreshUnencryptedFilesState { [weak self] in
            self?.tableView.reloadData()
        }
    }

    private func refreshUnencryptedFilesState(completion: @escaping @MainActor @Sendable () -> Void = {}) {
        Task { [weak self, vaultStore] in
            // Locked or unreadable counts as "nothing to re-encrypt", as before.
            let hasUnencrypted = (try? await vaultStore.hasUnencryptedFiles()) ?? false
            self?.hasUnencryptedFiles = hasUnencrypted
            completion()
        }
    }

    private func setupTableView() {
        tableView = UITableView(frame: view.bounds, style: .insetGrouped)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.accessibilityIdentifier = "settings.table"
        view.addSubview(tableView)
    }

    /// Reloads the Pro row on each change of the entitlement (the stream yields changes only).
    private func observeEntitlement() {
        let updates = proUnlock.unlockedUpdates()
        entitlementObservation = Task { [weak self] in
            for await _ in updates {
                self?.tableView.reloadSections(IndexSet(integer: Section.pro.rawValue), with: .none)
            }
        }
    }
}

// MARK: - UITableViewDataSource
extension LegacySecuritySettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let sectionKind = Section(rawValue: section) else { return 0 }
        switch sectionKind {
        case .pro: return 1
        case .lockMode: return showsReEncryptRow ? 4 : 3
        case .password: return vaultLock.lockMode == .none ? 0 : 1
        case .trash: return 1
        }
    }

    private var showsReEncryptRow: Bool {
        vaultLock.lockMode != .none && hasUnencryptedFiles
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionKind = Section(rawValue: section) else { return nil }
        switch sectionKind {
        case .pro: return nil
        case .lockMode: return "Lock Mode"
        case .password: return vaultLock.lockMode == .none ? nil : "Password"
        case .trash: return "Storage"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.accessibilityIdentifier = nil

        guard let sectionKind = Section(rawValue: indexPath.section) else { return cell }
        switch sectionKind {
        case .pro:
            cell.accessibilityIdentifier = "upgradeToProCell"
            if proUnlock.isUnlocked {
                cell.textLabel?.text = "Pro Unlocked"
                cell.textLabel?.textColor = .secondaryLabel
                cell.accessoryType = .checkmark
                cell.selectionStyle = .none
            } else {
                cell.textLabel?.text = "Upgrade to Pro"
                cell.textLabel?.textColor = .systemBlue
                cell.accessoryType = .disclosureIndicator
            }

        case .lockMode:
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "No Lock"
                cell.accessibilityIdentifier = "settings.lockMode.noLockRow"
                cell.accessoryType = vaultLock.lockMode == .none ? .checkmark : .none
            case 1:
                cell.textLabel?.text = "Password"
                cell.accessibilityIdentifier = "settings.lockMode.passwordRow"
                cell.accessoryType = vaultLock.lockMode == .password ? .checkmark : .none
            case 2:
                cell.textLabel?.text = "Password + \(vaultLock.biometricKind.legacyDisplayName)"
                cell.accessibilityIdentifier = "settings.lockMode.biometricRow"
                cell.accessoryType = vaultLock.lockMode == .passwordAndBiometrics ? .checkmark : .none
                cell.textLabel?.textColor = vaultLock.biometricsAvailable ? .label : .secondaryLabel
            case 3:
                cell.textLabel?.text = "Re-encrypt Everything"
                cell.accessibilityIdentifier = "settings.lockMode.reEncryptRow"
                cell.textLabel?.textColor = .systemBlue
            default: break
            }

        case .password:
            cell.textLabel?.text = "Change Password"
            cell.accessibilityIdentifier = "settings.changePasswordRow"
            cell.textLabel?.textColor = .systemBlue

        case .trash:
            cell.textLabel?.text = "Recently Deleted"
            cell.accessibilityIdentifier = "settings.recentlyDeletedRow"
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }
}

// MARK: - UITableViewDelegate
extension LegacySecuritySettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let sectionKind = Section(rawValue: indexPath.section) else { return }
        switch sectionKind {
        case .pro:
            guard !proUnlock.isUnlocked else { return }
            let paywall = LegacyPaywallViewController(proUnlock: proUnlock)
            paywall.modalPresentationStyle = .formSheet
            paywall.onUnlock = { [weak self] in self?.tableView.reloadData() }
            present(paywall, animated: true)

        case .lockMode:
            switch indexPath.row {
            case 0: setLockMode(.none)
            case 1: setLockMode(.password)
            case 2:
                guard vaultLock.biometricsAvailable else { return }
                setLockMode(.passwordAndBiometrics)
            case 3: reEncryptRemainingFiles()
            default: break
            }

        case .password:
            promptChangePassword()

        case .trash:
            let viewController = LegacyRecentlyDeletedViewController(vaultStore: vaultStore)
            navigationController?.pushViewController(viewController, animated: true)
        }
    }

#if DEBUG
    func testSetHasUnencryptedFiles(_ value: Bool) {
        hasUnencryptedFiles = value
        tableView.reloadData()
    }
    var testTableView: UITableView { tableView }
#endif

    private func reEncryptRemainingFiles() {
        // The lock is already on, so the encryption needs no target; a pending encrypt's target is kept.
        let pending = lockMigrator.pending
        let target = pending?.kind == .encrypt ? pending?.targetLockMode : nil
        let migration = LegacyMigrationViewController(
            type: .encrypt, migrator: lockMigrator,
            begin: { await $0.start(.encrypt, target: target) },
            onComplete: { [weak self] _ in
                self?.refreshUnencryptedFilesState { self?.tableView.reloadData() }
            })
        present(migration, animated: true)
    }

    private func setLockMode(_ mode: LockMode) {
        if mode == .none {
            let alert = UIAlertController(
                title: "Remove Lock?",
                message: "Your files will be decrypted and no longer protected.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
                guard let self else { return }
                // The migrator removes the keys and the lock once every file is decrypted; a failure there
                // shows on the Migration screen, and Skip keeps the lock and keys.
                let migration = LegacyMigrationViewController(
                    type: .decrypt, migrator: self.lockMigrator,
                    begin: { await $0.start(.decrypt, target: nil) },
                    onComplete: { [weak self] _ in
                        self?.refreshUnencryptedFilesState { self?.tableView.reloadData() }
                    })
                self.present(migration, animated: true)
            })
            present(alert, animated: true)
        } else if vaultLock.lockMode == .none {
            // Adding a lock from No Lock always asks for a password, even if a key blob from an earlier
            // install exists: the vault lock replaces it (empty vault) or checks it.
            // Password + Face ID: lock with the password and encrypt first, then enable Face ID, but only if
            // every file was encrypted. Otherwise (Skip with failed files) the vault stays Password with no
            // biometric item and the user is told why; after a kill the pending migration targets Password
            // and resumes on the next unlock.
            // If enabling Face ID fails, the vault stays locked with Password and the error shows.
            promptSetPassword(for: mode) { [weak self] in
                guard let self else { return }
                let migration = LegacyMigrationViewController(
                    type: .encrypt, migrator: self.lockMigrator,
                    begin: { await $0.start(.encrypt, target: .password) },
                    onComplete: { [weak self] completedFully in
                        guard let self else { return }
                        if mode == .passwordAndBiometrics {
                            if completedFully {
                                self.enableBiometricsAfterAddingLock()
                            } else {
                                self.showError(
                                    "Face ID wasn't turned on because some files aren't encrypted yet. "
                                        + "Use Re-encrypt Everything, then turn on Face ID."
                                )
                            }
                        }
                        self.refreshUnencryptedFilesState { self.tableView.reloadData() }
                    })
                self.present(migration, animated: true)
            }
        } else {
            // Password <-> Password + biometrics: the row shows the real mode afterwards, also on a failure.
            Task { [weak self, vaultLock] in
                do {
                    try await vaultLock.switchMode(to: mode)
                } catch {
                    self?.showError((error as? VaultLockError)?.legacyMessage ?? error.localizedDescription)
                }
                self?.tableView.reloadData()
            }
        }
    }

    /// Last step of adding Password + Face ID from No Lock: stores the biometric item and switches the
    /// lock mode. On failure the lock mode stays Password and the error shows.
    private func enableBiometricsAfterAddingLock() {
        Task { [weak self, vaultLock] in
            do {
                try await vaultLock.switchMode(to: .passwordAndBiometrics)
            } catch {
                self?.showError((error as? VaultLockError)?.legacyMessage ?? error.localizedDescription)
            }
            self?.tableView.reloadData()
        }
    }

    private func promptSetPassword(for mode: LockMode, completion: @escaping @MainActor @Sendable () -> Void = {}) {
        let alert = UIAlertController(title: "Set Password", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Password"; $0.isSecureTextEntry = true
            $0.accessibilityIdentifier = "settings.passwordField"
        }
        alert.addTextField {
            $0.placeholder = "Confirm password"; $0.isSecureTextEntry = true
            $0.accessibilityIdentifier = "settings.confirmPasswordField"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self] _ in
            guard let self else { return }
            let password = alert.textFields?[0].text ?? ""
            let confirm  = alert.textFields?[1].text ?? ""
            guard !password.isEmpty else {
                self.showError("Password cannot be empty")
                return
            }
            guard password == confirm else {
                self.showError("Passwords do not match")
                return
            }

            let overlay = ProgressOverlayView.show(in: self, title: "Setting password…")
            // Adds the lock with Password first; biometrics, if chosen, follow once every file is encrypted.
            Task { [weak self, vaultLock] in
                do {
                    try await vaultLock.prepareToAddLock(mode: .password, password: password)
                    overlay.dismiss()
                    completion()
                } catch {
                    overlay.dismiss()
                    self?.showError((error as? VaultLockError)?.legacyMessage ?? error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }

    private func promptChangePassword() {
        let alert = UIAlertController(title: "Change Password", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Current password"; $0.isSecureTextEntry = true
            $0.accessibilityIdentifier = "settings.currentPasswordField"
        }
        alert.addTextField {
            $0.placeholder = "New password"; $0.isSecureTextEntry = true
            $0.accessibilityIdentifier = "settings.newPasswordField"
        }
        alert.addTextField {
            $0.placeholder = "Confirm new password"; $0.isSecureTextEntry = true
            $0.accessibilityIdentifier = "settings.confirmNewPasswordField"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Change", style: .default) { [weak self] _ in
            guard let self else { return }
            let current = alert.textFields?[0].text ?? ""
            let new     = alert.textFields?[1].text ?? ""
            let confirm = alert.textFields?[2].text ?? ""
            guard !new.isEmpty else {
                self.showError("New password cannot be empty")
                return
            }
            guard new == confirm else {
                self.showError("New passwords do not match")
                return
            }

            let overlay = ProgressOverlayView.show(in: self, title: "Changing password…")
            Task { [weak self, vaultLock] in
                do {
                    try await vaultLock.changePassword(current: current, new: new)
                    overlay.dismiss()
                    self?.showSuccess("Password changed successfully")
                } catch VaultLockError.wrongPassword {
                    overlay.dismiss()
                    self?.showError("Current password is incorrect")
                } catch {
                    overlay.dismiss()
                    self?.showError((error as? VaultLockError)?.legacyMessage ?? error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }
}
