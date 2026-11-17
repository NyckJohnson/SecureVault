import Foundation
import Testing

@testable import KoalaTVault

/// The user-facing text of `VaultLockError` (`LocalizedError`); screens show `localizedDescription`.
@Suite struct VaultLockErrorTextTests {
    private func expectText(_ error: VaultLockError, _ expected: String) {
        #expect(error.errorDescription == expected)
        #expect(error.localizedDescription == expected)
    }

    @Test("wrongPassword says the password is incorrect")
    func wrongPasswordText() {
        expectText(.wrongPassword, "Incorrect password")
    }

    @Test("emptyPassword says the password cannot be empty")
    func emptyPasswordText() {
        expectText(.emptyPassword, "Password cannot be empty")
    }

    @Test("emptyName asks for a vault name")
    func emptyNameText() {
        expectText(.emptyName, "Enter a name for the vault")
    }

    @Test("passwordInUse asks for a different password")
    func passwordInUseText() {
        expectText(.passwordInUse, "Choose a different password.")
    }

    @Test("vaultLimitReached points to Pro")
    func vaultLimitReachedText() {
        expectText(.vaultLimitReached, "More vaults with Pro.")
    }

    @Test("sameVault says the items are already in this vault")
    func sameVaultText() {
        expectText(.sameVault, "These items are already in this vault.")
    }

    @Test("notOpen asks to open a vault first")
    func notOpenText() {
        expectText(.notOpen, "Open a vault first.")
    }

    @Test("noBiometricVault says no vault uses Face ID")
    func noBiometricVaultText() {
        expectText(.noBiometricVault, "No vault uses Face ID.")
    }

    @Test("io text is the message itself")
    func ioText() {
        expectText(.io("Disk full"), "Disk full")
    }

    @Test("biometricsUnavailable says biometrics aren't available on this device")
    func biometricsUnavailableText() {
        expectText(.biometricsUnavailable, "Biometric authentication isn't available on this device.")
    }

    @Test("biometricCancelled says biometric authentication failed")
    func biometricCancelledText() {
        expectText(.biometricCancelled, "Biometric authentication failed")
    }

    @Test("biometryLockedOut says biometric authentication failed")
    func biometryLockedOutText() {
        expectText(.biometryLockedOut, "Biometric authentication failed")
    }

    @Test("biometryNotEnrolled says biometric authentication failed")
    func biometryNotEnrolledText() {
        expectText(.biometryNotEnrolled, "Biometric authentication failed")
    }

    @Test("passcodeNotSet says biometric authentication failed")
    func passcodeNotSetText() {
        expectText(.passcodeNotSet, "Biometric authentication failed")
    }

    @Test("biometricChanged says biometric authentication failed")
    func biometricChangedText() {
        expectText(.biometricChanged, "Biometric authentication failed")
    }

    @Test("keychain text includes a negative status number")
    func keychainNegativeStatusText() {
        expectText(.keychain(-25300), "A Keychain error occurred (-25300).")
    }

    @Test("keychain text includes a different, positive status number")
    func keychainPositiveStatusText() {
        expectText(.keychain(42), "A Keychain error occurred (42).")
    }

    @Test("keychain text differs between statuses")
    func keychainTextDependsOnStatus() {
        #expect(VaultLockError.keychain(1).errorDescription != VaultLockError.keychain(2).errorDescription)
    }
}
