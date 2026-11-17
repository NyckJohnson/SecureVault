import Foundation

/// The files of one migration pass and how far it got: `done` of `total` processed, plus the failed files.
struct MigrationProgress: Sendable, Equatable {
    /// The files of this pass, in the order the store listed them.
    var items: [VaultItem] = []
    /// How many of `items` have been processed (migrated or failed).
    private(set) var done = 0
    /// The files that failed in this pass, in listed order.
    private(set) var failed: [VaultItem] = []

    /// How many files this pass covers.
    var total: Int { items.count }
    /// The next file to process, or nil when the pass is through.
    var next: VaultItem? { done < items.count ? items[done] : nil }

    /// The next file migrated.
    mutating func advance() {
        done += 1
    }

    /// The next file failed: it is collected and counted as processed.
    mutating func fail() {
        guard let item = next else { return }
        failed.append(item)
        done += 1
    }

    /// A new pass over just the failed files.
    mutating func restartWithFailed() {
        items = failed
        done = 0
        failed = []
    }

    var running: MigrationPhase { .running(done: done, total: total) }
    var failedPhase: MigrationPhase { .failed(names: failed.map(\.name)) }
}

/// Holds the current phase and publishes each change of it, once, to every subscriber.
@MainActor
final class MigrationPhaseBroadcast {
    /// The current phase.
    private(set) var phase: MigrationPhase = .idle

    private var continuations: [UUID: AsyncStream<MigrationPhase>.Continuation] = [:]

    /// Sets the phase; subscribers hear about it only if it changed.
    func update(_ newPhase: MigrationPhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        for continuation in continuations.values { continuation.yield(newPhase) }
    }

    /// A stream of every later phase change; it unsubscribes itself when the consumer stops.
    func updates() -> AsyncStream<MigrationPhase> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.continuations[id] = nil }
            }
        }
    }
}
