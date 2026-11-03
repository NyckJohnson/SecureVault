import Combine
import UIKit

/// The paywall: binds `PaywallViewModel` to the title, message, price, Unlock, Restore and Close.
final class PaywallViewController: UIViewController, AlertPresenting {
    private let pro: any ProUnlocking
    private let onUnlock: @MainActor () -> Void
    private lazy var viewModel = PaywallViewModel(
        pro: pro, alerts: self, onUnlock: onUnlock,
        onClose: { [weak self] in self?.dismiss(animated: true) })
    private var subscriptions = Set<AnyCancellable>()
    private var priceTask: Task<Void, Never>?

    private let titleLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let priceLabel = UILabel()
    private let unlockButton = UIButton(type: .system)
    private let restoreButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    /// - Parameters:
    ///   - pro: the "Unlock Pro" entitlement.
    ///   - onUnlock: called after Pro is unlocked, before the paywall closes.
    init(pro: any ProUnlocking, onUnlock: @escaping @MainActor () -> Void) {
        self.pro = pro
        self.onUnlock = onUnlock
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        priceTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "paywall"
        configureViews()
        layOutViews()
        bindViewModel()
        priceTask = Task { [viewModel] in await viewModel.loadPrice() }
    }

    private func configureViews() {
        titleLabel.text = viewModel.title
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "paywall.titleLabel"

        descriptionLabel.text = viewModel.message
        descriptionLabel.font = .preferredFont(forTextStyle: .body)
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.textAlignment = .center
        descriptionLabel.numberOfLines = 0
        descriptionLabel.accessibilityIdentifier = "paywall.descriptionLabel"

        priceLabel.font = .preferredFont(forTextStyle: .headline)
        priceLabel.textAlignment = .center
        priceLabel.accessibilityIdentifier = "paywall.priceLabel"

        unlockButton.configuration = .filled()
        unlockButton.setTitle("Unlock", for: .normal)
        unlockButton.addTarget(self, action: #selector(unlockTapped), for: .touchUpInside)
        unlockButton.accessibilityIdentifier = "paywallUnlockButton"

        restoreButton.setTitle("Restore Purchases", for: .normal)
        restoreButton.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)
        restoreButton.accessibilityIdentifier = "restoreButton"

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .tertiaryLabel
        closeButton.accessibilityLabel = "Close"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityIdentifier = "paywall.closeButton"

        activityIndicator.hidesWhenStopped = true
        activityIndicator.accessibilityIdentifier = "paywall.activityIndicator"
    }

    private func layOutViews() {
        let stack = UIStackView()
        for arranged: UIView in [titleLabel, descriptionLabel, priceLabel] {
            stack.addArrangedSubview(arranged)
        }
        for arranged: UIView in [unlockButton, restoreButton, activityIndicator] {
            stack.addArrangedSubview(arranged)
        }
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(24, after: descriptionLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(closeButton)
        let guide = view.safeAreaLayoutGuide
        var constraints: [NSLayoutConstraint] = []
        constraints.append(stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24))
        constraints.append(stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24))
        constraints.append(stack.centerYAnchor.constraint(equalTo: view.centerYAnchor))
        constraints.append(closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8))
        constraints.append(closeButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16))
        NSLayoutConstraint.activate(constraints)
    }

    private func bindViewModel() {
        viewModel.$priceText
            .sink { [weak self] text in self?.priceLabel.text = text }
            .store(in: &subscriptions)
        viewModel.$isBusy
            .removeDuplicates()
            .sink { [weak self] isBusy in self?.showBusy(isBusy) }
            .store(in: &subscriptions)
    }

    private func showBusy(_ isBusy: Bool) {
        unlockButton.isEnabled = !isBusy
        restoreButton.isEnabled = !isBusy
        if isBusy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    @objc private func unlockTapped() {
        let scene = view.window?.windowScene
        Task { [viewModel] in await viewModel.unlockTapped(confirmIn: scene) }
    }

    @objc private func restoreTapped() {
        Task { [viewModel] in await viewModel.restoreTapped() }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}
