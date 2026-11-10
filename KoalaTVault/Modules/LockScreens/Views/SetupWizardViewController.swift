import Combine
import UIKit

/// The first-launch wizard: binds `SetupWizardViewModel` to the option cards, the password alert and the
/// progress overlay.
final class SetupWizardViewController: UIViewController, AlertPresenting {
    private let viewModel: SetupWizardViewModel
    private var subscriptions = Set<AnyCancellable>()
    private var overlay: ProgressOverlayView?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let optionsStack = UIStackView()
    private let continueButton = UIButton(type: .system)
    private var optionButtons: [SetupWizardOption: UIButton] = [:]

    /// - Parameter viewModel: the screen's logic and state.
    init(viewModel: SetupWizardViewModel) {
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

    private func configureViews() {
        titleLabel.text = "Welcome to Koala T Vault"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "setupWizard.titleLabel"

        subtitleLabel.text = "Choose how you want to protect your files"
        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        optionsStack.axis = .vertical
        optionsStack.spacing = 16
        addOption(
            .none, subtitle: "Files are not protected", systemImage: "lock.open",
            identifier: "setupWizard.noLockCard", action: #selector(selectNone))
        addOption(
            .password, subtitle: "Protect with a password", systemImage: "lock",
            identifier: "setupWizard.passwordCard", action: #selector(selectPassword))
        addOption(
            .passwordAndBiometrics, subtitle: "Password with biometric unlock", systemImage: "faceid",
            identifier: "setupWizard.biometricCard", action: #selector(selectBiometric))

        continueButton.setTitle("Continue", for: .normal)
        continueButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        continueButton.backgroundColor = .systemBlue
        continueButton.setTitleColor(.white, for: .normal)
        continueButton.layer.cornerRadius = 12
        continueButton.accessibilityIdentifier = "continueButton"
        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
    }

    private func addOption(
        _ option: SetupWizardOption,
        subtitle: String,
        systemImage: String,
        identifier: String,
        action: Selector
    ) {
        let button = UIButton(type: .system)
        button.layer.cornerRadius = 12
        button.layer.borderWidth = 2
        button.heightAnchor.constraint(equalToConstant: 80).isActive = true
        button.isEnabled = viewModel.isEnabled(option)
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)

        let icon = UIImageView(image: UIImage(systemName: systemImage))
        icon.tintColor = .systemBlue
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let titleText = UILabel()
        titleText.text = viewModel.title(for: option)
        titleText.font = .preferredFont(forTextStyle: .headline)

        let subtitleText = UILabel()
        subtitleText.text = subtitle
        subtitleText.font = .preferredFont(forTextStyle: .caption1)
        subtitleText.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [titleText, subtitleText])
        textStack.axis = .vertical
        textStack.spacing = 2

        let content = UIStackView(arrangedSubviews: [icon, textStack])
        content.axis = .horizontal
        content.spacing = 16
        content.alignment = .center
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(content)
        // Appends, not one literal: swift-format and swiftlint disagree on its trailing comma.
        var constraints: [NSLayoutConstraint] = []
        constraints.append(content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16))
        constraints.append(content.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16))
        constraints.append(content.centerYAnchor.constraint(equalTo: button.centerYAnchor))
        NSLayoutConstraint.activate(constraints)

        optionsStack.addArrangedSubview(button)
        optionButtons[option] = button
    }

    private func layOutViews() {
        for subview in [titleLabel, subtitleLabel, optionsStack, continueButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        // Appends, not one literal: swift-format and swiftlint disagree on its trailing comma.
        var constraints: [NSLayoutConstraint] = []
        constraints.append(titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60))
        constraints.append(titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24))
        constraints.append(titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24))
        constraints.append(subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16))
        constraints.append(subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24))
        constraints.append(subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24))
        constraints.append(optionsStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 48))
        constraints.append(optionsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24))
        constraints.append(optionsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24))
        constraints.append(
            continueButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32))
        constraints.append(continueButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24))
        constraints.append(continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24))
        constraints.append(continueButton.heightAnchor.constraint(equalToConstant: 50))
        NSLayoutConstraint.activate(constraints)
    }

    private func bindViewModel() {
        viewModel.$selectedOption
            .sink { [weak self] option in self?.showSelection(option) }
            .store(in: &subscriptions)
        viewModel.$isPasswordPromptVisible
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.presentPasswordPrompt() }
            .store(in: &subscriptions)
        viewModel.$isBusy
            .removeDuplicates()
            .sink { [weak self] isBusy in self?.showBusy(isBusy) }
            .store(in: &subscriptions)
        viewModel.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] message in self?.showError(message) }
            .store(in: &subscriptions)
    }

    private func showSelection(_ selected: SetupWizardOption) {
        for (option, button) in optionButtons {
            let isSelected = option == selected
            button.layer.borderColor = (isSelected ? UIColor.systemBlue : UIColor.systemGray4).cgColor
            button.backgroundColor =
                isSelected ? .systemBlue.withAlphaComponent(0.1) : .secondarySystemBackground
        }
    }

    /// No Lock finishes at once, so only the password modes show progress.
    private func showBusy(_ isBusy: Bool) {
        if isBusy, viewModel.selectedOption != .none {
            overlay = ProgressOverlayView.show(in: self, title: "Setting password…")
        } else if !isBusy {
            overlay?.dismiss()
            overlay = nil
        }
    }

    private func presentPasswordPrompt() {
        let alert = UIAlertController(title: "Set Password", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Password"
            $0.isSecureTextEntry = true
            $0.accessibilityIdentifier = "setupWizard.passwordField"
        }
        alert.addTextField {
            $0.placeholder = "Confirm password"
            $0.isSecureTextEntry = true
            $0.accessibilityIdentifier = "setupWizard.confirmPasswordField"
        }
        alert.addAction(
            UIAlertAction(title: "Cancel", style: .cancel) { [viewModel] _ in
                viewModel.cancelPasswordPrompt()
            })
        alert.addAction(
            UIAlertAction(title: "Set", style: .default) { [viewModel, weak alert] _ in
                let password = alert?.textFields?.first?.text ?? ""
                let confirmation = alert?.textFields?.last?.text ?? ""
                Task { await viewModel.submitPassword(password, confirmation: confirmation) }
            })
        present(alert, animated: true)
    }

    @objc private func selectNone() { viewModel.select(.none) }
    @objc private func selectPassword() { viewModel.select(.password) }
    @objc private func selectBiometric() { viewModel.select(.passwordAndBiometrics) }

    @objc private func continueTapped() {
        Task { [viewModel] in await viewModel.continueTapped() }
    }
}
