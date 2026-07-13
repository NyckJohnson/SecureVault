//
//  AuthService.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import Foundation
import LocalAuthentication
import Security

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
    private let lockModeKey        = "lockMode"
    private let lockTimeoutKey     = "lockTimeout"
    private let passwordKeychainKey = "com.securevault.password"

    // MARK: - Lock Mode
    var lockMode: LockMode {
        get { LockMode(rawValue: UserDefaults.standard.string(forKey: lockModeKey) ?? "none") ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lockModeKey) }
    }

    // MARK: - Lock Timeout (in seconds, -1 = immediately)
    var lockTimeout: TimeInterval {
        get { UserDefaults.standard.double(forKey: lockTimeoutKey) == 0 ? -1 : UserDefaults.standard.double(forKey: lockTimeoutKey) }
        set { UserDefaults.standard.set(newValue, forKey: lockTimeoutKey) }
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
        ) { success, error in
            DispatchQueue.main.async {
                completion(success, error)
            }
        }
    }

    // MARK: - Lock State
    private var backgroundedAt: Date?
    var isLocked = false

    func appDidBackground() {
        backgroundedAt = Date()
    }

    func appDidForeground() -> Bool {
        guard lockMode != .none else { return false }
        guard let backgroundedAt else {
            isLocked = true
            return true
        }
        let elapsed = Date().timeIntervalSince(backgroundedAt)
        if lockTimeout == -1 || elapsed >= lockTimeout {
            isLocked = true
            return true
        }
        return false
    }
}
