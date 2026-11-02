//
//  AuthService.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//
//  What is left of the legacy auth service once VaultLock and LockScreens replaced it: the wording
//  SecuritySettings still shows (until Settings replaces it).
//

import Foundation

// MARK: - Legacy wording

extension BiometricKind {
    /// The name the legacy screens show: "Face ID", "Touch ID", or "Biometrics" without biometric hardware.
    var legacyDisplayName: String {
        switch self {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .none: return "Biometrics"
        }
    }
}

extension VaultLockError {
    /// The message the legacy screens show for this error.
    var legacyMessage: String {
        switch self {
        case .wrongPassword: return "Incorrect password"
        case .existingPasswordRequired: return "A vault password already exists on this device. Enter that password."
        case .emptyPassword: return "Password cannot be empty"
        case .passwordMissing: return "Your vault password is missing from this device."
        case .notUnlocked: return "Unlock the vault first."
        case .biometricsUnavailable: return "Biometric authentication isn't available on this device."
        case .biometricCancelled, .biometryLockedOut, .biometryNotEnrolled, .passcodeNotSet, .biometricChanged:
            return "Biometric authentication failed"
        case .keychain(let status): return "A Keychain error occurred (\(status))."
        }
    }
}
