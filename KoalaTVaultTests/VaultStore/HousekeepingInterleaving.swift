import Foundation
import os

@testable import KoalaTVault

/// Stops a store operation inside its first cipher call, so a test can queue another store operation while the
/// first one is demonstrably in progress, then lets it continue. No timing thresholds decide the outcome: the
/// bounded waits only keep a monolithic implementation (which cannot be interleaved) from hanging the test.
///
/// Install `pass()` as a cipher hook (`decryptErrorFor`, `onFirstStreamInfo`). Only the first call blocks.
final class HousekeepingGate: Sendable {
    private struct State {
        var calls = 0
        var entered = false
    }

    private let released = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let waits: Bool
    private let onEnter: @Sendable () -> Void

    /// - Parameter waits: false makes the first call only run `onEnter` and carry on (no blocking).
    /// - Parameter onEnter: runs inside the store's step at the first cipher call (e.g. to remove folders).
    init(waits: Bool = true, onEnter: @escaping @Sendable () -> Void = {}) {
        self.waits = waits
        self.onEnter = onEnter
    }

    /// Called from the cipher hook.
    func pass() {
        let first = state.withLock { state -> Bool in
            state.calls += 1
            guard state.calls == 1 else { return false }
            state.entered = true
            return true
        }
        guard first else { return }
        onEnter()
        guard waits else { return }
        // Wait for the test to queue its operation, then give it a moment to reach the store's queue.
        if released.wait(timeout: .now() + 3) == .success { Thread.sleep(forTimeInterval: 0.2) }
    }

    /// Whether the hook has been reached, polled (bounded) until it is.
    func waitUntilEntered() async -> Bool {
        for _ in 0..<600 {
            if state.withLock({ $0.entered }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Lets the blocked step continue.
    func release() { released.signal() }
}

/// A one-shot signal a test task raises when it is about to do something, so the test waits for the fact
/// instead of sleeping for a guessed time.
final class Signal: Sendable {
    private let raised = OSAllocatedUnfairLock(initialState: false)
    func raise() { raised.withLock { $0 = true } }

    /// Whether the signal was raised, polled (bounded) until it is.
    func waitUntilRaised() async -> Bool {
        for _ in 0..<600 {
            if raised.withLock({ $0 }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

/// Thread-safe, ordered record of what finished when.
final class EventLog: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ event: String) { lock.withLock { $0.append(event) } }
    var events: [String] { lock.withLock { $0 } }
}
