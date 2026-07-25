//
//  LockScreenViewController.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

final class LockScreenViewController: UIViewController {

    private let authService = AuthService.shared

    // MARK: - UI
    private let logoImageView   = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let titleLabel      = UILabel()
    private let passwordField   = UITextField()
    private let unlockButton    = UIButton(type: .system)
    private let biometricButton = UIButton(type: .system)
    private let errorLabel      = UILabel()

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if authService.lockMode == .passwordAndBiometrics {
            attemptUnlock()
        }
    }

    // MARK: - Setup
    private func setupUI() {
        logoImageView.tintColor = .systemBlue
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "SecureVault Locked"
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

        NSLayoutConstraint.activate([
            logoImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logoImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -160),
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
        if let password {
            do {
                try authService.verifyPassword(password)
                unlockSucceeded()
            } catch {
                showError("Incorrect password")
            }
        } else {
            authService.authenticateWithBiometrics { [weak self] success, _ in
                guard let self else { return }
                if success {
                    self.unlockSucceeded()
                } else {
                    self.showError("Biometric authentication failed")
                }
            }
        }
    }

    private func unlockSucceeded() {
        AuthService.shared.didAuthenticate(in: view.window)
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
