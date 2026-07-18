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

enum LockMode: String {
    case none
    case password
    case passwordAndBiometrics
}

enum AuthError: Error {
    case noPasswordSet
    case wrongPassword
    case biometricsFailed
    case keychainError
}

final class AuthService {
    static let shared = AuthService()
    private init() {}

    // MARK: - Keys
    private let lockModeKey         = "lockMode"
    private let passwordKeychainKey = "com.securevault.password"

    // MARK: - Lock Mode
    var lockMode: LockMode {
        get { LockMode(rawValue: UserDefaults.standard.string(forKey: lockModeKey) ?? "none") ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lockModeKey) }
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
            if success {
                let query: [String: Any] = [
                    kSecClass as String:       kSecClassGenericPassword,
                    kSecAttrAccount as String: self.passwordKeychainKey,
                    kSecReturnData as String:  true,
                    kSecMatchLimit as String:  kSecMatchLimitOne
                ]
                var result: AnyObject?
                if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                   let data = result as? Data,
                   let password = String(data: data, encoding: .utf8) {
                    try? CryptoService.shared.loadKey(from: password)
                }
            }
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    // MARK: - Lock State
    var isLocked         = false
    var hasAuthenticated = false

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
        guard lockMode != .none else { return }
        isLocked = true
        showLockScreen(in: window)
    }

    // MARK: - Auth Success
    func didAuthenticate(in window: UIWindow?) {
        isLocked = false
        hasAuthenticated = true
        window?.rootViewController?.dismiss(animated: true) {
            self.hidePrivacyScreen(in: window)
            self.reloadFileBrowser(in: window)
        }
    }

    // MARK: - Privacy Screen
    private func showPrivacyScreen(in window: UIWindow?) {
        guard window?.viewWithTag(999) == nil else { return }
        let privacy = UIView()
        privacy.backgroundColor = .systemBackground
        privacy.tag = 999
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
        window?.viewWithTag(999)?.removeFromSuperview()
    }

    // MARK: - Lock Screen
    private func showLockScreen(in window: UIWindow?) {
        guard let root = window?.rootViewController else { return }
        guard !(root.presentedViewController is LockScreenViewController) else { return }
        let lock = LockScreenViewController()
        lock.modalPresentationStyle = .fullScreen
        root.present(lock, animated: false)
    }

    // MARK: - File Browser Reload
    private func reloadFileBrowser(in window: UIWindow?) {
        if let nav = window?.rootViewController as? UINavigationController,
           let browser = nav.viewControllers.first as? FileBrowserViewController {
            browser.reloadAfterAuth()
        }
    }
}
