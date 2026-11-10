import Foundation

/// A vault lock held in memory with a known password; records every call.
@MainActor
final class MockVaultLocking: VaultLocking {
    /// A recorded call.
    enum Call: Equatable, Sendable {
        case stateUpdates
        case setUp(LockMode)
        case unlock
        case unlockWithBiometrics
        case appWillResignActive
        case appDidEnterBackground
        case appWillEnterForeground
        case changePassword
        case switchMode(LockMode)
        case prepareToAddLock(LockMode)
        case removeKeysAfterDecryption
    }

    /// Every call so far, in order.
    private(set) var calls: [Call] = []
    /// The password that unlocks the vault; nil means no password blob.
    var password: String?
    /// When set, `unlockWithBiometrics()` throws this error.
    var biometricError: VaultLockError?

    private(set) var state: LockState {
        didSet {
            guard state != oldValue else { return }
            for continuation in continuations.values { continuation.yield(state) }
        }
    }
    private(set) var lockMode: LockMode
    var biometricKind: BiometricKind
    var biometricsAvailable: Bool

    private var continuations: [UUID: AsyncStream<LockState>.Continuation] = [:]

    /// A lock in `lockMode`, locked when a lock is set, with Face ID available by default.
    init(
        lockMode: LockMode = .password,
        password: String? = "correct horse",
        biometricKind: BiometricKind = .faceID,
        biometricsAvailable: Bool = true
    ) {
        self.lockMode = lockMode
        self.password = password
        self.biometricKind = biometricKind
        self.biometricsAvailable = biometricsAvailable
        state = lockMode == .none ? .open : .locked
    }

    func stateUpdates() -> AsyncStream<LockState> {
        calls.append(.stateUpdates)
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.continuations[id] = nil }
            }
        }
    }

    func setUp(mode: LockMode, password: String?) async throws {
        calls.append(.setUp(mode))
        guard mode != .none else {
            lockMode = .none
            state = .open
            return
        }
        guard let password, !password.isEmpty else { throw VaultLockError.emptyPassword }
        if mode == .passwordAndBiometrics && !biometricsAvailable { throw VaultLockError.biometricsUnavailable }
        self.password = password
        lockMode = mode
        state = .unlocked
    }

    func unlock(password: String) async throws {
        calls.append(.unlock)
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        guard let stored = self.password else { throw VaultLockError.passwordMissing }
        guard stored == password else { throw VaultLockError.wrongPassword }
        state = .unlocked
    }

    func unlockWithBiometrics() async throws {
        calls.append(.unlockWithBiometrics)
        guard lockMode == .passwordAndBiometrics else { throw VaultLockError.biometricsUnavailable }
        if let biometricError { throw biometricError }
        state = .unlocked
    }

    func appWillResignActive() -> Bool {
        calls.append(.appWillResignActive)
        return lockMode != .none && state == .unlocked
    }

    func appDidEnterBackground() {
        calls.append(.appDidEnterBackground)
        if lockMode != .none { state = .locked }
    }

    func appWillEnterForeground() {
        calls.append(.appWillEnterForeground)
        if lockMode == .none { state = .open }
    }

    func changePassword(current: String, new: String) async throws {
        calls.append(.changePassword)
        guard current == password else { throw VaultLockError.wrongPassword }
        guard !new.isEmpty else { throw VaultLockError.emptyPassword }
        password = new
    }

    func switchMode(to mode: LockMode) async throws {
        calls.append(.switchMode(mode))
        guard mode != .none, lockMode != .none, state == .unlocked else { throw VaultLockError.notUnlocked }
        if mode == .passwordAndBiometrics && !biometricsAvailable { throw VaultLockError.biometricsUnavailable }
        lockMode = mode
    }

    func prepareToAddLock(mode: LockMode, password: String) async throws {
        calls.append(.prepareToAddLock(mode))
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        if let stored = self.password, stored != password { throw VaultLockError.existingPasswordRequired }
        self.password = password
        lockMode = mode
        state = .unlocked
    }

    func removeKeysAfterDecryption() async throws {
        calls.append(.removeKeysAfterDecryption)
        lockMode = .none
        password = nil
        state = .open
    }
}
