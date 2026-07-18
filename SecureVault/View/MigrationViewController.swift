//
//  MigrationViewController.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

final class MigrationViewController: UIViewController {

    enum MigrationType {
        case encrypt
        case decrypt
    }

    private let type: MigrationType
    private let onComplete: () -> Void

    private let titleLabel    = UILabel()
    private let progressBar   = UIProgressView(progressViewStyle: .default)
    private let statusLabel   = UILabel()

    init(type: MigrationType, onComplete: @escaping () -> Void) {
        self.type = type
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startMigration()
    }

    private func setupUI() {
        titleLabel.text = type == .encrypt ? "Encrypting Files" : "Decrypting Files"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.progress = 0
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = "Preparing..."
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleLabel)
        view.addSubview(progressBar)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),

            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func startMigration() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let progressHandler: (Double) -> Void = { progress in
                    DispatchQueue.main.async {
                        self.progressBar.setProgress(Float(progress), animated: true)
                        self.statusLabel.text = "\(Int(progress * 100))% complete"
                    }
                }
                if self.type == .encrypt {
                    try FileSystem.shared.migrateToEncrypted(in: VaultDirectory.root, progress: progressHandler)
                } else {
                    try FileSystem.shared.migrateToDecrypted(in: VaultDirectory.root, progress: progressHandler)
                }
                DispatchQueue.main.async {
                    self.progressBar.setProgress(1.0, animated: true)
                    self.statusLabel.text = "Complete"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.dismiss(animated: true) {
                            self.onComplete()
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}
