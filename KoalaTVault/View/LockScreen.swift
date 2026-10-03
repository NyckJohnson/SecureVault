//
//  LockScreenViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit
import LocalAuthentication

final class LockScreenViewController: UIViewController {

    private let authService = AuthService.shared

    // MARK: - UI
    private let logoImageView    = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let titleLabel       = UILabel()
    private let passwordField    = UITextField()
    private let unlockButton     = UIButton(type: .system)
    private let biometricButton  = UIButton(type: .system)
    private let errorLabel       = UILabel()
    private var isAuthenticating = false

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard authService.lockMode == .passwordAndBiometrics else {
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

        biometricButton.setTitle("Use \(authService.biometricType)", for: .normal)
        biometricButton.addTarget(self, action: #selector(biometricButtonTapped), for: .touchUpInside)
        biometricButton.isHidden = authService.lockMode != .passwordAndBiometrics || !authService.biometricsAvailable
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

        // Preferred position; yields when the keyboard needs the space.
        let preferredLogoPosition = logoImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -160)
        preferredLogoPosition.priority = .defaultHigh - 1 // Must stay below compression resistance (750) so views move instead of collapsing

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
            biometricButton.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
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
        if let password {
            isAuthenticating = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    try self.authService.verifyPassword(password)
                    DispatchQueue.main.async {
                        self.isAuthenticating = false
                        self.unlockSucceeded()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isAuthenticating = false
                        if case AuthError.wrongPassword = error {
                            self.showError("Incorrect password")
                        } else {
                            self.showError(error.localizedDescription)
                        }
                    }
                }
            }
        } else {
            isAuthenticating = true
            authService.authenticateWithBiometrics { [weak self] success, error in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.unlockSucceeded()
                } else {
                    self.handleBiometricFailure(error)
                }
            }
        }
    }

    private func unlockSucceeded() {
        authService.didAuthenticate(in: view.window)
    }

    private func handleBiometricFailure(_ error: Error?) {
        guard let laError = error as? LAError else {
            showError("Biometric authentication failed")
            return
        }
        switch laError.code {
        case .userCancel, .userFallback, .systemCancel:
            break // user-initiated cancellation, not a failure — no error shown
        case .biometryNotEnrolled:
            showError("No Face ID/Touch ID set up on this device")
        case .biometryLockout:
            showError("Biometric authentication is locked — enter your password")
        case .passcodeNotSet:
            showError("Set a device passcode to use biometric authentication")
        default:
            showError("Biometric authentication failed")
        }
    }
    
    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        passwordField.text = ""
    }
}

extension LockScreenViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let password = passwordField.text, !password.isEmpty else { return true }
        attemptUnlock(with: password)
        return true
    }
}
