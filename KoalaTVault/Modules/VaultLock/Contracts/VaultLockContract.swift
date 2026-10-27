import Foundation

// coverage-exempt-file: declarations only

/// Whether the vault is open (no lock), locked (no key) or unlocked (key loaded).
enum LockState: Sendable, Equatable {
    case open, locked, unlocked
}

/// The device's biometric type.
enum BiometricKind: Sendable, Equatable {
    case none, faceID, touchID
}

/// Errors thrown by the vault lock.
enum VaultLockError: Error, Equatable, Sendable {
    case wrongPassword, existingPasswordRequired, emptyPassword, passwordMissing, notUnlocked
    case biometricsUnavailable, biometricCancelled, biometryLockedOut, biometryNotEnrolled, passcodeNotSet
    case biometricChanged, keychain(Int32)
}

/// The key lifecycle and lock state.
@MainActor
protocol VaultLocking: AnyObject, Sendable {
    /// The current lock state.
    var state: LockState { get }
    /// The current lock mode.
    var lockMode: LockMode { get }
    /// The device's biometric type.
    var biometricKind: BiometricKind { get }
    /// Whether biometrics can be used now.
    var biometricsAvailable: Bool { get }
    /// Each change of `state`, once.
    func stateUpdates() -> AsyncStream<LockState>
    /// Sets up the first lock mode (from the setup wizard).
    func setUp(mode: LockMode, password: String?) async throws
    /// Unlocks with the password.
    func unlock(password: String) async throws
    /// Unlocks with Face ID / Touch ID.
    func unlockWithBiometrics() async throws
    /// Returns whether the privacy cover should show.
    func appWillResignActive() -> Bool
    /// Wipes the key and temp files when a lock is set.
    func appDidEnterBackground()
    /// Updates the state when the app returns.
    func appWillEnterForeground()
    /// Changes the password after verifying the current one.
    func changePassword(current: String, new: String) async throws
    /// Switches between password and password + biometrics.
    func switchMode(to mode: LockMode) async throws
    /// Adds a lock before an encrypt migration.
    func prepareToAddLock(mode: LockMode, password: String) async throws
    /// Removes the keys and the lock after a decrypt migration.
    func removeKeysAfterDecryption() async throws
}
