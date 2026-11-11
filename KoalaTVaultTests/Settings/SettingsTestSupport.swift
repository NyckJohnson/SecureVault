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

/// Wraps a `MockVaultLocking` and adds what the mock cannot do: throw any error (not only a `VaultLockError`) from
/// `changePassword`, `setUsesBiometrics` and `deleteCurrentVault`, and hold those calls open until released.
@MainActor
final class SettingsScriptedLock: VaultLocking {
    let inner: MockVaultLocking
    var changePasswordError: (any Error)?
    var setUsesBiometricsError: (any Error)?
    var deleteError: (any Error)?
    var holdsCalls = false
    let gate = SettingsGate()
    private(set) var deletedPasswords: [String] = []

    init(inner: MockVaultLocking) {
        self.inner = inner
    }

    var current: OpenVault { inner.current }
    var unencryptedVault: OpenVault { inner.unencryptedVault }
    var biometricKind: BiometricKind { inner.biometricKind }
    var biometricsAvailable: Bool { inner.biometricsAvailable }
    var hasBiometricVault: Bool { inner.hasBiometricVault }
    var currentUsesBiometrics: Bool { inner.currentUsesBiometrics }

    func currentUpdates() -> AsyncStream<OpenVault> { inner.currentUpdates() }
    func upgradeIfNeeded() async throws { try await inner.upgradeIfNeeded() }
    func canCreateVault() async -> Bool { await inner.canCreateVault() }
    func createVault(name: String, password: String) async throws {
        try await inner.createVault(name: name, password: password)
    }
    func open(password: String) async throws { try await inner.open(password: password) }
    func openWithBiometrics() async throws { try await inner.openWithBiometrics() }
    func close() { inner.close() }
    func appWillResignActive() -> Bool { inner.appWillResignActive() }
    func appDidEnterBackground() { inner.appDidEnterBackground() }
    func openTransferTarget(password: String) async throws -> OpenVault {
        try await inner.openTransferTarget(password: password)
    }
    func closeTransferTarget(_ vault: OpenVault) { inner.closeTransferTarget(vault) }

    func changePassword(current: String, new: String) async throws {
        if holdsCalls { await gate.wait() }
        if let changePasswordError { throw changePasswordError }
        try await inner.changePassword(current: current, new: new)
    }

    func setUsesBiometrics(_ enabled: Bool) async throws {
        if holdsCalls { await gate.wait() }
        if let setUsesBiometricsError { throw setUsesBiometricsError }
        try await inner.setUsesBiometrics(enabled)
    }

    func deleteCurrentVault(password: String) async throws {
        deletedPasswords.append(password)
        if holdsCalls { await gate.wait() }
        if let deleteError { throw deleteError }
        try await inner.deleteCurrentVault(password: password)
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
        case retryFailed
        case skipFailed
        case clearUnreadableTrash
        case encryptLeftovers
        case cancel
    }

    private(set) var calls: [Call] = []
    private(set) var phase: MigrationPhase
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

    func encryptLeftovers(in store: any VaultStoring) async {
        calls.append(.encryptLeftovers)
    }

    func cancel() {
        calls.append(.cancel)
    }

    func retryFailed() async {
        calls.append(.retryFailed)
        if let phaseAfterRetry { send(phaseAfterRetry) }
    }

    func skipFailed() async {
        calls.append(.skipFailed)
        if let phaseAfterSkip { send(phaseAfterSkip) }
    }

    func clearUnreadableTrash() async {
        calls.append(.clearUnreadableTrash)
    }
}
