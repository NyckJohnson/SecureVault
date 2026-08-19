//
//  AuthService.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import Foundation
import LocalAuthentication
import Security
import UIKit

enum AuthError: Error {
    case wrongPassword
    case keychainError
}

final class AuthService {
    static let shared = AuthService()
    private init() {}

    // MARK: - Keys
    private let passwordKeychainKey = "com.securevault.password"
    private let privacyScreenTag    = 999

    // MARK: - Lock Mode
    var lockMode: LockMode {
        get { PreferencesService.shared.lockMode }
        set { PreferencesService.shared.lockMode = newValue }
    }

    // MARK: - Password
    func setPassword(_ password: String) throws {
        let data = password.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: passwordKeychainKey,
            kSecValueData as String:   data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuthError.keychainError }
    }

    func verifyPassword(_ password: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: passwordKeychainKey,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let stored = String(data: data, encoding: .utf8) else {
            throw AuthError.keychainError
        }
        guard stored == password else { throw AuthError.wrongPassword }
        try CryptoService.shared.loadKey(from: password)
    }

    func hasPassword() -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: passwordKeychainKey
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func removePassword() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: passwordKeychainKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Migration Completion
    func finalizeMigration(type: MigrationViewController.MigrationType, targetLockMode: LockMode?, completedFully: Bool) {
        guard completedFully else { return }
        switch type {
        case .encrypt:
            if let targetLockMode { lockMode = targetLockMode }
        case .decrypt:
            lockMode = .none
            removePassword()
            CryptoService.shared.wipeKey()
        }
    }

    // MARK: - Biometrics
    var biometricsAvailable: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var biometricType: String {
        let context = LAContext()
        context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        default:       return "Biometrics"
        }
    }

    func authenticateWithBiometrics(completion: @escaping (Bool, Error?) -> Void) {
        let context = LAContext()
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock SecureVault"
        ) { [weak self] success, error in
            guard let self else { return }
            guard success else {
                DispatchQueue.main.async { completion(false, error) }
                return
            }

            let query: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrAccount as String: self.passwordKeychainKey,
                kSecReturnData as String:  true,
                kSecMatchLimit as String:  kSecMatchLimitOne
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion(false, AuthError.keychainError) }
                return
            }

            do {
                try CryptoService.shared.loadKey(from: password)
                DispatchQueue.main.async { completion(true, nil) }
            } catch {
                DispatchQueue.main.async { completion(false, AuthError.keychainError) }
            }
        }
    }

    // MARK: - Lock State
    var isLocked         = false
    var hasAuthenticated = false
    
    static let vaultUnlockedNotification = Notification.Name("SecureVault.vaultUnlocked")

    // MARK: - Scene Lifecycle
    func handleBackground(in window: UIWindow?) {
        guard hasAuthenticated, lockMode != .none else { return }
        isLocked = true
        CryptoService.shared.wipeKey()
        FileSystem.shared.cleanupTempFiles()
        ThumbnailService.shared.clearCache()
        showPrivacyScreen(in: window)
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
            NotificationCenter.default.post(name: AuthService.vaultUnlockedNotification, object: nil)
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
            NotificationCenter.default.post(name: AuthService.vaultUnlockedNotification, object: nil)
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
            logo.heightAnchor.constraint(equalToConstant: 60),
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
        guard !(topVC is LockScreenViewController) else { return }
        let lock = LockScreenViewController()
        lock.modalPresentationStyle = .fullScreen
        topVC.present(lock, animated: false)
    }

    // MARK: - File Browser Reload
    private func reloadFileBrowser(in window: UIWindow?) {
        // Assumes root is always UINavigationController with FileBrowserViewController as the first VC.
        // Update this if the root view controller hierarchy ever changes (e.g. tab bar added).
        if let nav = window?.rootViewController as? UINavigationController,
           let browser = nav.viewControllers.first as? FileBrowserViewController {
            browser.reloadAfterAuth()
        }
    }
}
