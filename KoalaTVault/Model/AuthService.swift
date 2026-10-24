//
//  AuthService.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import Foundation
@preconcurrency import LocalAuthentication
import os
import Security
import UIKit

enum AuthError: Error {
    case wrongPassword
    case keychainError
}

@MainActor
final class AuthService {
    static let shared = AuthService()
    private init() {}

    // MARK: - Keys
    // Legacy account key — kept only to clean up any plaintext password stored by older builds.
    nonisolated private let legacyPasswordKeychainKey = "com.KoalaTVault.password"
    nonisolated private let biometricMasterKeyAccount = "com.KoalaTVault.biometricMasterKey"
    nonisolated private let biometricKeychainService  = "com.KoalaTVault"
    private let privacyScreenTag = 999
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "AuthService")

    // MARK: - Lock Mode
    var lockMode: LockMode {
        get { PreferencesService.shared.lockMode }
        set { PreferencesService.shared.lockMode = newValue }
    }

    // MARK: - Password
    nonisolated func createPassword(_ password: String) throws {
        try CryptoService.shared.createMasterKey(wrappedBy: password)
        // Caller is responsible for calling enableBiometrics() afterwards if lockMode is .passwordAndBiometrics.
    }

    nonisolated func changePassword(to newPassword: String) throws {
        // rewrapMasterKey keeps the same key in memory; the biometric item (raw key bytes) stays valid.
        try CryptoService.shared.rewrapMasterKey(with: newPassword)
    }

    nonisolated func verifyPassword(_ password: String) throws {
        do {
            try CryptoService.shared.unwrapMasterKey(with: password)
        } catch CryptoError.wrongPassword {
            throw AuthError.wrongPassword
        }
        deleteLegacyPasswordItem()
    }

    func hasPassword() -> Bool {
        (try? CryptoService.shared.hasMasterKeyBlob()) ?? true
    }

    func removePassword() throws {
        try CryptoService.shared.wipeMasterKeyBlob()
        removeBiometricSecret()
        deleteLegacyPasswordItem()
    }

    // MARK: - Biometric Secret Storage

    /// Stores the currently loaded master key in the Keychain protected by biometrics.
    /// Only call when lockMode is .passwordAndBiometrics and the master key is loaded.
    nonisolated func enableBiometrics() throws {
        var keyData = try CryptoService.shared.exportMasterKeyData()
        defer { keyData.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        try storeBiometricMasterKey(keyData)
    }

    /// Removes the biometrically-protected master key from the Keychain.
    nonisolated func removeBiometricSecret() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricKeychainService,
            kSecAttrAccount as String: biometricMasterKeyAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Stores raw master key bytes in the Keychain, accessible only after biometric auth on this device.
    /// Access control prevents migration via backup and invalidates the item if biometrics change.
    nonisolated private func storeBiometricMasterKey(_ keyData: Data) throws {
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            throw AuthError.keychainError
        }
        // Access control attributes cannot be updated via SecItemUpdate, so delete-then-add.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricKeychainService,
            kSecAttrAccount as String: biometricMasterKeyAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometricKeychainService,
            kSecAttrAccount as String: biometricMasterKeyAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessControl as String: access
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuthError.keychainError }
    }

    /// Removes any plaintext password stored by older app versions.
    nonisolated private func deleteLegacyPasswordItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: legacyPasswordKeychainKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Migration Completion
    func finalizeMigration(
        type: MigrationViewController.MigrationType,
        targetLockMode: LockMode?,
        completedFully: Bool
    ) {
        guard completedFully else { return }
        switch type {
        case .encrypt:
            if let targetLockMode { lockMode = targetLockMode }
        case .decrypt:
            lockMode = .none
            do {
                try removePassword()
            } catch {
                // Removal failed: the keychain blob persists while lockMode is .none.
                // The key is wiped below so the vault is still inaccessible, but the
                // inconsistency should be investigated.
                logger.error("removePassword failed during decrypt migration: \(error.localizedDescription, privacy: .public)")
            }
            CryptoService.shared.wipeKey()
        }
    }

    // MARK: - Biometrics
    var biometricsAvailable: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: nil
        )
    }

    var biometricType: String {
        let context = LAContext()
        context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: nil
        )
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometrics"
        }
    }

    func authenticateWithBiometrics(
        completion: @escaping @MainActor @Sendable (Bool, Error?) -> Void
    ) {
        // Use a fresh, non-pre-evaluated context. This makes SecItemCopyMatching the
        // sole authentication gate — the Secure Enclave enforces it at hardware level,
        // unlike evaluatePolicy whose result can be faked on a jailbroken device.
        let context = LAContext()

        DispatchQueue.global(qos: .userInitiated).async { [biometricKeychainService, biometricMasterKeyAccount] in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: biometricKeychainService,
                kSecAttrAccount as String: biometricMasterKeyAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            guard status == errSecSuccess, let keyData = result as? Data else {
                DispatchQueue.main.async {
                    // nil signals user-initiated dismissal so the lock screen shows no error.
                    completion(false, status == errSecUserCanceled ? nil : AuthError.keychainError)
                }
                return
            }

            do {
                try CryptoService.shared.loadMasterKey(from: keyData)
                DispatchQueue.main.async { completion(true, nil) }
            } catch {
                DispatchQueue.main.async { completion(false, AuthError.keychainError) }
            }
        }
    }

    // MARK: - Lock State
    var isLocked = false
    var hasAuthenticated = false

    static let vaultUnlockedNotification = Notification.Name(
        "KoalaTVault.vaultUnlocked"
    )

    // MARK: - Scene Lifecycle
    /// Call from `sceneWillResignActive`. Any interruption — Control Center, an
    /// alert, the StoreKit purchase sheet — triggers this, so it only covers the
    /// screen; it must NOT wipe the key or present the lock screen, since most of
    /// these interruptions aren't a real backgrounding.
    func handleWillResignActive(in window: UIWindow?) {
        guard hasAuthenticated, lockMode != .none else { return }
        showPrivacyScreen(in: window)
    }

    /// Call from `sceneDidEnterBackground`. This only fires on a genuine
    /// backgrounding (home button, app switch, screen lock), so this is where
    /// the actual lock — wiping the key and requiring re-auth — belongs.
    func handleDidEnterBackground(in window: UIWindow?) {
        guard hasAuthenticated, lockMode != .none else { return }
        isLocked = true
        CryptoService.shared.wipeKey()
        FileSystem.shared.cleanupTempFiles()
        ThumbnailService.shared.clearCache()
    }

    func handleForeground(in window: UIWindow?) {
        if lockMode == .none {
            hasAuthenticated = true
            hidePrivacyScreen(in: window)
            return
        }
        if isLocked {
            showLockScreen(in: window)
        } else {
            hidePrivacyScreen(in: window)
        }
    }

    func handleInitialLaunch(in window: UIWindow?) {
        guard lockMode != .none else {
            NotificationCenter.default.post(
                name: AuthService.vaultUnlockedNotification,
                object: nil
            )
            return
        }
        isLocked = true
        showLockScreen(in: window)
    }

    // MARK: - Auth Success
    func didAuthenticate(in window: UIWindow?) {
        isLocked = false
        hasAuthenticated = true
        guard let root = window?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        // topVC is the lock screen itself — dismiss it specifically, not its presenter's
        // whole chain, so an in-progress MigrationViewController underneath survives.
        let dismisser = topVC.presentingViewController ?? root
        dismisser.dismiss(animated: true) {
            self.hidePrivacyScreen(in: window)
            self.reloadFileBrowser(in: window)
            NotificationCenter.default.post(
                name: AuthService.vaultUnlockedNotification,
                object: nil
            )
        }
    }

    // MARK: - Privacy Screen
    private func showPrivacyScreen(in window: UIWindow?) {
        guard window?.viewWithTag(privacyScreenTag) == nil else { return }
        let privacy = UIView()
        privacy.backgroundColor = .systemBackground
        privacy.tag = privacyScreenTag
        let logo = UIImageView(image: UIImage(systemName: "lock.fill"))
        logo.tintColor = .systemBlue
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        privacy.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: privacy.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: privacy.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 60),
            logo.heightAnchor.constraint(equalToConstant: 60)
        ])
        privacy.frame = window?.bounds ?? .zero
        window?.addSubview(privacy)
    }

    private func hidePrivacyScreen(in window: UIWindow?) {
        window?.viewWithTag(privacyScreenTag)?.removeFromSuperview()
    }

    // MARK: - Lock Screen
    private func showLockScreen(in window: UIWindow?) {
        guard let root = window?.rootViewController else { return }
        // find topmost presented view controller
        var topVC = root
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        guard !(topVC is LockScreenViewController) else {
            hidePrivacyScreen(in: window)
            return
        }
        let lock = LockScreenViewController()
        lock.modalPresentationStyle = .fullScreen
        topVC.present(lock, animated: false) { [weak self] in
            self?.hidePrivacyScreen(in: window)
        }
    }

    // MARK: - File Browser Reload
    private func reloadFileBrowser(in window: UIWindow?) {
        // Assumes root is always UINavigationController with FileBrowserViewController as the first VC.
        // Update this if the root view controller hierarchy ever changes (e.g. tab bar added).
        if let nav = window?.rootViewController as? UINavigationController,
            let browser = nav.viewControllers.first
                as? FileBrowserViewController
        {
            browser.reloadAfterAuth()
        }
    }
}
