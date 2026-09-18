//
//  CryptoService.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import Foundation
import CryptoKit
import CommonCrypto

nonisolated final class CryptoService: @unchecked Sendable {
    static let shared = CryptoService()
    private init() {}

    // MARK: - In-memory key (wiped on lock)
    private var symmetricKey: SymmetricKey?

    var isKeyLoaded: Bool { symmetricKey != nil }

    func wipeKey() {
        print("wipeKey called")
        symmetricKey = nil
    }

    // MARK: - Master Key (random, wrapped at rest by a password-derived key)
    private let masterKeyBlobKeychainKey = "com.securevault.masterKeyBlob"

    /// Generates a new random master key, wraps it with a password-derived key, and stores the
    /// wrapped blob in Keychain. Call once, when a password is first set. Loads the key into memory.
    func createMasterKey(wrappedBy password: String) throws {
        let masterKey = SymmetricKey(size: .bits256)
        try storeWrappedMasterKey(masterKey, wrappedBy: password)
        symmetricKey = masterKey
    }

    /// Derives a wrapping key from `password`, decrypts the stored master-key blob, and loads the
    /// result into memory. Throws if the password is wrong or no blob exists yet.
    func unwrapMasterKey(with password: String) throws {
        guard let blob = readMasterKeyBlob() else { throw CryptoError.noKeyLoaded }
        let wrappingKey = deriveKey(from: password, salt: getOrCreateSalt())
        let sealedBox = try AES.GCM.SealedBox(combined: blob)
        let masterKeyData = try AES.GCM.open(sealedBox, using: wrappingKey)
        symmetricKey = SymmetricKey(data: masterKeyData)
    }

    /// Re-wraps the already-loaded master key under a new password. Call only after the old
    /// password has been verified (i.e. the master key is already in memory).
    func rewrapMasterKey(with newPassword: String) throws {
        guard let masterKey = symmetricKey else { throw CryptoError.noKeyLoaded }
        try storeWrappedMasterKey(masterKey, wrappedBy: newPassword)
    }

    func hasMasterKeyBlob() -> Bool {
        readMasterKeyBlob() != nil
    }

    func wipeMasterKeyBlob() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: masterKeyBlobKeychainKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func storeWrappedMasterKey(_ masterKey: SymmetricKey, wrappedBy password: String) throws {
        let wrappingKey = deriveKey(from: password, salt: getOrCreateSalt())
        let masterKeyData = masterKey.withUnsafeBytes { Data($0) }
        guard let combined = try AES.GCM.seal(masterKeyData, using: wrappingKey).combined else {
            throw CryptoError.encryptionFailed
        }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: masterKeyBlobKeychainKey,
            kSecValueData as String:   combined
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CryptoError.encryptionFailed }
    }

    private func readMasterKeyBlob() -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: masterKeyBlobKeychainKey,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
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
    private let streamChunkSize = 1 * 1024 * 1024 // 1MB
    private let chunkedFormatMagic: [UInt8] = [0x53, 0x56, 0x43, 0x33] // "SVC3"
    private let headerSize = 16 // magic(4) + chunkSize(4) + totalPlaintextSize(8)
    private let gcmOverhead = 28 // 12-byte nonce + 16-byte tag

    func encryptFile(at url: URL, to destination: URL) throws {
        guard let key = symmetricKey else { throw CryptoError.noKeyLoaded }
        let totalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: destination),
              let inputHandle = try? FileHandle(forReadingFrom: url) else {
            throw CryptoError.encryptionFailed
        }
        defer { try? outputHandle.close(); try? inputHandle.close() }

        outputHandle.write(Data(chunkedFormatMagic))
        outputHandle.write(uint32Data(UInt32(streamChunkSize)))
        outputHandle.write(uint64Data(UInt64(totalSize)))

        while try autoreleasepool(invoking: { () -> Bool in
            let chunk = inputHandle.readData(ofLength: streamChunkSize)
            guard !chunk.isEmpty else { return false }
            guard let combined = try AES.GCM.seal(chunk, using: key).combined else {
                throw CryptoError.encryptionFailed
            }
            outputHandle.write(uint32Data(UInt32(combined.count)))
            outputHandle.write(combined)
            return true
        }) {}
    }

    func decryptFile(at url: URL, to destination: URL) throws {
        guard let inputHandle = try? FileHandle(forReadingFrom: url) else {
            throw CryptoError.decryptionFailed
        }
        defer { try? inputHandle.close() }
        let header = inputHandle.readData(ofLength: headerSize)
        guard header.count == headerSize, Array(header.prefix(4)) == chunkedFormatMagic else {
            throw CryptoError.decryptionFailed
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: destination) else {
            throw CryptoError.decryptionFailed
        }
        defer { try? outputHandle.close() }

        while try autoreleasepool(invoking: { () -> Bool in
            let lengthData = inputHandle.readData(ofLength: 4)
            guard lengthData.count == 4 else { return false }
            let length = Int(uint32Value(lengthData))
            let combined = inputHandle.readData(ofLength: length)
            guard combined.count == length else { return false }
            outputHandle.write(try decrypt(data: combined))
            return true
        }) {}
    }

    /// Reads only the header — no decryption — to learn plaintext size and chunk size.
    func streamInfo(for url: URL) throws -> (totalSize: Int, chunkSize: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw CryptoError.decryptionFailed }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: headerSize)
        guard header.count == headerSize, Array(header.prefix(4)) == chunkedFormatMagic else {
            throw CryptoError.decryptionFailed
        }
        let chunkSize = Int(uint32Value(header.subdata(in: 4..<8)))
        let totalSize = Int(uint64Value(header.subdata(in: 8..<16)))
        return (totalSize, chunkSize)
    }

    /// Decrypts a single chunk by index without touching any other chunk.
    /// Relies on every chunk but the last being exactly `chunkSize` plaintext bytes,
    /// so its on-disk offset can be computed directly.
    func decryptChunk(at index: Int, from url: URL, chunkSize: Int, totalSize: Int) throws -> Data {
        let fullCombinedSize = chunkSize + gcmOverhead
        let offset = headerSize + index * (4 + fullCombinedSize)

        guard let handle = try? FileHandle(forReadingFrom: url) else { throw CryptoError.decryptionFailed }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        let lengthData = handle.readData(ofLength: 4)
        guard lengthData.count == 4 else { throw CryptoError.decryptionFailed }
        let combined = handle.readData(ofLength: Int(uint32Value(lengthData)))
        return try decrypt(data: combined)
    }

    private func uint32Data(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
    private func uint32Value(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }
    private func uint64Data(_ value: UInt64) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
    private func uint64Value(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
    }
}

// MARK: - Supporting Types
enum CryptoError: Error {
    case noKeyLoaded
    case encryptionFailed
    case decryptionFailed
}

extension CryptoError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noKeyLoaded:       return "No encryption key is loaded."
        case .encryptionFailed:  return "Failed to encrypt the file."
        case .decryptionFailed:  return "Failed to decrypt the file."
        }
    }
}
