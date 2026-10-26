//
//  MigrationViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import os
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
    /// True while a `runMigration` loop is executing; at most one loop runs per screen.
    private var isLoopRunning = false
    /// Set when the closing index cleanup of a decrypt migration failed; a Skip then reports
    /// the migration as not completed, so the key and lock are kept.
    private var decryptCleanupFailed = false
    /// False until the scan of files to migrate has succeeded; the scan needs the key, so a
    /// migration that starts (or is retried) while locked scans after the unlock.
    private var filesLoaded = false
    /// Counts backgroundings and data-protection losses. A file that fails while this changed
    /// failed because of the interruption, not because of the file, and is run again.
    private var interruptions = 0
    /// Reruns of the current file after interrupted failures; bounded so a file that keeps
    /// failing is reported instead of looping.
    private var transientRetries = 0
    private static let maxTransientRetries = 2
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "Migration")

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
        let center = NotificationCenter.default
        // Any of these can make work possible again (key loaded, files readable).
        for name in [AuthService.vaultUnlockedNotification,
                     UIApplication.didBecomeActiveNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification] {
            center.addObserver(self, selector: #selector(resumeIfPossible), name: name, object: nil)
        }
        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.protectedDataWillBecomeUnavailableNotification] {
            center.addObserver(self, selector: #selector(noteInterruption), name: name, object: nil)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Appears again when a lock screen is dismissed over it; the migration is already
        // under way then (running or paused), and unlocking resumes it via resumeIfPossible.
        guard migrationTask == nil else { return }
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
        migrationTask = Task { await runMigration() }
    }

    /// Work needs the key (wiped when the app backgrounds under a lock) and readable files
    /// (data protection closes them while the device is locked).
    private var canMigrate: Bool {
        CryptoService.shared.isKeyLoaded && UIApplication.shared.isProtectedDataAvailable
    }

    /// Scans for files (once per run or Retry), then migrates them one at a time. Pauses
    /// whenever work isn't possible; nothing is counted as failed for that. State stays on the
    /// main actor; only the file I/O runs in the background.
    private func runMigration() async {
        guard !isLoopRunning else { return }
        isLoopRunning = true
        defer { isLoopRunning = false }
        guard await loadFilesIfNeeded() else { return }
        while currentIndex < filesToMigrate.count {
            await delayForUITests()
            guard canMigrate else {
                pauseMigration()
                return
            }
            let (item, itemDirectory) = filesToMigrate[currentIndex]
            let interruptionsBefore = interruptions
            do {
                try await Self.migrate(item, in: itemDirectory, encrypt: type == .encrypt)
            } catch {
                if wasInterrupted(by: error, since: interruptionsBefore) {
                    // Each file's migration is safe to rerun from any point, so run it again.
                    guard canMigrate else {
                        pauseMigration()
                        return
                    }
                    if transientRetries < Self.maxTransientRetries {
                        transientRetries += 1
                        continue
                    }
                }
                failedFiles.append((item: item, directory: itemDirectory, error: error))
            }
            transientRetries = 0
            currentIndex += 1
            showProgress()
        }
        if type == .encrypt {
            guard await secureLeftoverIndexes() else { return }
        }
        if type == .decrypt && failedFiles.isEmpty {
            guard await finishDecryption() else { return }
        }
        finishOrShowFailures()
    }

    /// Scans for the files to migrate unless this run already has. Returns false when the run
    /// stopped here: paused (no key or files unreadable), or the scan-failure alert is shown.
    private func loadFilesIfNeeded() async -> Bool {
        guard !filesLoaded else { return true }
        guard canMigrate else {
            pauseMigration()
            return false
        }
        do {
            filesToMigrate = try await Self.loadFiles(toEncrypted: type == .encrypt, in: directory)
        } catch {
            if canMigrate {
                presentLoadFailure(error)
            } else {
                pauseMigration()
            }
            return false
        }
        filesLoaded = true
        currentIndex = 0
        transientRetries = 0
        return true
    }

    /// True when a file's failure came from an interruption (backgrounding, device lock, key
    /// wipe) rather than from the file.
    private func wasInterrupted(by error: Error, since interruptionsBefore: Int) -> Bool {
        interruptions != interruptionsBefore || !canMigrate || (error as? CryptoError) == .noKeyLoaded
    }

    private func showProgress() {
        guard !filesToMigrate.isEmpty else { return }
        let progress = Double(currentIndex) / Double(filesToMigrate.count)
        progressBar.setProgress(Float(progress), animated: true)
        statusLabel.text = "\(Int(progress * 100))% complete"
    }

    /// Last step of an encrypt migration: re-saves encrypted any folder index an older build
    /// left in plaintext. Returns false when it paused (key wiped); a failure with the key loaded
    /// is logged and doesn't stop the migration: every file is safe, and the next save of that
    /// folder's index encrypts it.
    private func secureLeftoverIndexes() async -> Bool {
        do {
            try await Self.encryptIndexes(in: directory)
        } catch {
            guard canMigrate else {
                pauseMigration()
                return false
            }
            logger.error("Re-encrypting folder indexes failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    @concurrent
    private nonisolated static func encryptIndexes(in directory: VaultDirectory) async throws {
        try FileSystem.shared.encryptPlaintextIndexes(in: directory)
    }

    /// `UITEST_MIGRATION_FILE_DELAY`: waits before each file so a UI test can background mid-run.
    private func delayForUITests() async {
        guard let seconds = LegacyStorage.current.uiTestSettings?.migrationFileDelay, seconds > 0 else { return }
        // Sleeping only throws on cancellation, which nothing here requests.
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The scan failed with the key loaded (e.g. a damaged folder index). Never a dead end:
    /// Retry scans again; Close leaves the migration pending, so it resumes after the next unlock.
    private func presentLoadFailure(_ error: Error) {
        statusLabel.text = "Couldn't prepare the files"
        let alert = UIAlertController(
            title: "Couldn't Prepare Files",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.retryFailedFiles()
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
            self?.closeLeavingPending()
        })
        present(alert, animated: true)
    }

    private func closeLeavingPending() {
        endBackgroundTask()
        dismiss(animated: true) { [onComplete] in
            onComplete(false)
        }
    }

    /// Last step of a decrypt migration, run while the key is still loaded: decrypts any
    /// encrypted file that appeared since the scan and deletes every folder's `.vault_map`,
    /// so the vault lists once the key is removed. Returns false when the run stopped here
    /// (paused for a key wipe, or the failure alert is shown); the caller must then not finish.
    private func finishDecryption() async -> Bool {
        guard CryptoService.shared.isKeyLoaded else {
            pauseMigration()
            return false
        }
        do {
            try await Self.removeIndexes(in: directory)
            decryptCleanupFailed = false
            return true
        } catch {
            if !CryptoService.shared.isKeyLoaded {
                // The key was wiped mid-cleanup; unlocking resumes it.
                pauseMigration()
            } else {
                decryptCleanupFailed = true
                presentCleanupFailure(error)
            }
            return false
        }
    }

    @concurrent
    private nonisolated static func removeIndexes(in directory: VaultDirectory) async throws {
        try FileSystem.shared.migrateVaultToDecrypted(in: directory) { _ in }
    }

    private func presentCleanupFailure(_ error: Error) {
        let alert = UIAlertController(
            title: "Some Files Failed",
            message: error.localizedDescription,
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
        let completedFully = failedFiles.isEmpty && !decryptCleanupFailed
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

    /// Scans again rather than reusing the failed list, so whatever state an earlier attempt
    /// left (a file already finished, a leftover copy) is picked up from disk.
    private func retryFailedFiles() {
        failedFiles = []
        filesLoaded = false
        currentIndex = 0
        transientRetries = 0
        beginBackgroundTask()
        migrationTask = Task { await runMigration() }
    }

    private func pauseMigration() {
        guard !isPaused else { return }
        isPaused = true
        endBackgroundTask()
        statusLabel.text = "Paused — unlock to continue"
    }

    @objc private func resumeIfPossible() {
        guard isPaused, !isLoopRunning, canMigrate else { return }
        isPaused = false
        transientRetries = 0
        if filesLoaded {
            showProgress()
        } else {
            statusLabel.text = "Preparing..."
        }
        beginBackgroundTask()
        migrationTask = Task { await runMigration() }
    }

    @objc private func noteInterruption() {
        interruptions += 1
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MigrationCompletion") { [weak self] in
            // Expiration handler: time is nearly up. Nothing needs aborting: each file's
            // migration is safe to interrupt, a suspended file is rerun on resume, and
            // pendingMigrationType (already persisted) drives resume on the next launch.
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
