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

    private var filesToMigrate: [(item: VaultItem, directory: VaultDirectory)] = []
    // swiftlint:disable:next large_tuple
    private var failedFiles: [(item: VaultItem, directory: VaultDirectory, error: Error)] = []
    private var currentIndex      = 0
    private var isPaused          = false
    private let targetLockMode: LockMode?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let directory: VaultDirectory
    private var migrationTask: Task<Void, Never>?

    init(
        type: MigrationType,
        directory: VaultDirectory = .root,
        targetLockMode: LockMode? = nil,
        onComplete: @escaping (_ completedFully: Bool) -> Void
    ) {
        self.type = type
        self.directory = directory
        self.targetLockMode = targetLockMode
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vaultUnlocked),
            name: AuthService.vaultUnlockedNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

        // for ui tests
        titleLabel.accessibilityIdentifier = "migration.titleLabel"
        progressBar.accessibilityIdentifier = "migration.progressBar"
        statusLabel.accessibilityIdentifier = "migration.statusLabel"

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),

            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    private func startMigration() {
        PreferencesService.shared.pendingMigrationType = type
        if let targetLockMode {
            PreferencesService.shared.pendingMigrationTargetLockMode = targetLockMode
        }
        beginBackgroundTask()

        migrationTask = Task {
            do {
                filesToMigrate = try await Self.loadFiles(toEncrypted: type == .encrypt, in: directory)
            } catch {
                showError(error)
                return
            }
            currentIndex = 0
            await runMigration()
        }
    }

    /// Migrates remaining files one at a time. State stays on the main actor;
    /// only the file I/O runs in the background.
    private func runMigration() async {
        while currentIndex < filesToMigrate.count {
            guard CryptoService.shared.isKeyLoaded else {
                pauseMigration()
                return
            }
            let (item, itemDirectory) = filesToMigrate[currentIndex]
            do {
                try await Self.migrate(item, in: itemDirectory, encrypt: type == .encrypt)
            } catch {
                failedFiles.append((item: item, directory: itemDirectory, error: error))
            }
            currentIndex += 1
            let progress = Double(currentIndex) / Double(filesToMigrate.count)
            progressBar.setProgress(Float(progress), animated: true)
            statusLabel.text = "\(Int(progress * 100))% complete"
        }
        finishOrShowFailures()
    }

    @concurrent
    private nonisolated static func loadFiles(
        toEncrypted: Bool,
        in directory: VaultDirectory
    ) async throws -> [(item: VaultItem, directory: VaultDirectory)] {
        try FileSystem.shared.filesToMigrate(toEncrypted: toEncrypted, in: directory)
    }

    @concurrent
    private nonisolated static func migrate(_ item: VaultItem, in directory: VaultDirectory, encrypt: Bool) async throws {
        if encrypt {
            try FileSystem.shared.migrateFileToEncrypted(item, in: directory)
        } else {
            try FileSystem.shared.migrateFileToDecrypted(item, in: directory)
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
        migrationTask = Task { await runMigration() }
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
        migrationTask = Task { await runMigration() }
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
    var testMigrationTask: Task<Void, Never>? { migrationTask }

    /// Directly invokes what the "Retry"/"Skip" alert actions do, bypassing UIAlertController
    /// entirely — avoids relying on undocumented private API to simulate a tap.
    func testTapRetry() { retryFailedFiles() }
    func testTapSkip() { finishMigration() }
#endif
}
