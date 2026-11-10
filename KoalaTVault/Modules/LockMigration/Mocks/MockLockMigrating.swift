import Foundation

/// An encryption of leftover files that runs through a fixed number of files at once; records every call.
@MainActor
final class MockLockMigrating: LockMigrating {
    /// A recorded call.
    enum Call: Equatable, Sendable {
        case phaseUpdates
        case encryptLeftovers(root: String)
        case retryFailed
        case skipFailed
        case clearUnreadableTrash
        case cancel
    }

    /// Every call so far, in order.
    private(set) var calls: [Call] = []
    /// How many files a run processes.
    var fileCount: Int
    /// Display names of the files that fail on the first pass.
    var failingNames: [String]
    /// When true, a pass ends in `.unreadableTrash` instead of `.failed` or `.completed`;
    /// `clearUnreadableTrash()` resets it and runs again.
    var unreadableTrash: Bool

    private(set) var phase: MigrationPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            for continuation in continuations.values { continuation.yield(phase) }
        }
    }

    private var continuations: [UUID: AsyncStream<MigrationPhase>.Continuation] = [:]

    /// A run over `fileCount` files, of which `failingNames` fail.
    init(fileCount: Int = 12, failingNames: [String] = [], unreadableTrash: Bool = false) {
        self.fileCount = fileCount
        self.failingNames = failingNames
        self.unreadableTrash = unreadableTrash
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

    func encryptLeftovers(in store: any VaultStoring) async {
        calls.append(.encryptLeftovers(root: store.root.name))
        guard store.isEncrypted, !hasRun else { return }
        run()
    }

    func retryFailed() async {
        calls.append(.retryFailed)
        guard case .failed = phase else { return }
        failingNames = []
        phase = .completed(fully: true)
    }

    func skipFailed() async {
        calls.append(.skipFailed)
        switch phase {
        case .failed, .unreadableTrash: break
        default: return
        }
        phase = .completed(fully: false)
    }

    func clearUnreadableTrash() async {
        calls.append(.clearUnreadableTrash)
        guard phase == .unreadableTrash else { return }
        unreadableTrash = false
        run()
    }

    func cancel() {
        calls.append(.cancel)
        phase = .idle
    }

    /// A run exists: running, failed or awaiting the unreadable-trash choice.
    private var hasRun: Bool {
        switch phase {
        case .running, .failed, .unreadableTrash: true
        default: false
        }
    }

    private func run() {
        for done in 0...fileCount {
            phase = .running(done: done, total: fileCount)
        }
        if unreadableTrash {
            phase = .unreadableTrash
        } else if failingNames.isEmpty {
            phase = .completed(fully: true)
        } else {
            phase = .failed(names: failingNames)
        }
    }
}
