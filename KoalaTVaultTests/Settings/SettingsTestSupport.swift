import Foundation
import UIKit
import os

@testable import KoalaTVault

/// Collects the values a view model passes to a callback.
@MainActor
final class SettingsRecorder<Value> {
    private(set) var values: [Value] = []

    func record(_ value: Value) {
        values.append(value)
    }
}

/// Holds a call open until the test releases it.
@MainActor
final class SettingsGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            continuation = waiter
        }
        isWaiting = false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

enum SettingsTestSupport {
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

    /// Whether the lock was asked to change anything.
    @MainActor
    static func changedLock(_ lock: MockVaultLocking) -> Bool {
        lock.calls.contains { call in
            switch call {
            case .stateUpdates, .unlock, .unlockWithBiometrics, .appWillResignActive,
                .appDidEnterBackground, .appWillEnterForeground:
                false
            default:
                true
            }
        }
    }
}

/// A controllable stand-in for `Task.sleep`: every sleep suspends until `advance()` (or cancellation).
final class SettingsManualSleeper: Sendable {
    private struct State {
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var cancelled: Set<UUID> = []
        var durations: [Duration] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The durations of every sleep that began, in order.
    var requestedDurations: [Duration] { state.withLock { $0.durations } }

    /// How many sleeps are suspended right now.
    var pendingCount: Int { state.withLock { $0.waiters.count } }

    func sleep(_ duration: Duration) async throws {
        let sleepID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyCancelled = state.withLock { state -> Bool in
                    if state.cancelled.contains(sleepID) { return true }
                    state.waiters[sleepID] = continuation
                    state.durations.append(duration)
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
                state.cancelled.insert(sleepID)
                return state.waiters.removeValue(forKey: sleepID)
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

/// A failure with a fixed message, to check that other errors show their own text.
struct SettingsStubFailure: LocalizedError {
    var errorDescription: String? { "The disk is full." }
}

/// Wraps a `MockVaultLocking` and adds what the mock cannot do: throw a chosen error from
/// `changePassword` / `prepareToAddLock`, and hold `changePassword` open until the test releases it.
@MainActor
final class SettingsScriptedLock: VaultLocking {
    let inner: MockVaultLocking
    var changePasswordError: (any Error)?
    var prepareToAddLockError: (any Error)?
    var holdsChangePassword = false
    let changePasswordGate = SettingsGate()

    init(inner: MockVaultLocking) {
        self.inner = inner
    }

    var state: LockState { inner.state }
    var lockMode: LockMode { inner.lockMode }
    var biometricKind: BiometricKind { inner.biometricKind }
    var biometricsAvailable: Bool { inner.biometricsAvailable }

    func stateUpdates() -> AsyncStream<LockState> { inner.stateUpdates() }
    func setUp(mode: LockMode, password: String?) async throws { try await inner.setUp(mode: mode, password: password) }
    func unlock(password: String) async throws { try await inner.unlock(password: password) }
    func unlockWithBiometrics() async throws { try await inner.unlockWithBiometrics() }
    func appWillResignActive() -> Bool { inner.appWillResignActive() }
    func appDidEnterBackground() { inner.appDidEnterBackground() }
    func appWillEnterForeground() { inner.appWillEnterForeground() }
    func switchMode(to mode: LockMode) async throws { try await inner.switchMode(to: mode) }
    func removeKeysAfterDecryption() async throws { try await inner.removeKeysAfterDecryption() }

    func changePassword(current: String, new: String) async throws {
        if holdsChangePassword { await changePasswordGate.wait() }
        if let changePasswordError { throw changePasswordError }
        try await inner.changePassword(current: current, new: new)
    }

    func prepareToAddLock(mode: LockMode, password: String) async throws {
        if let prepareToAddLockError { throw prepareToAddLockError }
        try await inner.prepareToAddLock(mode: mode, password: password)
    }
}

/// Wraps a `MockProUnlocking` and adds a chosen thrown error and held purchase / restore calls.
@MainActor
final class SettingsScriptedPro: ProUnlocking {
    let inner: MockProUnlocking
    var purchaseError: (any Error)?
    var restoreError: (any Error)?
    var holdsCalls = false
    let gate = SettingsGate()

    init(inner: MockProUnlocking) {
        self.inner = inner
    }

    var isUnlocked: Bool { inner.isUnlocked }
    nonisolated var isUnlockedNow: Bool { inner.isUnlockedNow }

    func displayPrice() async -> String? { await inner.displayPrice() }
    func refresh() async { await inner.refresh() }
    func unlockedUpdates() -> AsyncStream<Bool> { inner.unlockedUpdates() }

    func purchase(confirmIn scene: UIScene?) async throws -> PurchaseOutcome {
        if holdsCalls { await gate.wait() }
        if let purchaseError { throw purchaseError }
        return try await inner.purchase(confirmIn: scene)
    }

    func restore() async throws -> Bool {
        if holdsCalls { await gate.wait() }
        if let restoreError { throw restoreError }
        return try await inner.restore()
    }
}

/// A `LockMigrating` whose phases the test sends by hand; records every call.
@MainActor
final class SettingsScriptedMigrator: LockMigrating {
    enum Call: Equatable {
        case phaseUpdates
        case start(MigrationKind, LockMode?)
        case resumeIfPending
        case retryFailed
        case skipFailed
    }

    private(set) var calls: [Call] = []
    private(set) var phase: MigrationPhase
    var pending: PendingMigration?
    /// The phase sent when `retryFailed()` is called, if any.
    var phaseAfterRetry: MigrationPhase?
    /// The phase sent when `skipFailed()` is called, if any.
    var phaseAfterSkip: MigrationPhase?

    private var continuations: [UUID: AsyncStream<MigrationPhase>.Continuation] = [:]

    init(phase: MigrationPhase = .idle) {
        self.phase = phase
    }

    func send(_ newPhase: MigrationPhase) {
        phase = newPhase
        for continuation in continuations.values { continuation.yield(newPhase) }
    }

    func phaseUpdates() -> AsyncStream<MigrationPhase> {
        calls.append(.phaseUpdates)
        let streamID = UUID()
        return AsyncStream { continuation in
            continuations[streamID] = continuation
        }
    }

    func start(_ kind: MigrationKind, target: LockMode?) async {
        calls.append(.start(kind, target))
    }

    func resumeIfPending() async {
        calls.append(.resumeIfPending)
    }

    func retryFailed() async {
        calls.append(.retryFailed)
        if let phaseAfterRetry { send(phaseAfterRetry) }
    }

    func skipFailed() async {
        calls.append(.skipFailed)
        if let phaseAfterSkip { send(phaseAfterSkip) }
    }
}
