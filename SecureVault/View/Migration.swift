//
//  MigrationViewController.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

final class MigrationViewController: UIViewController, ErrorPresenting {

    nonisolated enum MigrationType {
        case encrypt
        case decrypt
    }

    private let type: MigrationType
    private let onComplete: () -> Void

    private var filesToMigrate: [(item: VaultItem, directory: VaultDirectory)] = []
    private var currentIndex  = 0
    
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
                filesToMigrate = try FileSystem.shared.filesToMigrate(toEncrypted: type == .encrypt, in: VaultDirectory.root)
            } catch {
                DispatchQueue.main.async { self.showError(error) }
                return
            }
            currentIndex = 0
            processNextFile()
        }
    }

    /// Migrates filesToMigrate[currentIndex]. Must be called on a background queue.
    private func processNextFile() {
        guard currentIndex < filesToMigrate.count else {
            DispatchQueue.main.async { [weak self] in
                self?.finishMigration()
            }
            return
        }

        let (item, directory) = filesToMigrate[currentIndex]
        do {
            if type == .encrypt {
                try FileSystem.shared.migrateFileToEncrypted(item, in: directory)
            } else {
                try FileSystem.shared.migrateFileToDecrypted(item, in: directory)
            }
            currentIndex += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let progress = Double(self.currentIndex) / Double(self.filesToMigrate.count)
                self.progressBar.setProgress(Float(progress), animated: true)
                self.statusLabel.text = "\(Int(progress * 100))% complete"
            }
            processNextFile()
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.presentFailureOptions(for: item, error: error)
            }
        }
    }

    private func finishMigration() {
        progressBar.setProgress(1.0, animated: true)
        statusLabel.text = "Complete"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true) {
                self.onComplete()
            }
        }
    }

    private func presentFailureOptions(for item: VaultItem, error: Error) {
        let alert = UIAlertController(
            title: "Migration Failed",
            message: "Couldn't migrate \"\(item.name)\": \(error.localizedDescription)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.resumeMigration()
        })
        alert.addAction(UIAlertAction(title: "Skip", style: .default) { [weak self] _ in
            guard let self else { return }
            self.currentIndex += 1
            self.resumeMigration()
        })
        alert.addAction(UIAlertAction(title: "Stop", style: .destructive) { [weak self] _ in
            self?.dismiss(animated: true) {
                self?.onComplete()
            }
        })
        present(alert, animated: true)
    }

    private func resumeMigration() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processNextFile()
        }
    }
}
