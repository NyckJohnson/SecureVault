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

    @Test("existingPasswordRequired asks for the password already on the device")
    func existingPasswordRequiredText() {
        expectText(.existingPasswordRequired, "A vault password already exists on this device. Enter that password.")
    }

    @Test("emptyPassword says the password cannot be empty")
    func emptyPasswordText() {
        expectText(.emptyPassword, "Password cannot be empty")
    }

    @Test("passwordMissing says the password is missing from the device")
    func passwordMissingText() {
        expectText(.passwordMissing, "Your vault password is missing from this device.")
    }

    @Test("notUnlocked asks to unlock the vault first")
    func notUnlockedText() {
        expectText(.notUnlocked, "Unlock the vault first.")
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
