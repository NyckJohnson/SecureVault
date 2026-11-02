import Foundation
import os

@testable import KoalaTVault

/// A controllable stand-in for `Task.sleep`: every sleep suspends until `advance()` (or cancellation).
final class ViewerManualSleeper: Sendable {
    private struct State {
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var cancelled: Set<UUID> = []
        var durations: [Duration] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The durations of every sleep that began and was not cancelled before it started, in order.
    var requestedDurations: [Duration] { state.withLock { $0.durations } }

    /// How many sleeps are suspended right now.
    var pendingCount: Int { state.withLock { $0.waiters.count } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyCancelled = state.withLock { state -> Bool in
                    if state.cancelled.contains(id) { return true }
                    state.waiters[id] = continuation
                    state.durations.append(duration)
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
                state.cancelled.insert(id)
                return state.waiters.removeValue(forKey: id)
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Lets every suspended sleep finish normally.
    func advance() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            let all = Array(state.waiters.values)
            state.waiters = [:]
            return all
        }
        for waiter in waiters { waiter.resume() }
    }
}

enum ViewerTestSupport {
    /// Yields (and, rarely, sleeps a millisecond) until `condition` holds or the attempts run out.
    @MainActor
    static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<3000 {
            if condition() { return }
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Gives pending main-actor work a chance to run, for asserting that something did NOT happen.
    @MainActor
    static func settle() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    static func makeItem(
        _ name: String, isDirectory: Bool = false, isEncrypted: Bool = false
    ) -> VaultItem {
        let root = URL(fileURLWithPath: "/tmp/ViewerTestsRoot", isDirectory: true)
        return VaultItem(
            id: name, name: name, isDirectory: isDirectory, dateModified: Date(), fileSize: isDirectory ? nil : 1,
            deletedAt: nil, diskURL: root.appendingPathComponent(name, isDirectory: isDirectory), rootURL: root,
            isEncrypted: isEncrypted)
    }
}
