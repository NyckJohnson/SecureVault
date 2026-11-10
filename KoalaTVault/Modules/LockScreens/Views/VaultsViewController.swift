import Combine
import UIKit

/// The Vaults screen: binds `VaultsViewModel` to the password field, the buttons and the error label
/// (feature multiple-vaults-duress-password).
final class VaultsViewController: UIViewController {
    private let viewModel: VaultsViewModel
    private var subscriptions = Set<AnyCancellable>()
    private var observation: Task<Void, Never>?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let iconImageView = UIImageView(image: UIImage(systemName: "lock.rectangle.stack"))
    private let passwordField = UITextField()
    private let errorLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let biometricButton = UIButton(type: .system)
    private let createButton = UIButton(type: .system)
    private let closeVaultButton = UIButton(type: .system)
    private lazy var cancelItem = UIBarButtonItem(
        barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

    /// - Parameter viewModel: the screen's logic and state.
    init(viewModel: VaultsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Vaults"
        view.backgroundColor = .systemBackground
        configureViews()
        layOutViews()
        bindViewModel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard observation == nil else { return }
        observation = Task { [viewModel] in await viewModel.observeCurrentVault() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        passwordField.becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observation?.cancel()
        observation = nil
    }

    private func configureViews() {
        cancelItem.accessibilityIdentifier = "vaults.cancelButton"
        cancelItem.accessibilityLabel = "Cancel"
        navigationItem.leftBarButtonItem = cancelItem

        iconImageView.tintColor = .systemBlue
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle)
        iconImageView.isAccessibilityElement = false

        passwordField.placeholder = "Password"
        passwordField.isSecureTextEntry = true
        passwordField.textContentType = .password
        passwordField.borderStyle = .roundedRect
        passwordField.returnKeyType = .go
        passwordField.font = .preferredFont(forTextStyle: .body)
        passwordField.adjustsFontForContentSizeCategory = true
        passwordField.delegate = self
        passwordField.accessibilityLabel = "Password"
        passwordField.accessibilityIdentifier = "vaults.passwordField"
        passwordField.addTarget(self, action: #selector(passwordEdited), for: .editingChanged)

        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "vaults.errorLabel"

        configure(
            openButton, title: "Open", style: .filled(), identifier: "vaults.openButton",
            action: #selector(openTapped))
        configure(
            biometricButton, title: viewModel.biometricButtonTitle, style: .tinted(),
            identifier: "vaults.biometricButton", action: #selector(biometricTapped))
        configure(
            createButton, title: "Create New Vault", style: .plain(), identifier: "vaults.createButton",
            action: #selector(createTapped))
        configure(
            closeVaultButton, title: "Close Vault", style: .plain(), identifier: "vaults.closeVaultButton",
            action: #selector(closeVaultTapped))
        closeVaultButton.configuration?.baseForegroundColor = .systemRed
    }

    private func configure(
        _ button: UIButton,
        title: String,
        style: UIButton.Configuration,
        identifier: String,
        action: Selector
    ) {
        var configuration = style
        configuration.title = title
        configuration.buttonSize = .large
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func layOutViews() {
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        for subview in [
            iconImageView, passwordField, errorLabel, openButton, biometricButton, createButton, closeVaultButton,
        ] as [UIView] {
            stack.addArrangedSubview(subview)
        }
        stack.setCustomSpacing(8, after: passwordField)

        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        var constraints: [NSLayoutConstraint] = []
        constraints.append(scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor))
        constraints.append(scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor))
        constraints.append(scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor))
        constraints.append(scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor))
        constraints.append(stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 32))
        constraints.append(stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24))
        constraints.append(stack.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 24))
        constraints.append(stack.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -24))
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
        viewModel.$showsBiometricButton
            .sink { [weak self] shows in self?.biometricButton.isHidden = !shows }
            .store(in: &subscriptions)
        viewModel.$showsCloseVaultButton
            .sink { [weak self] shows in self?.closeVaultButton.isHidden = !shows }
            .store(in: &subscriptions)
    }

    private func showBusy(_ isBusy: Bool) {
        openButton.configuration?.title = isBusy ? VaultsViewModel.busyMessage : "Open"
        openButton.configuration?.showsActivityIndicator = isBusy
        openButton.accessibilityLabel = isBusy ? VaultsViewModel.busyMessage : "Open"
        for button in [openButton, biometricButton, createButton, closeVaultButton] {
            button.isEnabled = !isBusy
        }
        cancelItem.isEnabled = !isBusy
    }

    @objc private func passwordEdited() {
        viewModel.passwordEdited(passwordField.text ?? "")
    }

    @objc private func openTapped() {
        Task { [viewModel] in await viewModel.openTapped() }
    }

    @objc private func biometricTapped() {
        Task { [viewModel] in await viewModel.biometricTapped() }
    }

    @objc private func createTapped() {
        Task { [viewModel] in await viewModel.createTapped() }
    }

    @objc private func closeVaultTapped() {
        viewModel.closeVaultTapped()
    }

    @objc private func cancelTapped() {
        viewModel.cancelTapped()
    }
}

extension VaultsViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        openTapped()
        return true
    }
}

/// The live `VaultsScreenFactory`: the Vaults screen in a form-sheet navigation controller; Create New Vault
/// pushes the Create Vault screen.
@MainActor
final class LiveVaultsScreenFactory: VaultsScreenFactory {
    private let lock: any VaultLocking

    /// - Parameter lock: the app's vaults.
    init(lock: any VaultLocking) {
        self.lock = lock
    }

    func makeVaults(onNeedsPro: @escaping (UIViewController) -> Void) -> UIViewController {
        let viewModel = VaultsViewModel(lock: lock)
        let navigation = UINavigationController(rootViewController: VaultsViewController(viewModel: viewModel))
        navigation.modalPresentationStyle = .formSheet
        viewModel.onDone = { [weak navigation] in
            navigation?.dismiss(animated: true)
        }
        viewModel.onCreateVault = { [weak navigation, lock] in
            let createVault = CreateVaultViewController(viewModel: CreateVaultViewModel(lock: lock))
            navigation?.pushViewController(createVault, animated: true)
        }
        viewModel.onNeedsPro = { [weak navigation] in
            guard let navigation else { return }
            onNeedsPro(navigation)
        }
        return navigation
    }
}

#if DEBUG
    @available(iOS 17.0, *)
    #Preview("Vaults: unencrypted vault open") {
        LiveVaultsScreenFactory(lock: MockVaultLocking()).makeVaults(onNeedsPro: { _ in })
    }

    @available(iOS 17.0, *)
    #Preview("Vaults: encrypted vault open") {
        let lock = MockVaultLocking()
        Task { try? await lock.open(password: "correct horse") }
        return LiveVaultsScreenFactory(lock: lock).makeVaults(onNeedsPro: { _ in })
    }

    @available(iOS 17.0, *)
    #Preview("Vaults: Face ID available") {
        LiveVaultsScreenFactory(lock: MockVaultLocking(biometricVaultID: "primary"))
            .makeVaults(onNeedsPro: { _ in })
    }

    @available(iOS 17.0, *)
    #Preview("Vaults: error shown") {
        let viewModel = VaultsViewModel(lock: MockVaultLocking())
        viewModel.passwordEdited("not a password")
        Task { await viewModel.openTapped() }
        return UINavigationController(rootViewController: VaultsViewController(viewModel: viewModel))
    }
#endif
