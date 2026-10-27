import Foundation

/// A lock migration that runs through a fixed number of files at once; records every call.
@MainActor
final class MockLockMigrating: LockMigrating {
    /// A recorded call.
    enum Call: Equatable, Sendable {
        case phaseUpdates
        case start(MigrationKind, target: LockMode?)
        case resumeIfPending
        case retryFailed
        case skipFailed
    }

    /// Every call so far, in order.
    private(set) var calls: [Call] = []
    /// How many files a migration processes.
    var fileCount: Int
    /// Display names of the files that fail on the first pass.
    var failingNames: [String]

    private(set) var phase: MigrationPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            for continuation in continuations.values { continuation.yield(phase) }
        }
    }
    private(set) var pending: PendingMigration?

    private var continuations: [UUID: AsyncStream<MigrationPhase>.Continuation] = [:]

    /// A migration of `fileCount` files, of which `failingNames` fail, optionally already pending.
    init(fileCount: Int = 12, failingNames: [String] = [], pending: PendingMigration? = nil) {
        self.fileCount = fileCount
        self.failingNames = failingNames
        self.pending = pending
    }

    func phaseUpdates() -> AsyncStream<MigrationPhase> {
        calls.append(.phaseUpdates)
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.continuations[id] = nil }
            }
        }
    }

    func start(_ kind: MigrationKind, target: LockMode?) async {
        calls.append(.start(kind, target: target))
        guard !isRunning else { return }
        pending = PendingMigration(kind: kind, targetLockMode: kind == .encrypt ? target : nil)
        run()
    }

    func resumeIfPending() async {
        calls.append(.resumeIfPending)
        guard pending != nil, !isRunning else { return }
        run()
    }

    func retryFailed() async {
        calls.append(.retryFailed)
        guard case .failed = phase else { return }
        failingNames = []
        phase = .completed(fully: true)
        pending = nil
    }

    func skipFailed() async {
        calls.append(.skipFailed)
        guard case .failed = phase else { return }
        phase = .completed(fully: false)
        pending = nil
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private func run() {
        for done in 0...fileCount {
            phase = .running(done: done, total: fileCount)
        }
        if failingNames.isEmpty {
            phase = .completed(fully: true)
            pending = nil
        } else {
            phase = .failed(names: failingNames)
        }
    }
}
