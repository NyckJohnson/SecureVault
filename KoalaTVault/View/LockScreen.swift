//
//  LegacyLockScreenViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

final class LegacyLockScreenViewController: UIViewController {

    private let vaultLock: any VaultLocking
    private let preferences: any PreferencesStoring
    private let onUnlocked: @MainActor (UIWindow?) -> Void

    // MARK: - UI
    private let logoImageView    = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let titleLabel       = UILabel()
    private let passwordField    = UITextField()
    private let unlockButton     = UIButton(type: .system)
    private let biometricButton  = UIButton(type: .system)
    private let errorLabel       = UILabel()
    private var isAuthenticating = false

    /// - Parameters:
    ///   - vaultLock: the app's vault lock, which unlocks with the password or biometrics.
    ///   - preferences: the app's settings (read for a pending encryption).
    ///   - onUnlocked: called with this screen's window after a successful unlock.
    init(
        vaultLock: any VaultLocking,
        preferences: any PreferencesStoring,
        onUnlocked: @escaping @MainActor (UIWindow?) -> Void
    ) {
        self.vaultLock = vaultLock
        self.preferences = preferences
        self.onUnlocked = onUnlocked
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard vaultLock.lockMode == .passwordAndBiometrics else {
            passwordField.becomeFirstResponder()
            return
        }
        if view.window?.windowScene?.activationState == .foregroundActive {
            attemptUnlock()
        } else {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate),
                                                   name: UIScene.didActivateNotification,
                                                   object: view.window?.windowScene)
        }
    }

    @objc private func sceneDidActivate() {
        NotificationCenter.default.removeObserver(self, name: UIScene.didActivateNotification, object: nil)
        attemptUnlock()
    }

    // MARK: - Setup
    private func setupUI() {
        logoImageView.tintColor = .systemBlue
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "KoalaTVault Locked"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        passwordField.placeholder = "Enter password"
        passwordField.isSecureTextEntry = true
        passwordField.borderStyle = .roundedRect
        passwordField.returnKeyType = .done
        passwordField.delegate = self
        passwordField.translatesAutoresizingMaskIntoConstraints = false

        unlockButton.setTitle("Unlock", for: .normal)
        unlockButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        unlockButton.addTarget(self, action: #selector(unlockButtonTapped), for: .touchUpInside)
        unlockButton.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        biometricButton.setTitle("Use \(vaultLock.biometricKind.legacyDisplayName)", for: .normal)
        biometricButton.addTarget(self, action: #selector(biometricButtonTapped), for: .touchUpInside)
        biometricButton.isHidden = vaultLock.lockMode != .passwordAndBiometrics || !vaultLock.biometricsAvailable
        biometricButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(logoImageView)
        view.addSubview(titleLabel)
        view.addSubview(passwordField)
        view.addSubview(unlockButton)
        view.addSubview(errorLabel)
        view.addSubview(biometricButton)
        
        // for ui tests
        passwordField.accessibilityIdentifier = "passwordField"
        unlockButton.accessibilityIdentifier = "unlockButton"
        titleLabel.accessibilityIdentifier = "lockScreen.titleLabel"
        biometricButton.accessibilityIdentifier = "lockScreen.biometricButton"
        errorLabel.accessibilityIdentifier = "lockScreen.errorLabel"

        // Preferred position; yields when the keyboard needs the space.
        let preferredLogoPosition = logoImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -160)
        // Must stay below compression resistance (750) so views move instead of collapsing
        preferredLogoPosition.priority = .defaultHigh - 1

        NSLayoutConstraint.activate([
            logoImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            preferredLogoPosition,
            logoImageView.widthAnchor.constraint(equalToConstant: 60),
            logoImageView.heightAnchor.constraint(equalToConstant: 60),

            titleLabel.topAnchor.constraint(equalTo: logoImageView.bottomAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            passwordField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 32),
            passwordField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            passwordField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            errorLabel.topAnchor.constraint(equalTo: passwordField.bottomAnchor, constant: 8),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            unlockButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 16),
            unlockButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            biometricButton.topAnchor.constraint(equalTo: unlockButton.bottomAnchor, constant: 16),
            biometricButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            biometricButton.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        ])
    }

    // MARK: - Actions
    @objc private func unlockButtonTapped() {
        guard let password = passwordField.text, !password.isEmpty else { return }
        attemptUnlock(with: password)
    }

    @objc private func biometricButtonTapped() {
        attemptUnlock()
    }
    
    private func attemptUnlock(with password: String? = nil) {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        if let password {
            // The vault lock refreshes the biometric item after a password unlock in biometric mode.
            Task { [weak self, vaultLock] in
                do {
                    try await vaultLock.unlock(password: password)
                    try await self?.addPendingLockIfNeeded(password: password)
                    self?.isAuthenticating = false
                    self?.unlockSucceeded()
                } catch {
                    self?.isAuthenticating = false
                    self?.showError((error as? VaultLockError)?.legacyMessage ?? error.localizedDescription)
                }
            }
        } else {
            Task { [weak self, vaultLock] in
                do {
                    try await vaultLock.unlockWithBiometrics()
                    self?.isAuthenticating = false
                    self?.unlockSucceeded()
                } catch {
                    self?.isAuthenticating = false
                    self?.handleBiometricFailure(error)
                }
            }
        }
    }

    /// An encryption interrupted by an older version can be pending with no lock mode saved (the lock mode
    /// was only written at the end). The password just verified adds the lock now, as adding a lock does
    /// before encrypting, so the vault is unlocked under the lock and the encryption can resume.
    private func addPendingLockIfNeeded(password: String) async throws {
        guard vaultLock.lockMode == .none, let pending = preferences.pendingMigration, pending.kind == .encrypt
        else { return }
        let mode: LockMode = pending.targetLockMode == .passwordAndBiometrics ? .passwordAndBiometrics : .password
        try await vaultLock.prepareToAddLock(mode: mode, password: password)
    }

    private func unlockSucceeded() {
        onUnlocked(view.window)
    }

    private func handleBiometricFailure(_ error: Error) {
        // A dismissed prompt is the user's choice, not a failure: no error shown.
        guard (error as? VaultLockError) != .biometricCancelled else { return }
        showError("Biometric authentication failed")
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        passwordField.text = ""
    }
}

extension LegacyLockScreenViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let password = passwordField.text, !password.isEmpty else { return true }
        attemptUnlock(with: password)
        return true
    }
}
