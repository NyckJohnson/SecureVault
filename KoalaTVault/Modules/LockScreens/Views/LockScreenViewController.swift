import Combine
import UIKit

/// The lock screen: binds `LockScreenViewModel` to the password field, buttons and error label.
final class LockScreenViewController: UIViewController {
    private let viewModel: LockScreenViewModel
    private var subscriptions = Set<AnyCancellable>()

    private let logoImageView = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let titleLabel = UILabel()
    private let passwordField = UITextField()
    private let unlockButton = UIButton(type: .system)
    private let biometricButton = UIButton(type: .system)
    private let errorLabel = UILabel()

    /// - Parameter viewModel: the screen's logic and state.
    init(viewModel: LockScreenViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureViews()
        layOutViews()
        bindViewModel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if viewModel.focusesPasswordField {
            passwordField.becomeFirstResponder()
        }
    }

    private func configureViews() {
        logoImageView.tintColor = .systemBlue
        logoImageView.contentMode = .scaleAspectFit

        titleLabel.text = "KoalaTVault Locked"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "lockScreen.titleLabel"

        passwordField.placeholder = "Enter password"
        passwordField.isSecureTextEntry = true
        passwordField.borderStyle = .roundedRect
        passwordField.returnKeyType = .done
        passwordField.delegate = self
        passwordField.accessibilityIdentifier = "passwordField"
        passwordField.addTarget(self, action: #selector(passwordEdited), for: .editingChanged)

        unlockButton.setTitle("Unlock", for: .normal)
        unlockButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        unlockButton.accessibilityIdentifier = "unlockButton"
        unlockButton.addTarget(self, action: #selector(unlockTapped), for: .touchUpInside)

        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "lockScreen.errorLabel"

        biometricButton.setTitle(viewModel.biometricButtonTitle, for: .normal)
        biometricButton.isHidden = !viewModel.showsBiometricButton
        biometricButton.accessibilityIdentifier = "lockScreen.biometricButton"
        biometricButton.addTarget(self, action: #selector(biometricTapped), for: .touchUpInside)
    }

    private func layOutViews() {
        let subviews: [UIView] = [logoImageView, titleLabel, passwordField, unlockButton, errorLabel, biometricButton]
        for subview in subviews {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        // Preferred position; yields when the keyboard needs the space.
        let preferredLogoPosition = logoImageView.centerYAnchor.constraint(
            equalTo: view.centerYAnchor, constant: -160)
        // Must stay below compression resistance (750) so views move instead of collapsing.
        preferredLogoPosition.priority = .defaultHigh - 1

        // Appends, not one literal: swift-format and swiftlint disagree on its trailing comma.
        var constraints: [NSLayoutConstraint] = []
        constraints.append(logoImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor))
        constraints.append(preferredLogoPosition)
        constraints.append(logoImageView.widthAnchor.constraint(equalToConstant: 60))
        constraints.append(logoImageView.heightAnchor.constraint(equalToConstant: 60))
        constraints.append(titleLabel.topAnchor.constraint(equalTo: logoImageView.bottomAnchor, constant: 16))
        constraints.append(titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor))
        constraints.append(passwordField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 32))
        constraints.append(passwordField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40))
        constraints.append(passwordField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40))
        constraints.append(errorLabel.topAnchor.constraint(equalTo: passwordField.bottomAnchor, constant: 8))
        constraints.append(errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor))
        constraints.append(unlockButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 16))
        constraints.append(unlockButton.centerXAnchor.constraint(equalTo: view.centerXAnchor))
        constraints.append(biometricButton.topAnchor.constraint(equalTo: unlockButton.bottomAnchor, constant: 16))
        constraints.append(biometricButton.centerXAnchor.constraint(equalTo: view.centerXAnchor))
        constraints.append(
            biometricButton.bottomAnchor.constraint(
                lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -16))
        NSLayoutConstraint.activate(constraints)
    }

    private func bindViewModel() {
        viewModel.$password
            .sink { [weak self] password in
                // Only when it differs: resetting a secure field's text would disturb typing.
                guard let self, self.passwordField.text != password else { return }
                self.passwordField.text = password
            }
            .store(in: &subscriptions)
        viewModel.$isBusy
            .sink { [weak self] isBusy in self?.unlockButton.isEnabled = !isBusy }
            .store(in: &subscriptions)
        viewModel.$errorMessage
            .sink { [weak self] message in
                self?.errorLabel.text = message
                self?.errorLabel.isHidden = message == nil
            }
            .store(in: &subscriptions)
    }

    @objc private func passwordEdited() {
        viewModel.passwordEdited(passwordField.text ?? "")
    }

    @objc private func unlockTapped() {
        Task { [viewModel] in await viewModel.unlockTapped() }
    }

    @objc private func biometricTapped() {
        Task { [viewModel] in await viewModel.biometricTapped() }
    }
}

extension LockScreenViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        unlockTapped()
        return true
    }
}
