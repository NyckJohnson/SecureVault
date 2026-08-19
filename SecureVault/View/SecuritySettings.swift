//
//  SecuritySettingsViewController.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

final class SecuritySettingsViewController: UIViewController, ErrorPresenting {

    private let authService         = AuthService.shared
    private var tableView:            UITableView!
    private var hasUnencryptedFiles = false

    // MARK: - Sections
    private enum Section: Int, CaseIterable {
        case lockMode
        case password
        case trash
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Security"
        view.backgroundColor = .systemBackground
        setupTableView()
        refreshUnencryptedFilesState { [weak self] in
            self?.tableView.reloadData()
        }
    }

    private func refreshUnencryptedFilesState(completion: @escaping () -> Void = {}) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hasUnencrypted = (try? FileSystem.shared.filesToMigrate(toEncrypted: true, in: .root))?.isEmpty == false
            DispatchQueue.main.async {
                self?.hasUnencryptedFiles = hasUnencrypted
                completion()
            }
        }
    }

    private func setupTableView() {
        tableView = UITableView(frame: view.bounds, style: .insetGrouped)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        view.addSubview(tableView)
    }
}

// MARK: - UITableViewDataSource
extension SecuritySettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .lockMode: return showsReEncryptRow ? 4 : 3
        case .password: return authService.lockMode == .none ? 0 : 1
        case .trash: return 1
        }
    }

    private var showsReEncryptRow: Bool {
        authService.lockMode != .none && hasUnencryptedFiles
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
            case .lockMode: return "Lock Mode"
            case .password: return authService.lockMode == .none ? nil : "Password"
            case .trash: return "Storage"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.accessoryType = .none

        switch Section(rawValue: indexPath.section)! {
        case .lockMode:
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "No Lock"
                cell.accessoryType = authService.lockMode == .none ? .checkmark : .none
            case 1:
                cell.textLabel?.text = "Password"
                cell.accessoryType = authService.lockMode == .password ? .checkmark : .none
            case 2:
                cell.textLabel?.text = "Password + \(authService.biometricType)"
                cell.accessoryType = authService.lockMode == .passwordAndBiometrics ? .checkmark : .none
                cell.textLabel?.textColor = authService.biometricsAvailable ? .label : .secondaryLabel
            case 3:
                cell.textLabel?.text = "Re-encrypt Everything"
                cell.textLabel?.textColor = .systemBlue
            default: break
            }

        case .password:
            cell.textLabel?.text = "Change Password"
            cell.textLabel?.textColor = .systemBlue
            
        case .trash:
            cell.textLabel?.text = "Recently Deleted"
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }
}

// MARK: - UITableViewDelegate
extension SecuritySettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        switch Section(rawValue: indexPath.section)! {
        case .lockMode:
            switch indexPath.row {
            case 0: setLockMode(.none)
            case 1: setLockMode(.password)
            case 2:
                guard authService.biometricsAvailable else { return }
                setLockMode(.passwordAndBiometrics)
            case 3: reEncryptRemainingFiles()
            default: break
            }

        case .password:
            promptChangePassword()
            
        case .trash:
            let vc = RecentlyDeletedViewController()
            navigationController?.pushViewController(vc, animated: true)
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
        let migration = MigrationViewController(type: .decrypt) { completedFully in
            self.authService.finalizeMigration(type: .decrypt, targetLockMode: nil, completedFully: completedFully)
            self.refreshUnencryptedFilesState { self.tableView.reloadData() }
        }
        present(migration, animated: true)
    }

    private func setLockMode(_ mode: LockMode) {
        if mode == .none {
            let alert = UIAlertController(title: "Remove Lock?", message: "Your files will be decrypted and no longer protected.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
                guard let self else { return }
                let migration = MigrationViewController(type: .encrypt, targetLockMode: mode) { completedFully in
                    self.authService.finalizeMigration(type: .encrypt, targetLockMode: mode, completedFully: completedFully)
                    self.refreshUnencryptedFilesState { self.tableView.reloadData() }
                }
                self.present(migration, animated: true)
            })
            present(alert, animated: true)
        } else if !authService.hasPassword() {
            promptSetPassword(for: mode) { [weak self] in
                guard let self else { return }
                let migration = MigrationViewController(type: .encrypt, targetLockMode: authService.lockMode) { [weak self] completedFully in
                    guard let self else { return }
                    self.authService.finalizeMigration(type: .encrypt, targetLockMode: self.authService.lockMode, completedFully: completedFully)
                    self.refreshUnencryptedFilesState { self.tableView.reloadData() }
                }
                self.present(migration, animated: true)
            }
        } else {
            authService.lockMode = mode
            tableView.reloadData()
        }
    }

    private func promptSetPassword(for mode: LockMode, completion: @escaping () -> Void = {}) {
        let alert = UIAlertController(title: "Set Password", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Password"; $0.isSecureTextEntry = true }
        alert.addTextField { $0.placeholder = "Confirm password"; $0.isSecureTextEntry = true }
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
            do {
                try self.authService.setPassword(password)
                try CryptoService.shared.loadKey(from: password)
                completion()
            } catch {
                self.showError("Failed to save password")
            }
        })
        present(alert, animated: true)
    }

    private func promptChangePassword() {
        let alert = UIAlertController(title: "Change Password", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Current password"; $0.isSecureTextEntry = true }
        alert.addTextField { $0.placeholder = "New password"; $0.isSecureTextEntry = true }
        alert.addTextField { $0.placeholder = "Confirm new password"; $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Change", style: .default) { [weak self] _ in
            guard let self else { return }
            let current = alert.textFields?[0].text ?? ""
            let new     = alert.textFields?[1].text ?? ""
            let confirm = alert.textFields?[2].text ?? ""
            do {
                try self.authService.verifyPassword(current)
                guard !new.isEmpty else {
                    self.showError("New password cannot be empty")
                    return
                }
                guard new == confirm else {
                    self.showError("New passwords do not match")
                    return
                }
                try self.authService.setPassword(new)
                self.showSuccess("Password changed successfully")
            } catch AuthError.wrongPassword {
                self.showError("Current password is incorrect")
            } catch {
                self.showError("Failed to change password")
            }
        })
        present(alert, animated: true)
    }
}
