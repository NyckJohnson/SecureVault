import Foundation

/// The device's biometric type.
enum BiometricKind: Sendable, Equatable {
    case none, faceID, touchID
}

/// A vault ready to use: the unencrypted vault, or an encrypted vault whose key is loaded.
struct OpenVault: Sendable {
    /// "unencrypted", "primary" (the upgraded vault) or a UUID string.
    let id: String
    let name: String
    let isEncrypted: Bool
    let store: any VaultStoring
}

/// Errors thrown by the vault lock.
enum VaultLockError: Error, Equatable, Sendable {
    case wrongPassword, emptyPassword, emptyName, passwordInUse, vaultLimitReached, sameVault, notOpen
    case biometricsUnavailable, noBiometricVault
    case biometricCancelled, biometryLockedOut, biometryNotEnrolled, passcodeNotSet, biometricChanged
    case keychain(Int32), io(String)  // swiftlint:disable:this identifier_name
}

extension VaultLockError: LocalizedError {
    /// The error's user-facing description; `.keychain` includes the status number, `.io` is its message.
    var errorDescription: String? {
        switch self {
        case .wrongPassword: "Incorrect password"
        case .emptyPassword: "Password cannot be empty"
        case .emptyName: "Enter a name for the vault"
        case .passwordInUse: "Choose a different password."
        case .vaultLimitReached: "More vaults with Pro."
        case .sameVault: "These items are already in this vault."
        case .notOpen: "Open a vault first."
        case .biometricsUnavailable: "Biometric authentication isn't available on this device."
        case .noBiometricVault: "No vault uses Face ID."
        case .biometricCancelled, .biometryLockedOut, .biometryNotEnrolled, .passcodeNotSet, .biometricChanged:
            "Biometric authentication failed"
        case .keychain(let status): "A Keychain error occurred (\(status))."
        case .io(let message): message
        }
    }
}

/// The vaults: which vault is open, the unencrypted vault, opening, creating, closing and deleting encrypted
/// vaults, their passwords and Face ID, the transfer target, closing on background, and the one-time upgrade.
@MainActor
protocol VaultLocking: AnyObject, Sendable {
    /// The open vault (the unencrypted vault at launch).
    var current: OpenVault { get }
    /// The unencrypted vault, always there.
    var unencryptedVault: OpenVault { get }
    /// Each change of `current`, once.
    func currentUpdates() -> AsyncStream<OpenVault>
    /// The device's biometric type.
    var biometricKind: BiometricKind { get }
    /// Whether biometrics can be used now.
    var biometricsAvailable: Bool { get }
    /// Whether a listed vault uses Face ID.
    var hasBiometricVault: Bool { get }
    /// Whether `current` is the vault that uses Face ID.
    var currentUsesBiometrics: Bool { get }
    /// Upgrades a 1.2 vault once, at launch.
    func upgradeIfNeeded() async throws
    /// Whether a new encrypted vault may be created (Pro, or no encrypted vault yet).
    func canCreateVault() async -> Bool
    /// Creates an encrypted vault and opens it.
    func createVault(name: String, password: String) async throws
    /// Opens the vault the password belongs to.
    func open(password: String) async throws
    /// Opens the vault that uses Face ID.
    func openWithBiometrics() async throws
    /// Closes the open encrypted vault; `current` becomes the unencrypted vault.
    func close()
    /// Returns whether the privacy cover should show.
    func appWillResignActive() -> Bool
    /// Closes the open encrypted vault.
    func appDidEnterBackground()
    /// Changes the open vault's password after verifying the current one.
    func changePassword(current: String, new: String) async throws
    /// Turns Face ID on or off for the open vault.
    func setUsesBiometrics(_ enabled: Bool) async throws
    /// Erases the open vault after verifying its password.
    func deleteCurrentVault(password: String) async throws
    /// Opens another vault as a transfer target, separate from `current`.
    func openTransferTarget(password: String) async throws -> OpenVault
    /// Closes a transfer target: its key and temp files are wiped.
    func closeTransferTarget(_ vault: OpenVault)
}
