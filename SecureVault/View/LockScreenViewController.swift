//
//  LockScreenViewController.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

protocol LockScreenDelegate: AnyObject {
    func lockScreenDidAuthenticate()
}

final class LockScreenViewController: UIViewController {

    weak var delegate: LockScreenDelegate?
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
            authenticateWithBiometrics()
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
        unlockButton.addTarget(self, action: #selector(unlockWithPassword), for: .touchUpInside)
        unlockButton.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        biometricButton.setTitle("Use \(authService.biometricType)", for: .normal)
        biometricButton.addTarget(self, action: #selector(authenticateWithBiometrics), for: .touchUpInside)
        biometricButton.isHidden = authService.lockMode != .passwordAndBiometrics || !authService.biometricsAvailable
        biometricButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(logoImageView)
        view.addSubview(titleLabel)
        view.addSubview(passwordField)
        view.addSubview(unlockButton)
        view.addSubview(errorLabel)
        view.addSubview(biometricButton)

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
    @objc private func unlockWithPassword() {
        guard let password = passwordField.text, !password.isEmpty else { return }
        do {
            try authService.verifyPassword(password)
            authService.isLocked = false
            delegate?.lockScreenDidAuthenticate()
        } catch {
            errorLabel.text = "Incorrect password"
            errorLabel.isHidden = false
            passwordField.text = ""
        }
    }

    @objc private func authenticateWithBiometrics() {
        authService.authenticateWithBiometrics { [weak self] success, _ in
            guard let self else { return }
            if success {
                self.authService.isLocked = false
                self.delegate?.lockScreenDidAuthenticate()
            } else {
                self.errorLabel.text = "Biometric authentication failed"
                self.errorLabel.isHidden = false
            }
        }
    }
}

// MARK: - UITextFieldDelegate
extension LockScreenViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        unlockWithPassword()
        return true
    }
}
