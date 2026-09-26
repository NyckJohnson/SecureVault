//
//  MigrationViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

final class MigrationViewController: UIViewController, ErrorPresenting {

    nonisolated enum MigrationType: String {
        case encrypt
        case decrypt
    }

    private let type: MigrationType
    private let onComplete: (_ completedFully: Bool) -> Void

    private let titleLabel    = UILabel()
    private let progressBar   = UIProgressView(progressViewStyle: .default)
    private let statusLabel   = UILabel()

    private var filesToMigrate:   [(item: VaultItem, directory: VaultDirectory)] = []
    private var failedFiles:      [(item: VaultItem, directory: VaultDirectory, error: Error)] = []
    private var currentIndex      = 0
    private var isPaused          = false
    private let targetLockMode:   LockMode?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let directory:        VaultDirectory

    init(type: MigrationType, directory: VaultDirectory = .root, targetLockMode: LockMode? = nil, onComplete: @escaping (_ completedFully: Bool) -> Void) {
        self.type = type
        self.directory = directory
        self.targetLockMode = targetLockMode
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        NotificationCenter.default.addObserver(self, selector: #selector(vaultUnlocked), name: AuthService.vaultUnlockedNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        endBackgroundTask()
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
        PreferencesService.shared.pendingMigrationType = type
        if let targetLockMode {
            PreferencesService.shared.pendingMigrationTargetLockMode = targetLockMode
        }
        beginBackgroundTask()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                filesToMigrate = try FileSystem.shared.filesToMigrate(toEncrypted: type == .encrypt, in: directory)
                print("Resuming migration — \(filesToMigrate.count) files still need to be en/de-crypted")
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
                self?.finishOrShowFailures()
            }
            return
        }

        guard CryptoService.shared.isKeyLoaded else {
            DispatchQueue.main.async { [weak self] in
                self?.pauseMigration()
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
        } catch {
            failedFiles.append((item: item, directory: directory, error: error))
        }
        currentIndex += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let progress = Double(self.currentIndex) / Double(self.filesToMigrate.count)
            self.progressBar.setProgress(Float(progress), animated: true)
            self.statusLabel.text = "\(Int(progress * 100))% complete"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processNextFile()
        }
    }

    private func finishMigration() {
        let completedFully = failedFiles.isEmpty
        if completedFully {
            PreferencesService.shared.pendingMigrationType = nil
            PreferencesService.shared.pendingMigrationTargetLockMode = nil
        }
        endBackgroundTask()
        progressBar.setProgress(1.0, animated: true)
        statusLabel.text = "Complete"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true) {
                self.onComplete(completedFully)
            }
        }
    }

    private func finishOrShowFailures() {
        if failedFiles.isEmpty {
            finishMigration()
        } else {
            presentFailureSummary()
        }
    }

    private func presentFailureSummary() {
        let names = failedFiles.map { $0.item.name }.joined(separator: ", ")
        let alert = UIAlertController(
            title: "Some Files Failed",
            message: "These files couldn't be migrated: \(names)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.retryFailedFiles()
        })
        alert.addAction(UIAlertAction(title: "Skip", style: .default) { [weak self] _ in
            self?.finishMigration()
        })
        present(alert, animated: true)
    }

    private func retryFailedFiles() {
        filesToMigrate = failedFiles.map { (item: $0.item, directory: $0.directory) }
        failedFiles = []
        currentIndex = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processNextFile()
        }
    }

    private func pauseMigration() {
        guard !isPaused else { return }
        isPaused = true
        endBackgroundTask()
        statusLabel.text = "Paused — unlock to continue"
    }

    @objc private func vaultUnlocked() {
        guard isPaused else { return }
        isPaused = false
        beginBackgroundTask()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processNextFile()
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MigrationCompletion") { [weak self] in
            // Expiration handler: time is nearly up. We can't finish the current file safely,
            // but there's nothing unsafe to abort — processNextFile will simply get suspended
            // by the OS, and pendingMigrationType (already persisted) drives resume on next launch.
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
    
#if DEBUG
    var testFailedFileNames: [String] { failedFiles.map { $0.item.name } }
    var testIsPaused: Bool { isPaused }
    var testStatusText: String? { statusLabel.text }

    /// Directly invokes what the "Retry"/"Skip" alert actions do, bypassing UIAlertController
    /// entirely — avoids relying on undocumented private API to simulate a tap.
    func testTapRetry() { retryFailedFiles() }
    func testTapSkip() { finishMigration() }
#endif
}
