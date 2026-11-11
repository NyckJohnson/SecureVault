import Combine
import UIKit

/// The lock screen (the Vaults screen): a full-screen column with the app's icon and name, the password field,
/// Open, "Use <biometric>", "Open Unencrypted Vault" and "Create New Vault", bound to `VaultsViewModel`
/// (feature multiple-vaults-duress-password). No Cancel: a vault must be opened to leave it.
final class VaultsViewController: UIViewController {
    /// The column's widest width, so the screen reads well on iPad and in landscape.
    private static let maximumContentWidth: CGFloat = 420

    private let viewModel: VaultsViewModel
    private var subscriptions = Set<AnyCancellable>()

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let iconImageView = UIImageView(
        image: UIImage(named: "koalaT") ?? UIImage(systemName: "lock.shield.fill"))
    private let appNameLabel = UILabel()
    private let passwordField = UITextField()
    private let errorLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let biometricButton = UIButton(type: .system)
    private let unencryptedButton = UIButton(type: .system)
    private let createButton = UIButton(type: .system)

    /// - Parameter viewModel: the screen's logic and state.
    init(viewModel: VaultsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The back button title on Create Vault.
        title = "Vaults"
        view.backgroundColor = .systemBackground
        configureViews()
        layOutViews()
        bindViewModel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Create Vault, pushed over this screen, needs the bar for its back button.
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        passwordField.becomeFirstResponder()
    }

    private func configureViews() {
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.tintColor = .systemBlue
        iconImageView.layer.cornerRadius = 18
        iconImageView.layer.cornerCurve = .continuous
        iconImageView.clipsToBounds = true
        iconImageView.isAccessibilityElement = false

        appNameLabel.text = Self.appName
        appNameLabel.font = .preferredFont(forTextStyle: .largeTitle)
        appNameLabel.adjustsFontForContentSizeCategory = true
        appNameLabel.textAlignment = .center
        appNameLabel.numberOfLines = 0
        appNameLabel.accessibilityTraits = .header

        passwordField.placeholder = "Password"
        passwordField.isSecureTextEntry = true
        // No password content type: iOS must never offer to save or suggest a vault password.
        passwordField.textContentType = nil
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
            unencryptedButton, title: "Open Unencrypted Vault", style: .plain(),
            identifier: "vaults.unencryptedButton", action: #selector(unencryptedTapped))
        configure(
            createButton, title: "Create New Vault", style: .plain(), identifier: "vaults.createButton",
            action: #selector(createTapped))
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
            iconImageView, appNameLabel, passwordField, errorLabel, openButton, biometricButton, unencryptedButton,
            createButton,
        ] as [UIView] {
            stack.addArrangedSubview(subview)
        }
        stack.setCustomSpacing(8, after: iconImageView)
        stack.setCustomSpacing(32, after: appNameLabel)
        stack.setCustomSpacing(8, after: passwordField)
        stack.setCustomSpacing(32, after: biometricButton)
        stack.setCustomSpacing(4, after: unencryptedButton)

        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        let iconSize = UIFontMetrics(forTextStyle: .largeTitle).scaledValue(for: 88)

        // Centred vertically while it fits; the scroll view takes over when it doesn't (keyboard, large text).
        let centred = stack.centerYAnchor.constraint(equalTo: frame.centerYAnchor)
        centred.priority = .defaultLow
        // Full width up to the readable maximum.
        let fullWidth = stack.widthAnchor.constraint(equalTo: frame.widthAnchor, constant: -48)
        fullWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
            centred,
            stack.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumContentWidth),
            stack.widthAnchor.constraint(lessThanOrEqualTo: frame.widthAnchor, constant: -48),
            fullWidth,
            iconImageView.heightAnchor.constraint(equalToConstant: iconSize),
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
        viewModel.$showsBiometricButton
            .sink { [weak self] shows in self?.biometricButton.isHidden = !shows }
            .store(in: &subscriptions)
    }

    private func showBusy(_ isBusy: Bool) {
        openButton.configuration?.title = isBusy ? VaultsViewModel.busyMessage : "Open"
        openButton.configuration?.showsActivityIndicator = isBusy
        openButton.accessibilityLabel = isBusy ? VaultsViewModel.busyMessage : "Open"
        for button in [openButton, biometricButton, unencryptedButton, createButton] {
            button.isEnabled = !isBusy
        }
    }

    /// The app's name as the home screen shows it.
    private static var appName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "KoalaTVault"
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

    @objc private func unencryptedTapped() {
        viewModel.unencryptedTapped()
    }

    @objc private func createTapped() {
        Task { [viewModel] in await viewModel.createTapped() }
    }
}

