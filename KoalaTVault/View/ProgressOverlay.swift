//
//  ProgressOverlay.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/27/26.
//

import UIKit

final class ProgressOverlay: UIView {

    private let containerView  = UIView()
    private let titleLabel     = UILabel()
    private let progressBar    = UIProgressView(progressViewStyle: .default)
    private let statusLabel    = UILabel()
    private let cancelButton   = UIButton(type: .system)
    private var onCancel: (() -> Void)?

    static func show(in viewController: UIViewController, title: String, cancellable: Bool = false, onCancel: (() -> Void)? = nil) -> ProgressOverlay {
        let overlay = ProgressOverlay()
        overlay.titleLabel.text = title
        overlay.onCancel = onCancel
        overlay.cancelButton.isHidden = !cancellable
        overlay.frame = viewController.view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        viewController.view.addSubview(overlay)
        return overlay
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        backgroundColor = UIColor.black.withAlphaComponent(0.5)

        containerView.backgroundColor = .systemBackground
        containerView.layer.cornerRadius = 16
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.text = "Preparing..."
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(titleLabel)
        containerView.addSubview(progressBar)
        containerView.addSubview(statusLabel)
        containerView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 300),

            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            progressBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            cancelButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),
        ])
    }

    func update(progress: Float, status: String) {
        DispatchQueue.main.async {
            self.progressBar.setProgress(progress, animated: false)
            self.statusLabel.text = status
        }
    }

    func dismiss() {
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.2) {
                self.alpha = 0
            } completion: { _ in
                self.removeFromSuperview()
            }
        }
    }

    @objc private func cancelTapped() {
        onCancel?()
        dismiss()
    }
}
