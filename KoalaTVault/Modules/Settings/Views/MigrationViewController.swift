import Combine
import UIKit

/// Grants a little time to finish work after the app moves to the background: `UIApplication`'s background
/// tasks, or a stand-in in tests.
@MainActor
protocol BackgroundTimeProviding: AnyObject {
    /// Asks for background time; `handler` runs if the time runs out first.
    func beginBackgroundTask(withName taskName: String?, expirationHandler handler: (() -> Void)?)
        -> UIBackgroundTaskIdentifier
    /// Hands back the time asked for by `beginBackgroundTask`.
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

extension UIApplication: BackgroundTimeProviding {
    /// `BackgroundTimeProviding`'s form of UIKit's `beginBackgroundTask(withName:expirationHandler:)`, whose
    /// handler type is `@MainActor @Sendable`; UIKit calls the handler on the main thread.
    func beginBackgroundTask(
        withName taskName: String?, expirationHandler handler: (() -> Void)?
    ) -> UIBackgroundTaskIdentifier {
        var expiration: (@MainActor @Sendable () -> Void)?
        if let handler {
            let box = BackgroundExpirationBox(handler)
            expiration = { box.handler() }
        }
        return beginBackgroundTask(withName: taskName, expirationHandler: expiration)
    }
}

/// Carries a background task's expiration handler to the main actor, where UIKit runs it.
@MainActor
private final class BackgroundExpirationBox {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
}

/// The migration screen: binds `MigrationViewModel` to the title, progress bar, status line and failure alert
/// (failed files, or unreadable trash), holds background time while files migrate, and goes away at the end.
final class MigrationViewController: UIViewController, AlertPresenting {
    private let backgroundTime: any BackgroundTimeProviding
    private let onFinish: @MainActor (Bool) -> Void
    private let viewModel: MigrationViewModel
    private var subscriptions = Set<AnyCancellable>()
    private var runTask: Task<Void, Never>?
    private var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
    /// The failure alert on screen, so a later phase can take it away.
    private weak var failureAlert: UIAlertController?

    private let titleLabel = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()

    /// - Parameters:
    ///   - kind: encrypt or decrypt; sets the title.
    ///   - migrator: the app's one lock migration.
    ///   - waitsForNewRun: true when the caller starts a migration right after making this screen (see
    ///     `MigrationViewModel`).
    ///   - sleep: waits before the screen goes away (a stand-in in tests).
    ///   - backgroundTime: grants background time while files migrate.
    ///   - onFinish: called once, after the screen is dismissed, with whether the migration completed fully.
    init(
        kind: MigrationKind, migrator: any LockMigrating, waitsForNewRun: Bool = false,
        sleep: @escaping @Sendable (Duration) async throws -> Void = MigrationViewModel.liveSleep,
        backgroundTime: any BackgroundTimeProviding = UIApplication.shared,
        onFinish: @escaping @MainActor (Bool) -> Void
    ) {
        self.backgroundTime = backgroundTime
        self.onFinish = onFinish
        // The view model reports its end here; the relay reaches this controller once it exists.
        let relay = MigrationFinishRelay()
        viewModel = MigrationViewModel(
            kind: kind, migrator: migrator, waitsForNewRun: waitsForNewRun, sleep: sleep,
            onFinish: { relay.controller?.finish(completedFully: $0) })
        super.init(nibName: nil, bundle: nil)
        relay.controller = self
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        runTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureViews()
        bindViewModel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A failure reported before the screen was on screen shows now.
        showFailureIfNeeded()
        // Appears again when a lock screen is dismissed over it; the view model runs only once.
        guard runTask == nil else { return }
        runTask = Task { [viewModel] in await viewModel.run() }
    }

    private func configureViews() {
        titleLabel.text = viewModel.title
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "migration.titleLabel"

        progressBar.accessibilityIdentifier = "migration.progressBar"

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "migration.statusLabel"

        for subview in [titleLabel, progressBar, statusLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        var constraints: [NSLayoutConstraint] = []
        constraints.append(titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor))
        constraints.append(titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40))
        constraints.append(progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24))
        constraints.append(progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40))
        constraints.append(progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40))
        constraints.append(statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12))
        constraints.append(statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor))
        NSLayoutConstraint.activate(constraints)
    }

    private func bindViewModel() {
        viewModel.$statusText
            .sink { [weak self] text in self?.statusLabel.text = text }
            .store(in: &subscriptions)
        viewModel.$progress
            .sink { [weak self] progress in self?.progressBar.progress = progress }
            .store(in: &subscriptions)
        viewModel.$failureMessage
            .sink { [weak self] message in
                if message == nil { self?.dismissFailureAlert() }
            }
            .store(in: &subscriptions)
        // Published values arrive before the property changes, so read the state on the next turn.
        viewModel.$failureMessage
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showFailureIfNeeded() }
            .store(in: &subscriptions)
        viewModel.$wantsBackgroundTime
            .removeDuplicates()
            .sink { [weak self] wants in
                if wants { self?.beginBackgroundTime() } else { self?.endBackgroundTime() }
            }
            .store(in: &subscriptions)
    }

    // MARK: - Failure alert

    private func showFailureIfNeeded() {
        guard let message = viewModel.failureMessage, viewIfLoaded?.window != nil else { return }
        dismissFailureAlert()
        let alert = UIAlertController(title: viewModel.failureTitle, message: message, preferredStyle: .alert)
        // Unreadable trash offers Clear and Continue instead of Retry; Skip is the same in both.
        if viewModel.isUnreadableTrash {
            alert.addClosingAction(title: "Clear and Continue", style: .default) { [viewModel] in
                Task { await viewModel.clearAndContinue() }
            }
        } else {
            alert.addClosingAction(title: "Retry", style: .default) { [viewModel] in
                Task { await viewModel.retry() }
            }
        }
        alert.addClosingAction(title: "Skip", style: .default) { [viewModel] in
            Task { await viewModel.skip() }
        }
        failureAlert = alert
        presentFromSettings(alert, animated: false)
    }

    private func dismissFailureAlert() {
        guard let alert = failureAlert else { return }
        failureAlert = nil
        if alert.presentingViewController != nil {
            alert.dismiss(animated: false)
        }
    }

    // MARK: - Finishing

    fileprivate func finish(completedFully: Bool) {
        dismissFailureAlert()
        let onFinish = onFinish
        guard let presenter = presentingViewController else {
            onFinish(completedFully)
            return
        }
        // Dismissing from the presenter also takes away anything shown over this screen.
        presenter.dismiss(animated: true) { onFinish(completedFully) }
    }

    // MARK: - Background time

    private func beginBackgroundTime() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = backgroundTime.beginBackgroundTask(withName: "MigrationCompletion") { [weak self] in
            // Time is nearly up. Nothing needs aborting: the migrator pauses on the key wipe and resumes
            // after the next unlock.
            self?.endBackgroundTime()
        }
    }

    private func endBackgroundTime() {
        guard backgroundTaskID != .invalid else { return }
        backgroundTime.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

/// Lets the view model, made before its controller, report its end to that controller.
@MainActor
private final class MigrationFinishRelay {
    weak var controller: MigrationViewController?
}
