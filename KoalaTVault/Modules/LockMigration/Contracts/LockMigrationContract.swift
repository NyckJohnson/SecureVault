import Foundation

// coverage-exempt-file: declarations only

/// Where a lock migration is.
enum MigrationPhase: Sendable, Equatable {
    case idle
    case running(done: Int, total: Int)
    case paused(done: Int, total: Int)
    case failed(names: [String])
    case completed(fully: Bool)
}

/// Encrypts or decrypts the whole vault when a lock is added or removed.
@MainActor
protocol LockMigrating: AnyObject, Sendable {
    /// The current phase.
    var phase: MigrationPhase { get }
    /// The persisted migration in progress, if any.
    var pending: PendingMigration? { get }
    /// Each change of `phase`.
    func phaseUpdates() -> AsyncStream<MigrationPhase>
    /// Starts a migration; `target` is the lock mode an encrypt migration ends in.
    func start(_ kind: MigrationKind, target: LockMode?) async
    /// Continues a persisted migration, if any.
    func resumeIfPending() async
    /// Migrates the failed files again.
    func retryFailed() async
    /// Gives up on the failed files.
    func skipFailed() async
}
