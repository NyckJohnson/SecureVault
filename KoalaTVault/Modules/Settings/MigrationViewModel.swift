import Combine
import Foundation

/// The logic of the migration screen: shows what the app's one `LockMigrating` reports, forwards Retry and
/// Skip, and reports the end once.
@MainActor
final class MigrationViewModel: ObservableObject {
    /// The screen's title.
    let title: String
    /// The status line.
    @Published private(set) var statusText = "Preparing…"
    /// How far the migration is, from 0 to 1.
    @Published private(set) var progress: Float = 0
    /// The failure alert's title, while files have failed.
    @Published private(set) var failureTitle: String?
    /// The failure alert's message, while files have failed.
    @Published private(set) var failureMessage: String?
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

    /// - Parameters:
    ///   - kind: encrypt or decrypt; sets the title.
    ///   - migrator: the app's one lock migration.
    ///   - waitsForNewRun: true when the caller starts a migration right after making this: a `.completed`
    ///     or `.idle` phase at hand then belongs to an earlier migration and is ignored. False when showing
    ///     a resume, where `.completed` is this migration's end.
    ///   - sleep: waits before reporting the end (a stand-in in tests).
    ///   - onFinish: called once at the end, with whether the migration completed fully.
    init(
        kind: MigrationKind, migrator: any LockMigrating, waitsForNewRun: Bool = false,
        sleep: @escaping @Sendable (Duration) async throws -> Void = MigrationViewModel.liveSleep,
        onFinish: @escaping @MainActor (Bool) -> Void
    ) {
        title = kind == .encrypt ? "Encrypting Files" : "Decrypting Files"
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
    /// the first call does anything: a screen appears again when a lock screen is dismissed over it.
    func run() async {
        guard !hasStartedRunning else { return }
        hasStartedRunning = true
        if case .completed(let fully) = initialPhase {
            await finish(fully: fully)
            return
        }
        for await phase in phases {
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

    // MARK: - Private

    private func apply(_ phase: MigrationPhase) {
        guard !isFinishing else { return }
        switch phase {
        case .idle:
            break
        case .running(let done, let total):
            clearFailure()
            wantsBackgroundTime = true
            guard total > 0 else { return }
            progress = Float(done) / Float(total)
            statusText = "\(done * 100 / total)% complete"
        case .paused(let done, let total):
            clearFailure()
            wantsBackgroundTime = false
            if total > 0 {
                progress = Float(done) / Float(total)
            }
            statusText = "Paused — unlock to continue"
        case .failed(let names):
            wantsBackgroundTime = false
            failureTitle = "Some Files Failed"
            // No names: a step other than a file failed (listing the files, or a closing step).
            failureMessage =
                names.isEmpty
                ? "The migration couldn't finish. Retry, or Skip to stop for now."
                : "These files couldn't be migrated: \(names.joined(separator: ", "))"
        case .completed:
            clearFailure()
            wantsBackgroundTime = false
            isFinishing = true
            progress = 1
            statusText = "Complete"
        }
    }

    private func clearFailure() {
        failureTitle = nil
        failureMessage = nil
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
