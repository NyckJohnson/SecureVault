import Combine
import Foundation

/// The logic of the migration screen, which encrypts an opened vault's leftover unencrypted files: shows what
/// `LockMigrating` reports, forwards Retry, Skip and Clear and Continue, and reports the end once. The caller
/// starts the work (`encryptLeftovers(in:)`) and stops it (`cancel()`); this screen never does.
@MainActor
final class MigrationViewModel: ObservableObject {
    /// The screen's title.
    let title = "Encrypting Files"
    /// The status line.
    @Published private(set) var statusText = "Preparing…"
    /// How far the migration is, from 0 to 1.
    @Published private(set) var progress: Float = 0
    /// The failure alert's title, while files have failed.
    @Published private(set) var failureTitle: String?
    /// The failure alert's message, while files have failed.
    @Published private(set) var failureMessage: String?
    /// True while the failure alert is the unreadable-trash one (Clear and Continue / Skip), not the
    /// failed-files one (Retry / Skip).
    @Published private(set) var isUnreadableTrash = false
    /// True while files are migrating, when the app should ask for background time.
    @Published private(set) var wantsBackgroundTime = false

    private let migrator: any LockMigrating
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onFinish: @MainActor (Bool) -> Void
    /// Subscribed at init, so no phase after it is missed, however late `run()` begins.
    private let phases: AsyncStream<MigrationPhase>
    /// The phase this screen started from, unless it was ignored as an earlier migration's.
    private var initialPhase = MigrationPhase.idle
    private var isFinishing = false
    private var hasStartedRunning = false
    /// True once a run has been seen (running, failed or unreadable trash), so a later `.idle` means it stopped.
    private var hasSeenRun = false

    /// - Parameters:
    ///   - migrator: the leftover encryption.
    ///   - waitsForNewRun: true when the caller starts the encryption right after making this: a `.completed`
    ///     phase at hand then belongs to an earlier run and is ignored. False when following a run already
    ///     under way, where `.completed` is this run's end.
    ///   - sleep: waits before reporting the end (a stand-in in tests).
    ///   - onFinish: called once at the end, with whether the migration completed fully.
    init(
        migrator: any LockMigrating, waitsForNewRun: Bool = false,
        sleep: @escaping @Sendable (Duration) async throws -> Void = MigrationViewModel.liveSleep,
        onFinish: @escaping @MainActor (Bool) -> Void
    ) {
        self.migrator = migrator
        self.sleep = sleep
        self.onFinish = onFinish
        phases = migrator.phaseUpdates()
        let phase = migrator.phase
        if case .completed = phase, waitsForNewRun { return }
        initialPhase = phase
        apply(phase)
    }

    /// The real wait before the screen goes away.
    nonisolated static func liveSleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    /// Follows the migration to its end, then reports it, unless the calling task is cancelled first. Only
    /// the first call does anything, however often the screen appears.
    func run() async {
        guard !hasStartedRunning else { return }
        hasStartedRunning = true
        if case .completed(let fully) = initialPhase {
            await finish(fully: fully)
            return
        }
        for await phase in phases {
            if phase == .idle, hasSeenRun {
                // The run stopped without finishing (the vault closed): go at once, reporting not fully.
                isFinishing = true
                wantsBackgroundTime = false
                clearFailure()
                onFinish(false)
                return
            }
            apply(phase)
            if case .completed(let fully) = phase {
                await finish(fully: fully)
                return
            }
        }
    }

    /// The user chose Retry.
    func retry() async {
        await migrator.retryFailed()
    }

    /// The user chose Skip.
    func skip() async {
        await migrator.skipFailed()
    }

    /// The user chose Clear and Continue on the unreadable-trash alert.
    func clearAndContinue() async {
        await migrator.clearUnreadableTrash()
    }

    // MARK: - Private

    private func apply(_ phase: MigrationPhase) {
        guard !isFinishing else { return }
        switch phase {
        case .idle:
            break
        case .running(let done, let total):
            hasSeenRun = true
            clearFailure()
            wantsBackgroundTime = true
            guard total > 0 else { return }
            progress = Float(done) / Float(total)
            statusText = "\(done * 100 / total)% complete"
        case .failed(let names):
            hasSeenRun = true
            wantsBackgroundTime = false
            isUnreadableTrash = false
            failureTitle = "Some Files Failed"
            // No names: a step other than a file failed (listing the files, or a closing step).
            failureMessage =
                names.isEmpty
                ? "Some files couldn't be encrypted."
                : "These files couldn't be encrypted: \(names.joined(separator: ", "))"
        case .completed:
            clearFailure()
            wantsBackgroundTime = false
            isFinishing = true
            progress = 1
            statusText = "Complete"
        case .unreadableTrash:
            hasSeenRun = true
            wantsBackgroundTime = false
            isUnreadableTrash = true
            failureTitle = "Some Deleted Items Can't Be Read"
            failureMessage =
                "They were encrypted with a key this vault no longer has, so they can never be restored "
                + "or opened. Clear them to continue."
        }
    }

    private func clearFailure() {
        failureTitle = nil
        failureMessage = nil
        isUnreadableTrash = false
    }

    private func finish(fully: Bool) async {
        do {
            try await sleep(.milliseconds(500))
        } catch {
            // Only cancellation throws here: the screen went away, so there is nothing to report to.
            return
        }
        onFinish(fully)
    }
}
