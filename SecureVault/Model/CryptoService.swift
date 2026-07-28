//
//  CryptoService.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import Foundation
import CryptoKit
import CommonCrypto

final class CryptoService {
    static let shared = CryptoService()
    private init() {}

    // MARK: - In-memory key (wiped on lock)
    private var symmetricKey: SymmetricKey?

    var isKeyLoaded: Bool { symmetricKey != nil }

    func loadKey(from password: String) throws {
        let salt = getOrCreateSalt()
        let key = deriveKey(from: password, salt: salt)
        symmetricKey = key
    }

    func wipeKey() {
        print("wipeKey called")
        symmetricKey = nil
    }

    // MARK: - Key Derivation
    private func deriveKey(from password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedKey = [UInt8](repeating: 0, count: 32) // 256-bit key
        _ = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress, passwordData.count,
                    saltBytes.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    100_000, // iterations — slow by design
                    &derivedKey, derivedKey.count
                )
            }
        }
        return SymmetricKey(data: Data(derivedKey))
    }

    // MARK: - Salt
    private let saltKeychainKey = "com.securevault.salt"

    private func getOrCreateSalt() -> Data {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: saltKeychainKey,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }
        // create new salt
        var salt = Data(count: 32)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let addQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: saltKeychainKey,
            kSecValueData as String:   salt
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        return salt
    }

    // MARK: - Encryption
    func encrypt(data: Data) throws -> Data {
        guard let key = symmetricKey else { throw CryptoError.noKeyLoaded }
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else { throw CryptoError.encryptionFailed }
        return combined
    }

    func decrypt(data: Data) throws -> Data {
        guard let key = symmetricKey else { throw CryptoError.noKeyLoaded }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - File Operations
    func encryptFile(at url: URL, to destination: URL) throws {
        try autoreleasepool {
            let data = try Data(contentsOf: url)
            let encrypted = try encrypt(data: data)
            try encrypted.write(to: destination)
        }
    }

    func decryptFile(at url: URL, to destination: URL) throws {
        let data = try Data(contentsOf: url)
        let decrypted = try decrypt(data: data)
        try decrypted.write(to: destination)
    }

    // MARK: - File Name Mapping
    private let mappingFileName = ".securevault_map"

    func loadMapping(from directory: URL) throws -> [String: FileMapping] {
        let mapURL = directory.appendingPathComponent(mappingFileName)
        guard FileManager.default.fileExists(atPath: mapURL.path) else { return [:] }
        let data = try Data(contentsOf: mapURL)
        let decrypted = try decrypt(data: data)
        return try JSONDecoder().decode([String: FileMapping].self, from: decrypted)
    }

    func saveMapping(_ mapping: [String: FileMapping], to directory: URL) throws {
        let mapURL = directory.appendingPathComponent(mappingFileName)
        let data = try JSONEncoder().encode(mapping)
        let encrypted = try encrypt(data: data)
        try encrypted.write(to: mapURL)
    }
}

// MARK: - Supporting Types
struct FileMapping: Codable {
    let originalName: String
    let directory: String
}

enum CryptoError: Error {
    case noKeyLoaded
    case encryptionFailed
    case decryptionFailed
}
