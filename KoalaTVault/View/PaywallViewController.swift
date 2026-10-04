//
//  PaywallViewController.swift
//  KoalaTVault
//

import UIKit
import StoreKit

final class PaywallViewController: UIViewController, ErrorPresenting {

    /// Called after a successful purchase or restore, before dismissal.
    var onUnlock: (() -> Void)?

    private let titleLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let priceLabel = UILabel()
    private let unlockButton = UIButton(type: .system)
    private let restoreButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setUpLayout()
        Task { await loadProduct() }
    }

    // MARK: - Layout
    private func setUpLayout() {
        titleLabel.text = "Unlock Pro"
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.textAlignment = .center

        descriptionLabel.text = "Store more than \(EntitlementService.freeFileLimit) files."
        descriptionLabel.font = .preferredFont(forTextStyle: .body)
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.textAlignment = .center
        descriptionLabel.numberOfLines = 0

        priceLabel.font = .preferredFont(forTextStyle: .headline)
        priceLabel.textAlignment = .center
        priceLabel.text = " "

        unlockButton.configuration = .filled()
        unlockButton.setTitle("Unlock", for: .normal)
        unlockButton.addTarget(self, action: #selector(unlockTapped), for: .touchUpInside)
        unlockButton.accessibilityIdentifier = "paywallUnlockButton"

        restoreButton.setTitle("Restore Purchases", for: .normal)
        restoreButton.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)
        restoreButton.accessibilityIdentifier = "restoreButton"

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .tertiaryLabel
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        activityIndicator.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, descriptionLabel, priceLabel, unlockButton, restoreButton, activityIndicator
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(24, after: descriptionLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])
    }

    // MARK: - StoreKit
    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [EntitlementService.unlockProductID])
            priceLabel.text = products.first?.displayPrice
        } catch {
            priceLabel.text = nil
        }
    }

    @objc private func unlockTapped() {
        setLoading(true)
        let scene = view.window?.windowScene
        Task {
            do {
                try await EntitlementService.shared.purchaseUnlock(confirmIn: scene)
                setLoading(false)
                finishIfUnlocked()
            } catch {
                setLoading(false)
                showError(error)
            }
        }
    }

    @objc private func restoreTapped() {
        setLoading(true)
        Task {
            do {
                try await EntitlementService.shared.restorePurchases()
                setLoading(false)
                if EntitlementService.shared.isUnlocked {
                    finishIfUnlocked()
                } else {
                    showError("No previous purchase found to restore.")
                }
            } catch StoreKitError.userCancelled {
                setLoading(false)
            } catch {
                setLoading(false)
                showError(error)
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func finishIfUnlocked() {
        guard EntitlementService.shared.isUnlocked else { return }
        onUnlock?()
        dismiss(animated: true)
    }

    private func setLoading(_ loading: Bool) {
        unlockButton.isEnabled = !loading
        restoreButton.isEnabled = !loading
        if loading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }
}
