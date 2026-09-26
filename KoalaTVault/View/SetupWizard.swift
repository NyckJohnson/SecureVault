//
//  SetupWizardViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

final class SetupWizardViewController: UIViewController, ErrorPresenting {

    // MARK: - Properties
    private var selectedLockMode: LockMode = .none
    private let authService = AuthService.shared

    // MARK: - UI
    private let titleLabel      = UILabel()
    private let subtitleLabel   = UILabel()
    private let stackView       = UIStackView()
    private let noneButton      = UIButton(type: .system)
    private let passwordButton  = UIButton(type: .system)
    private let biometricButton = UIButton(type: .system)
    private let continueButton  = UIButton(type: .system)

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    // MARK: - Setup
    private func setupUI() {
        titleLabel.text = "Welcome to Koala T Vault"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.text = "Choose how you want to protect your files"
        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        setupOptionButton(noneButton, title: "No Lock", subtitle: "Files are not protected", systemImage: "lock.open")
        setupOptionButton(passwordButton, title: "Password", subtitle: "Protect with a password", systemImage: "lock")
        setupOptionButton(biometricButton, title: "Password + \(authService.biometricType)", subtitle: "Password with biometric unlock", systemImage: "faceid")
        biometricButton.isEnabled = authService.biometricsAvailable

        noneButton.addTarget(self, action: #selector(selectNone), for: .touchUpInside)
        passwordButton.addTarget(self, action: #selector(selectPassword), for: .touchUpInside)
        biometricButton.addTarget(self, action: #selector(selectBiometric), for: .touchUpInside)

        stackView.axis = .vertical
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(noneButton)
        stackView.addArrangedSubview(passwordButton)
        stackView.addArrangedSubview(biometricButton)

        continueButton.setTitle("Continue", for: .normal)
        continueButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        continueButton.backgroundColor = .systemBlue
        continueButton.setTitleColor(.white, for: .normal)
        continueButton.layer.cornerRadius = 12
        continueButton.addTarget(self, action: #selector(continueSetup), for: .touchUpInside)
        continueButton.translatesAutoresizingMaskIntoConstraints = false

        // for ui tests
        continueButton.accessibilityIdentifier = "continueButton"
        
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(stackView)
        view.addSubview(continueButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            stackView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 48),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            continueButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            continueButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            continueButton.heightAnchor.constraint(equalToConstant: 50),
        ])

        selectNone() // default selection
    }

    private func setupOptionButton(_ button: UIButton, title: String, subtitle: String, systemImage: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = 12
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor.systemGray4.cgColor
        button.backgroundColor = .secondarySystemBackground
        button.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let icon = UIImageView(image: UIImage(systemName: systemImage))
        icon.tintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let titleLbl = UILabel()
        titleLbl.text = title
        titleLbl.font = .preferredFont(forTextStyle: .headline)

        let subtitleLbl = UILabel()
        subtitleLbl.text = subtitle
        subtitleLbl.font = .preferredFont(forTextStyle: .caption1)
        subtitleLbl.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [titleLbl, subtitleLbl])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.isUserInteractionEnabled = false

        let hStack = UIStackView(arrangedSubviews: [icon, textStack])
        hStack.axis = .horizontal
        hStack.spacing = 16
        hStack.alignment = .center
        hStack.translatesAutoresizingMaskIntoConstraints = false
        hStack.isUserInteractionEnabled = false

        button.addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            hStack.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
            hStack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
    }

    // MARK: - Selection
    private func updateSelection() {
        [noneButton, passwordButton, biometricButton].forEach {
            $0.layer.borderColor = UIColor.systemGray4.cgColor
            $0.backgroundColor = .secondarySystemBackground
        }
        let selected: UIButton
        switch selectedLockMode {
        case .none:                  selected = noneButton
        case .password:              selected = passwordButton
        case .passwordAndBiometrics: selected = biometricButton
        }
        selected.layer.borderColor = UIColor.systemBlue.cgColor
        selected.backgroundColor = .systemBlue.withAlphaComponent(0.1)
    }

    @objc private func selectNone() {
        selectedLockMode = .none
        updateSelection()
    }

    @objc private func selectPassword() {
        selectedLockMode = .password
        updateSelection()
    }

    @objc private func selectBiometric() {
        selectedLockMode = .passwordAndBiometrics
        updateSelection()
    }

    // MARK: - Continue
    @objc private func continueSetup() {
        if selectedLockMode == .none {
            authService.lockMode = .none
            completeSetup()
        } else {
            promptSetPassword()
        }
    }

    private func promptSetPassword() {
        let alert = UIAlertController(title: "Set Password", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Password"
            $0.isSecureTextEntry = true
        }
        alert.addTextField {
            $0.placeholder = "Confirm password"
            $0.isSecureTextEntry = true
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
            do {
                try CryptoService.shared.createMasterKey(wrappedBy: password)
                self.authService.lockMode = self.selectedLockMode
                self.completeSetup()
            } catch {
                self.showError(error)
            }
        })
        present(alert, animated: true)
    }

    private func completeSetup() {
        PreferencesService.shared.hasCompletedSetup = true
        dismiss(animated: true)
    }
}
