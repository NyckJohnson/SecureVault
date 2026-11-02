import Foundation
import UIKit

@testable import KoalaTVault

/// A failure with a fixed message, to check that other errors show their own text.
struct StubFailure: LocalizedError {
    var errorDescription: String? { "The disk is full." }
}

/// Wraps a `MockVaultLocking` and adds what the mock cannot do: throw a chosen error from
/// `setUp` / `unlock`, and hold `setUp` / `unlock` open until the test releases them.
@MainActor
final class ScriptedVaultLock: VaultLocking {
    let inner: MockVaultLocking
    var setUpError: (any Error)?
    var unlockError: (any Error)?
    var holdsSetUp = false
    var holdsUnlock = false
    /// True while a held call waits for `releaseHeldCall()`.
    private(set) var isHoldingCall = false
    private(set) var setUpModes: [LockMode] = []
    private(set) var setUpPasswords: [String?] = []
    private var heldContinuation: CheckedContinuation<Void, Never>?

    init(inner: MockVaultLocking? = nil) {
        self.inner = inner ?? MockVaultLocking(lockMode: .none)
    }

    var state: LockState { inner.state }
    var lockMode: LockMode { inner.lockMode }
    var biometricKind: BiometricKind { inner.biometricKind }
    var biometricsAvailable: Bool { inner.biometricsAvailable }

    func releaseHeldCall() {
        heldContinuation?.resume()
        heldContinuation = nil
    }

    func stateUpdates() -> AsyncStream<LockState> { inner.stateUpdates() }

    func setUp(mode: LockMode, password: String?) async throws {
        setUpModes.append(mode)
        setUpPasswords.append(password)
        await holdIfNeeded(holdsSetUp)
        if let setUpError { throw setUpError }
        try await inner.setUp(mode: mode, password: password)
    }

    func unlock(password: String) async throws {
        await holdIfNeeded(holdsUnlock)
        if let unlockError { throw unlockError }
        try await inner.unlock(password: password)
    }

    func unlockWithBiometrics() async throws { try await inner.unlockWithBiometrics() }
    func appWillResignActive() -> Bool { inner.appWillResignActive() }
    func appDidEnterBackground() { inner.appDidEnterBackground() }
    func appWillEnterForeground() { inner.appWillEnterForeground() }

    func changePassword(current: String, new: String) async throws {
        try await inner.changePassword(current: current, new: new)
    }

    func switchMode(to mode: LockMode) async throws { try await inner.switchMode(to: mode) }

    func prepareToAddLock(mode: LockMode, password: String) async throws {
        try await inner.prepareToAddLock(mode: mode, password: password)
    }

    func removeKeysAfterDecryption() async throws { try await inner.removeKeysAfterDecryption() }

    private func holdIfNeeded(_ shouldHold: Bool) async {
        guard shouldHold else { return }
        isHoldingCall = true
        await withCheckedContinuation { heldContinuation = $0 }
        isHoldingCall = false
    }
}

/// A `LockPresenting` that records what the coordinator asks for instead of touching UIKit.
@MainActor
final class RecordingLockPresenter: LockPresenting {
    /// A recorded request.
    enum Request: Equatable {
        case presentSetupWizard
        case presentLockScreen
        case dismissSetupWizard
        case dismissLockScreen
        case showPrivacyCover
        case hidePrivacyCover
    }

    private(set) var requests: [Request] = []
    private(set) var setupViewModels: [SetupWizardViewModel] = []
    private(set) var lockViewModels: [LockScreenViewModel] = []
    /// Runs at the moment the lock screen is presented.
    var onPresentLockScreen: (() -> Void)?

    func count(of request: Request) -> Int {
        requests.filter { $0 == request }.count
    }

    func presentSetupWizard(_ viewModel: SetupWizardViewModel, in window: UIWindow) {
        requests.append(.presentSetupWizard)
        setupViewModels.append(viewModel)
    }

    func presentLockScreen(_ viewModel: LockScreenViewModel, in window: UIWindow) {
        onPresentLockScreen?()
        requests.append(.presentLockScreen)
        lockViewModels.append(viewModel)
    }

    func dismissSetupWizard() { requests.append(.dismissSetupWizard) }
    func dismissLockScreen() { requests.append(.dismissLockScreen) }
    func showPrivacyCover(in window: UIWindow) { requests.append(.showPrivacyCover) }
    func hidePrivacyCover() { requests.append(.hidePrivacyCover) }
}

/// Polls (yielding to other tasks) until the condition holds; false if it never does.
@MainActor
func waitForCondition(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
