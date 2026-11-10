import Combine
import UIKit

/// The vault picker: binds `VaultPickerViewModel` to the "Unencrypted Vault" row, the password field, Use Vault,
/// Cancel and the error label (feature multiple-vaults-duress-password). The picker never dismisses itself:
/// whoever presented it does, in the view model's `onFinish`.
final class VaultPickerViewController: UIViewController {
    private let viewModel: VaultPickerViewModel
    private var subscriptions = Set<AnyCancellable>()

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let unencryptedButton = UIButton(type: .system)
    private let passwordHintLabel = UILabel()
    private let passwordField = UITextField()
    private let errorLabel = UILabel()
    private let useButton = UIButton(type: .system)
    private lazy var cancelItem = UIBarButtonItem(
        barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

    /// - Parameter viewModel: the screen's logic and state.
    init(viewModel: VaultPickerViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = viewModel.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The picker in a form-sheet navigation controller, ready to present.
    static func makeSheet(viewModel: VaultPickerViewModel) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: VaultPickerViewController(viewModel: viewModel))
        navigation.modalPresentationStyle = .formSheet
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureViews()
        layOutViews()
        bindViewModel()
    }

    private func configureViews() {
        cancelItem.accessibilityIdentifier = "vaultPicker.cancelButton"
        cancelItem.accessibilityLabel = "Cancel"
        navigationItem.leftBarButtonItem = cancelItem

        var unencrypted = UIButton.Configuration.tinted()
        unencrypted.title = "Unencrypted Vault"
        unencrypted.image = UIImage(systemName: "lock.open")
        unencrypted.imagePadding = 8
        unencrypted.buttonSize = .large
        unencrypted.titleTextAttributesTransformer = Self.headline
        unencryptedButton.configuration = unencrypted
        unencryptedButton.titleLabel?.adjustsFontForContentSizeCategory = true
        unencryptedButton.accessibilityLabel = "Unencrypted Vault"
        unencryptedButton.accessibilityIdentifier = "vaultPicker.unencryptedRow"
        unencryptedButton.isHidden = !viewModel.showsUnencryptedRow
        unencryptedButton.addTarget(self, action: #selector(unencryptedTapped), for: .touchUpInside)

        passwordHintLabel.text =
            viewModel.showsUnencryptedRow
            ? "Or enter the password of the vault to use." : "Enter the password of the vault to use."
        passwordHintLabel.font = .preferredFont(forTextStyle: .subheadline)
        passwordHintLabel.adjustsFontForContentSizeCategory = true
        passwordHintLabel.textColor = .secondaryLabel
        passwordHintLabel.numberOfLines = 0

        passwordField.placeholder = "Password"
        passwordField.isSecureTextEntry = true
        passwordField.textContentType = .password
        passwordField.borderStyle = .roundedRect
        passwordField.returnKeyType = .go
        passwordField.font = .preferredFont(forTextStyle: .body)
        passwordField.adjustsFontForContentSizeCategory = true
        passwordField.delegate = self
        passwordField.accessibilityLabel = "Password"
        passwordField.accessibilityIdentifier = "vaultPicker.passwordField"
        passwordField.addTarget(self, action: #selector(passwordEdited), for: .editingChanged)

        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "vaultPicker.errorLabel"

        var use = UIButton.Configuration.filled()
        use.title = "Use Vault"
        use.buttonSize = .large
        use.titleTextAttributesTransformer = Self.headline
        useButton.configuration = use
        useButton.titleLabel?.adjustsFontForContentSizeCategory = true
        useButton.accessibilityLabel = "Use Vault"
        useButton.accessibilityIdentifier = "vaultPicker.useButton"
        useButton.addTarget(self, action: #selector(useTapped), for: .touchUpInside)
    }

    private static let headline = UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.font = UIFont.preferredFont(forTextStyle: .headline)
        return attributes
    }

    private func layOutViews() {
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        for subview in [unencryptedButton, passwordHintLabel, passwordField, errorLabel, useButton] as [UIView] {
            stack.addArrangedSubview(subview)
        }
        stack.setCustomSpacing(24, after: unencryptedButton)
        stack.setCustomSpacing(8, after: passwordHintLabel)
        stack.setCustomSpacing(8, after: passwordField)

        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -24),
        ])
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
            .sink { [weak self] isBusy in self?.showBusy(isBusy) }
            .store(in: &subscriptions)
        viewModel.$errorMessage
            .sink { [weak self] message in
                self?.errorLabel.text = message
                self?.errorLabel.isHidden = message == nil
                if let message {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
            }
            .store(in: &subscriptions)
    }

    private func showBusy(_ isBusy: Bool) {
        let title = isBusy ? VaultPickerViewModel.busyMessage : "Use Vault"
        useButton.configuration?.title = title
        useButton.configuration?.showsActivityIndicator = isBusy
        useButton.accessibilityLabel = title
        useButton.isEnabled = !isBusy
        unencryptedButton.isEnabled = !isBusy
        passwordField.isEnabled = !isBusy
        cancelItem.isEnabled = !isBusy
    }

    @objc private func passwordEdited() {
        viewModel.passwordEdited(passwordField.text ?? "")
    }

    @objc private func unencryptedTapped() {
        viewModel.unencryptedTapped()
    }

    @objc private func useTapped() {
        Task { [viewModel] in await viewModel.useTapped() }
    }

    @objc private func cancelTapped() {
        viewModel.cancelTapped()
    }
}

extension VaultPickerViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        useTapped()
        return true
    }
}

#if DEBUG
    @available(iOS 17.0, *)
    #Preview("Vault Picker: from the unencrypted vault") {
        VaultPickerViewController.makeSheet(
            viewModel: VaultPickerViewModel(lock: MockVaultLocking(), isMove: true))
    }

    @available(iOS 17.0, *)
    #Preview("Vault Picker: from an encrypted vault") {
        let lock = MockVaultLocking(
            vaults: [
                MockVaultLocking.Vault(id: "primary", name: "My Vault", password: "correct horse"),
                MockVaultLocking.Vault(id: "second", name: "Travel", password: "battery staple"),
            ],
            isPro: true)
        let navigation = UINavigationController()
        Task {
            try? await lock.open(password: "correct horse")
            navigation.setViewControllers(
                [VaultPickerViewController(viewModel: VaultPickerViewModel(lock: lock, isMove: false))],
                animated: false)
        }
        return navigation
    }

    @available(iOS 17.0, *)
    #Preview("Vault Picker: error shown") {
        let viewModel = VaultPickerViewModel(lock: MockVaultLocking(), isMove: true)
        viewModel.passwordEdited("not a password")
        Task { await viewModel.useTapped() }
        return VaultPickerViewController.makeSheet(viewModel: viewModel)
    }
#endif
