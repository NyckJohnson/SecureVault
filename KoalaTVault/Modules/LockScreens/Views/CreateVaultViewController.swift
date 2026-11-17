import Combine
import UIKit

/// The Create Vault screen: binds `CreateVaultViewModel` to the name field, the Create button and the error
/// label; Create asks for the password and its confirmation in a "Set Password" alert
/// (feature multiple-vaults-duress-password).
final class CreateVaultViewController: UIViewController {
    private let viewModel: CreateVaultViewModel
    private var subscriptions = Set<AnyCancellable>()

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let iconImageView = UIImageView(image: UIImage(systemName: "lock.badge.plus"))
    private let nameField = UITextField()
    private let errorLabel = UILabel()
    private let createButton = UIButton(type: .system)

    /// - Parameter viewModel: the screen's logic and state.
    init(viewModel: CreateVaultViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Create Vault"
        view.backgroundColor = .systemBackground
        configureViews()
        layOutViews()
        bindViewModel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        nameField.becomeFirstResponder()
    }

    private func configureViews() {
        iconImageView.tintColor = .systemBlue
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle)
        iconImageView.isAccessibilityElement = false

        configure(
            nameField, placeholder: "Name", identifier: "createVault.nameField", returnKey: .go,
            action: #selector(nameEdited))
        nameField.autocapitalizationType = .words
        // No content type: a content type here makes iOS treat the screen as a sign-up form and offer
        // passwords to save or suggest.
        nameField.textContentType = nil

        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "createVault.errorLabel"

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Create"
        configuration.buttonSize = .large
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        createButton.configuration = configuration
        createButton.titleLabel?.adjustsFontForContentSizeCategory = true
        createButton.accessibilityLabel = "Create"
        createButton.accessibilityIdentifier = "createVault.createButton"
        createButton.addTarget(self, action: #selector(createTapped), for: .touchUpInside)
    }

    private func configure(
        _ field: UITextField,
        placeholder: String,
        identifier: String,
        returnKey: UIReturnKeyType,
        action: Selector
    ) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.returnKeyType = returnKey
        field.autocorrectionType = .no
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = self
        field.accessibilityLabel = placeholder
        field.accessibilityIdentifier = identifier
        field.addTarget(self, action: action, for: .editingChanged)
    }

    private func layOutViews() {
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        for subview in [iconImageView, nameField, errorLabel, createButton] as [UIView] {
            stack.addArrangedSubview(subview)
        }
        stack.setCustomSpacing(8, after: nameField)

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
        viewModel.$name
            .sink { [weak nameField] text in
                // Only when it differs: resetting the text would disturb typing.
                guard let nameField, nameField.text != text else { return }
                nameField.text = text
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
        let title = isBusy ? CreateVaultViewModel.busyMessage : "Create"
        createButton.configuration?.title = title
        createButton.configuration?.showsActivityIndicator = isBusy
        createButton.accessibilityLabel = title
        createButton.isEnabled = !isBusy
        nameField.isEnabled = !isBusy
        navigationItem.hidesBackButton = isBusy
        if isBusy {
            view.endEditing(true)
        }
    }

    @objc private func nameEdited() {
        viewModel.nameEdited(nameField.text ?? "")
    }

    /// Create: a blank name goes straight to the view model (which shows the name error); otherwise the
    /// password and confirmation are asked for in the "Set Password" alert, whose Create runs the creation.
    /// Asking in an alert keeps iOS from offering to save or suggest a password for the vault.
    @objc private func createTapped() {
        view.endEditing(true)
        let name = nameField.text ?? ""
        viewModel.nameEdited(name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            runCreate()
            return
        }
        present(makePasswordAlert(), animated: true)
    }

    private func makePasswordAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: "Set Password", message: "Choose a password for this vault.", preferredStyle: .alert)
        alert.addTextField { field in
            Self.configureAlertField(field, placeholder: "Password", identifier: "createVault.alertPasswordField")
        }
        alert.addTextField { field in
            Self.configureAlertField(
                field, placeholder: "Confirm Password", identifier: "createVault.alertConfirmField")
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let create = UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields, fields.count == 2 else { return }
            viewModel.passwordEdited(fields[0].text ?? "")
            viewModel.confirmationEdited(fields[1].text ?? "")
            runCreate()
        }
        create.accessibilityIdentifier = "createVault.alertCreateButton"
        alert.addAction(create)
        return alert
    }

    private static func configureAlertField(_ field: UITextField, placeholder: String, identifier: String) {
        field.placeholder = placeholder
        field.isSecureTextEntry = true
        // No password content type: iOS must never offer to save or suggest a vault password.
        field.textContentType = nil
        field.autocorrectionType = .no
        field.accessibilityLabel = placeholder
        field.accessibilityIdentifier = identifier
    }

    private func runCreate() {
        Task { [viewModel] in await viewModel.createTapped() }
    }
}

extension CreateVaultViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === nameField {
            createTapped()
        }
        return true
    }
}

#if DEBUG
    @available(iOS 17.0, *)
    #Preview("Create Vault: empty form") {
        UINavigationController(
            rootViewController: CreateVaultViewController(viewModel: CreateVaultViewModel(lock: MockVaultLocking())))
    }

    @available(iOS 17.0, *)
    #Preview("Create Vault: passwords do not match (after the Set Password alert)") {
        let viewModel = CreateVaultViewModel(lock: MockVaultLocking(isPro: true))
        viewModel.nameEdited("Travel")
        viewModel.passwordEdited("one")
        viewModel.confirmationEdited("two")
        Task { await viewModel.createTapped() }
        return UINavigationController(rootViewController: CreateVaultViewController(viewModel: viewModel))
    }

    @available(iOS 17.0, *)
    #Preview("Create Vault: password in use (after the Set Password alert)") {
        let viewModel = CreateVaultViewModel(lock: MockVaultLocking(isPro: true))
        viewModel.nameEdited("Travel")
        viewModel.passwordEdited("correct horse")
        viewModel.confirmationEdited("correct horse")
        Task { await viewModel.createTapped() }
        return UINavigationController(rootViewController: CreateVaultViewController(viewModel: viewModel))
    }
#endif
