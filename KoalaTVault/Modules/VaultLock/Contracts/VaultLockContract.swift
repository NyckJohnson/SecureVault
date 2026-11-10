import Foundation

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

extension VaultLockError: LocalizedError {
    /// The error's user-facing description; `.keychain` includes the status number.
    var errorDescription: String? {
        switch self {
        case .wrongPassword: "Incorrect password"
        case .existingPasswordRequired: "A vault password already exists on this device. Enter that password."
        case .emptyPassword: "Password cannot be empty"
        case .passwordMissing: "Your vault password is missing from this device."
        case .notUnlocked: "Unlock the vault first."
        case .biometricsUnavailable: "Biometric authentication isn't available on this device."
        case .biometricCancelled, .biometryLockedOut, .biometryNotEnrolled, .passcodeNotSet, .biometricChanged:
            "Biometric authentication failed"
        case .keychain(let status): "A Keychain error occurred (\(status))."
        }
    }
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