extension VaultsViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        openTapped()
        return true
    }
}

/// The live `VaultsScreenFactory`: the lock screen in a full-screen navigation controller; Create New Vault pushes
/// the Create Vault screen. The presenter dismisses it when `onDone` is called.
@MainActor
final class LiveVaultsScreenFactory: VaultsScreenFactory {
    private let lock: any VaultLocking

    /// - Parameter lock: the app's vaults.
    init(lock: any VaultLocking) {
        self.lock = lock
    }

    func makeLockScreen(
        onDone: @escaping () -> Void,
        onNeedsPro: @escaping (UIViewController) -> Void
    ) -> UIViewController {
        let viewModel = VaultsViewModel(lock: lock)
        let navigation = UINavigationController(rootViewController: VaultsViewController(viewModel: viewModel))
        navigation.modalPresentationStyle = .fullScreen
        viewModel.onDone = { onDone() }
        viewModel.onCreateVault = { [weak navigation, lock] in
            let createViewModel = CreateVaultViewModel(lock: lock)
            createViewModel.onDone = { onDone() }
            createViewModel.onNeedsPro = { [weak navigation] in
                guard let navigation else { return }
                onNeedsPro(navigation)
            }
            navigation?.pushViewController(CreateVaultViewController(viewModel: createViewModel), animated: true)
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
    #Preview("Lock screen: no Face ID vault") {
        LiveVaultsScreenFactory(lock: MockVaultLocking()).makeLockScreen(onDone: {}, onNeedsPro: { _ in })
    }

    @available(iOS 17.0, *)
    #Preview("Lock screen: Face ID") {
        LiveVaultsScreenFactory(lock: MockVaultLocking(biometricVaultID: "primary"))
            .makeLockScreen(onDone: {}, onNeedsPro: { _ in })
    }

    @available(iOS 17.0, *)
    #Preview("Lock screen: busy") {
        let viewModel = VaultsViewModel(lock: PreviewSlowVaultLocking())
        viewModel.passwordEdited("correct horse")
        Task { await viewModel.openTapped() }
        return UINavigationController(rootViewController: VaultsViewController(viewModel: viewModel))
    }

    @available(iOS 17.0, *)
    #Preview("Lock screen: incorrect password") {
        let viewModel = VaultsViewModel(lock: MockVaultLocking())
        viewModel.passwordEdited("not a password")
        Task { await viewModel.openTapped() }
        return UINavigationController(rootViewController: VaultsViewController(viewModel: viewModel))
    }

    /// A preview-only `VaultLocking` whose open by password never finishes, so the lock screen stays on "Opening…";
    /// everything else is `MockVaultLocking`'s.
    @MainActor
    private final class PreviewSlowVaultLocking: VaultLocking {
        private let mock = MockVaultLocking()

        var current: OpenVault { mock.current }
        var unencryptedVault: OpenVault { mock.unencryptedVault }
        func currentUpdates() -> AsyncStream<OpenVault> { mock.currentUpdates() }
        var biometricKind: BiometricKind { mock.biometricKind }
        var biometricsAvailable: Bool { mock.biometricsAvailable }
        var hasBiometricVault: Bool { mock.hasBiometricVault }
        var currentUsesBiometrics: Bool { mock.currentUsesBiometrics }
        func upgradeIfNeeded() async throws { try await mock.upgradeIfNeeded() }
        func canCreateVault() async -> Bool { await mock.canCreateVault() }
        func createVault(name: String, password: String) async throws {
            try await mock.createVault(name: name, password: password)
        }
        func open(password: String) async throws {
            try await Task.sleep(for: .seconds(3600))
        }
        func openWithBiometrics() async throws { try await mock.openWithBiometrics() }
        func close() { mock.close() }
        func appWillResignActive() -> Bool { mock.appWillResignActive() }
        func appDidEnterBackground() { mock.appDidEnterBackground() }
        func changePassword(current: String, new: String) async throws {
            try await mock.changePassword(current: current, new: new)
        }
        func setUsesBiometrics(_ enabled: Bool) async throws { try await mock.setUsesBiometrics(enabled) }
        func deleteCurrentVault(password: String) async throws { try await mock.deleteCurrentVault(password: password) }
        func openTransferTarget(password: String) async throws -> OpenVault {
            try await mock.openTransferTarget(password: password)
        }
        func closeTransferTarget(_ vault: OpenVault) { mock.closeTransferTarget(vault) }
    }
#endif
