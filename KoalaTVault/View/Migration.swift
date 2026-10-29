//
//  LegacyMigrationViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//
//  The Migration screen. It only shows what the app's one `LockMigrating` reports and forwards the user's
//  Retry and Skip; the migration itself (files, pause and resume, the pending record) lives in LockMigration.
//

import UIKit

final class LegacyMigrationViewController: UIViewController, AlertPresenting {

    /// Encrypt or decrypt; the same type the preferences persist as the pending migration.
    typealias MigrationType = MigrationKind

    private let type: MigrationType
    private let migrator: any LockMigrating
    /// What the presenter wants the migrator to do (start, or resume a pending one); run once, on first appearance.
    private let begin: @MainActor (any LockMigrating) async -> Void
    private let onComplete: (_ completedFully: Bool) -> Void

    private let titleLabel    = UILabel()
    private let progressBar   = UIProgressView(progressViewStyle: .default)
    private let statusLabel   = UILabel()

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// Follows the migrator's phase; subscribed at init, so no change after `begin` is missed.
    private var phaseObservation: Task<Void, Never>?
    private var beginTask: Task<Void, Never>?
    /// The failure alert currently shown, so a later phase can take it away.
    private weak var failureAlert: UIAlertController?
    private var isFinishing = false
    /// A failure reported before the screen was on screen; shown once it appears.
    private var failureAwaitingAppearance: [String]?

    /// - Parameters:
    ///   - type: encrypt or decrypt the whole vault (trash included); sets the title.
    ///   - migrator: the app's one lock migration, which this screen shows.
    ///   - begin: called once when the screen first appears, e.g. `start(_:target:)` or `resumeIfPending()`.
    ///   - onComplete: called after the screen is dismissed on `.completed(fully:)`, with `fully`.
    init(
        type: MigrationType,
        migrator: any LockMigrating,
        begin: @escaping @MainActor (any LockMigrating) async -> Void,
        onComplete: @escaping (_ completedFully: Bool) -> Void
    ) {
        self.type = type
        self.migrator = migrator
        self.begin = begin
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        observePhase()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        phaseObservation?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        // A run already under way (e.g. a resume) shows at once. An old `.completed` or `.idle` belongs to an
        // earlier migration: the screen waits for this one's phases instead.
        switch migrator.phase {
        case .running, .paused, .failed: render(migrator.phase)
        case .idle, .completed: break
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let names = failureAwaitingAppearance {
            failureAwaitingAppearance = nil
            presentFailureSummary(names: names)
        }
        // Appears again when a lock screen is dismissed over it; the migration is already under way then
        // (running or paused), and the unlock resumes it through `resumeIfPending`.
        guard beginTask == nil else { return }
        let migrator = migrator
        let begin = begin
        beginTask = Task { await begin(migrator) }
    }

    /// The stream yields changes only; `viewDidLoad` renders the phase at hand.
    private func observePhase() {
        let updates = migrator.phaseUpdates()
        phaseObservation = Task { [weak self] in
            for await phase in updates {
                self?.render(phase)
            }
        }
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

    // MARK: - Phases

    private func render(_ phase: MigrationPhase) {
        guard !isFinishing else { return }
        switch phase {
        case .idle:
            break
        case .running(let done, let total):
            dismissFailureAlert()
            beginBackgroundTask()
            showProgress(done: done, total: total)
        case .paused(let done, let total):
            dismissFailureAlert()
            endBackgroundTask()
            setProgress(done: done, total: total)
            statusLabel.text = "Paused — unlock to continue"
        case .failed(let names):
            endBackgroundTask()
            if viewIfLoaded?.window == nil {
                failureAwaitingAppearance = names
            } else {
                presentFailureSummary(names: names)
            }
        case .completed(let fully):
            dismissFailureAlert()
            finishMigration(completedFully: fully)
        }
    }

    private func showProgress(done: Int, total: Int) {
        guard total > 0 else { return }
        setProgress(done: done, total: total)
        statusLabel.text = "\(done * 100 / total)% complete"
    }

    private func setProgress(done: Int, total: Int) {
        guard total > 0 else { return }
        progressBar.setProgress(Float(done) / Float(total), animated: true)
    }

    private func finishMigration(completedFully: Bool) {
        isFinishing = true
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

    /// The failure summary. `names` is empty when a step other than a file failed (listing the files, or a
    /// closing step); the screen then says so generically, and the error itself is only logged.
    private func presentFailureSummary(names: [String]) {
        dismissFailureAlert()
        let message = names.isEmpty
            ? "The migration couldn't finish. Retry, or Skip to stop for now."
            : "These files couldn't be migrated: \(names.joined(separator: ", "))"
        let alert = UIAlertController(title: "Some Files Failed", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.retryFailedFiles()
        })
        alert.addAction(UIAlertAction(title: "Skip", style: .default) { [weak self] _ in
            self?.skipFailedFiles()
        })
        failureAlert = alert
        present(alert, animated: true)
    }

    private func dismissFailureAlert() {
        failureAwaitingAppearance = nil
        guard let failureAlert, failureAlert.presentingViewController != nil else { return }
        failureAlert.dismiss(animated: false)
        self.failureAlert = nil
    }

    private func retryFailedFiles() {
        Task { [migrator] in await migrator.retryFailed() }
    }

    private func skipFailedFiles() {
        Task { [migrator] in await migrator.skipFailed() }
    }

    // MARK: - Background time

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MigrationCompletion") { [weak self] in
            // Expiration handler: time is nearly up. Nothing needs aborting: the migrator pauses on the key
            // wipe, and its persisted pending record drives the resume after the next unlock.
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

#if DEBUG
    var testStatusText: String? { statusLabel.text }

    /// Directly invokes what the "Retry"/"Skip" alert actions do, bypassing UIAlertController
    /// entirely — avoids relying on undocumented private API to simulate a tap.
    func testTapRetry() { retryFailedFiles() }
    func testTapSkip() { skipFailedFiles() }
#endif
}
