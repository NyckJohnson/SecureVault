//
//  CryptoService.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import os
import Foundation
import CryptoKit
import CommonCrypto

nonisolated final class CryptoService: @unchecked Sendable {
    static let shared = CryptoService()
    private init() {}

    // MARK: - In-memory key (wiped on lock)
    // Only mutable state in the class. The key lives inside the lock, so every access
    // is synchronized and background queues can't race wipeKey().
    private let keyState = OSAllocatedUnfairLock<SymmetricKey?>(initialState: nil)
    private var symmetricKey: SymmetricKey? {
        get { keyState.withLock { $0 } }
        set { keyState.withLock { $0 = newValue } }
    }

    var isKeyLoaded: Bool { symmetricKey != nil }

    func wipeKey() {
        symmetricKey = nil
    }

    /// Returns the raw bytes of the currently loaded master key. Caller must zero the returned Data when done.
    func exportMasterKeyData() throws -> Data {
        guard let key = symmetricKey else { throw CryptoError.noKeyLoaded }
        return key.withUnsafeBytes { Data($0) }
    }

    /// Loads a master key directly from raw bytes. Used for biometric unlock.
    func loadMasterKey(from data: Data) throws {
        guard data.count == 32 else { throw CryptoError.decryptionFailed }
        symmetricKey = SymmetricKey(data: data)
    }

    // MARK: - Master Key (random, wrapped at rest by a password-derived key)
    private let masterKeyBlobKeychainKey = "com.KoalaTVault.masterKeyBlob"
    private let keychainService = "com.KoalaTVault"
    // Not ThisDeviceOnly: the blob is password-wrapped, and must survive backup/restore
    // alongside the encrypted files or the vault becomes unrecoverable on a new device.
    private let keychainAccessibility = kSecAttrAccessibleWhenUnlocked

    private func blobQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: masterKeyBlobKeychainKey
        ]
    }

    /// Generates a new random master key, wraps it with a password-derived key, and stores the
    /// wrapped blob in Keychain. Call once, when a password is first set. Loads the key into memory.
    func createMasterKey(wrappedBy password: String) throws {
        guard !(try hasMasterKeyBlob()) else { throw CryptoError.masterKeyAlreadyExists }
        let masterKey = SymmetricKey(size: .bits256)
        try storeWrappedMasterKey(masterKey, wrappedBy: password)
        symmetricKey = masterKey
    }

    /// Derives a wrapping key from `password`, decrypts the stored master-key blob, and loads the
    /// result into memory. Throws if the password is wrong or no blob exists yet.
    func unwrapMasterKey(with password: String) throws {
        guard let blob = try readMasterKeyBlob() else { throw CryptoError.noMasterKeyBlob }
        guard blob.count > blobHeaderSize, blob[blob.startIndex] == blobVersion else {
            throw CryptoError.decryptionFailed
        }
        let header = blob.subdata(in: 0..<blobHeaderSize)
        let iterations = uint32Value(blob.subdata(in: 1..<5))
        guard (minPbkdfIterations...maxPbkdfIterations).contains(iterations) else {
            throw CryptoError.decryptionFailed
        }
        let salt = blob.subdata(in: 5..<blobHeaderSize)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: blob.subdata(in: blobHeaderSize..<blob.count)) else {
            throw CryptoError.decryptionFailed
        }

        let wrappingKey = try deriveKey(from: password, salt: salt, iterations: iterations)
        var masterKeyData: Data
        do {
            masterKeyData = try AES.GCM.open(sealedBox, using: wrappingKey, authenticating: header)
        } catch CryptoKitError.authenticationFailure {
            throw CryptoError.wrongPassword
        } catch is CryptoKitError {
            throw CryptoError.decryptionFailed
        }

        symmetricKey = SymmetricKey(data: masterKeyData)
        masterKeyData.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }

    /// Re-wraps the already-loaded master key under a new password. Call only after the old
    /// password has been verified (i.e. the master key is already in memory).
    func rewrapMasterKey(with newPassword: String) throws {
        guard let masterKey = symmetricKey else { throw CryptoError.noKeyLoaded }
        try storeWrappedMasterKey(masterKey, wrappedBy: newPassword)
    }

    func hasMasterKeyBlob() throws -> Bool {
        try readMasterKeyBlob() != nil
    }

    func wipeMasterKeyBlob() throws {
        let status = SecItemDelete(blobQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptoError.keychain(status)
        }
    }

    private func storeWrappedMasterKey(_ masterKey: SymmetricKey, wrappedBy password: String) throws {
        let salt = try randomBytes(count: saltSize)
        var header = Data([blobVersion])
        header.append(uint32Data(pbkdfIterations))
        header.append(salt)

        let wrappingKey = try deriveKey(from: password, salt: salt, iterations: pbkdfIterations)
        var masterKeyData = masterKey.withUnsafeBytes { Data($0) }
        defer { masterKeyData.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard let sealed = try AES.GCM.seal(masterKeyData, using: wrappingKey, authenticating: header).combined else {
            throw CryptoError.encryptionFailed
        }
        let blob = header + sealed

        let searchQuery = blobQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: blob,
            kSecAttrAccessible as String: keychainAccessibility
        ]

        // Update in place so the old blob survives if the write fails
        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = searchQuery
            addQuery[kSecValueData as String] = blob
            addQuery[kSecAttrAccessible as String] = keychainAccessibility
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CryptoError.keychain(addStatus) }
        default:
            throw CryptoError.keychain(updateStatus)
        }
    }

    /// Returns the stored blob, `nil` if none exists, or throws if the Keychain read fails.
    private func readMasterKeyBlob() throws -> Data? {
        var query = blobQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw CryptoError.keychain(errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CryptoError.keychain(status)
        }
    }

    // MARK: - Key Derivation
    private let pbkdfIterations: UInt32    = 600_000 // OWASP 2023 guidance for PBKDF2-HMAC-SHA256
    private let minPbkdfIterations: UInt32 = 100_000
    private let maxPbkdfIterations: UInt32 = 10_000_000 // sanity cap so a corrupt blob can't hang unlock

    // Master-key blob: version(1) | iterations(4, LE) | salt(32) | AES-GCM combined
    // The first `blobHeaderSize` bytes are authenticated as AAD.
    private let blobVersion: UInt8 = 1
    private let saltSize = 32
    private let blobHeaderSize = 37 // 1 + 4 + 32

    private func deriveKey(from password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        guard !password.isEmpty else { throw CryptoError.encryptionFailed }

        let passwordData = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var derivedKey = [UInt8](repeating: 0, count: 32) // 256-bit key
        let status = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress, passwordData.count,
                    saltBytes.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derivedKey, derivedKey.count
                )
            }
        }
        guard status == Int32(kCCSuccess) else { throw CryptoError.encryptionFailed }
        var keyData = Data(derivedKey)
        defer { keyData.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        let key = SymmetricKey(data: keyData)
        derivedKey.withUnsafeMutableBufferPointer { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        return key
    }

    private func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status: OSStatus = data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else { throw CryptoError.encryptionFailed }
        return data
    }

    // MARK: - Encryption
    func encrypt(data: Data, authenticating domain: String) throws -> Data {
        guard let key = symmetricKey else { throw CryptoError.noKeyLoaded }
        let sealedBox = try AES.GCM.seal(data, using: key, authenticating: Data(domain.utf8))
        guard let combined = sealedBox.combined else { throw CryptoError.encryptionFailed }
        return combined
    }

    func decrypt(data: Data, authenticating domain: String) throws -> Data {
        guard let key = symmetricKey else { throw CryptoError.noKeyLoaded }
        return try openSealed(data, using: key, authenticating: Data(domain.utf8))
    }

    /// Opens an AES-GCM combined blob, mapping any CryptoKit failure to `CryptoError.decryptionFailed`.
    private func openSealed(_ combined: Data, using key: SymmetricKey, authenticating aad: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch is CryptoKitError {
            throw CryptoError.decryptionFailed
        }
    }

    /// Derives a per-file encryption key from the master key and the file's unique random ID.
    private func fileKey(from masterKey: SymmetricKey, fileID: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: masterKey, salt: fileID,
                               info: Data("file-key".utf8), outputByteCount: 32)
    }

    /// Reads exactly `count` bytes, looping until full or EOF to handle short reads.
    private func readFully(from handle: FileHandle, count: Int) throws -> Data? {
        var accumulated = Data(capacity: count)
        while accumulated.count < count {
            guard let chunk = try handle.read(upToCount: count - accumulated.count), !chunk.isEmpty else { break }
            accumulated.append(chunk)
        }
        return accumulated.isEmpty ? nil : accumulated
    }

    // MARK: - File Operations
    private let streamChunkSize             = 1 * 1024 * 1024          // 1MB
    private let chunkedFormatMagic: [UInt8] = [0x53, 0x56, 0x43, 0x35] // "SVC5" — per-file HKDF keys
    private let headerSize                  = 32 // magic(4) + chunkSize(4) + totalPlaintextSize(8) + fileID(16)
    private let fileIDSize                  = 16
    private let gcmOverhead                 = 28                       // 12-byte nonce + 16-byte tag
    private let maxChunkSize                = 16 * 1024 * 1024         // sanity cap on header chunkSize
    private let maxTotalSize                = 1 << 41                  // 2 TiB; keeps all offset math far below Int.max

    /// Creates an empty file on the same volume as `destination` so the final move is an atomic rename.
    /// Caller must remove `directory` when done.
    private func makeStagingFile(for destination: URL) throws -> (directory: URL, file: URL) {
        let fileManager = FileManager.default
        let directory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                            appropriateFor: destination.deletingLastPathComponent(), create: true)
        let file = directory.appendingPathComponent(UUID().uuidString)
        guard fileManager.createFile(atPath: file.path, contents: nil,
                                     attributes: [.protectionKey: FileProtectionType.complete]) else {
            try? fileManager.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        return (directory, file)
    }

    /// Atomically moves `staged` into place, replacing `destination` if it exists.
    private func commitStagingFile(_ staged: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    func encryptFile(at url: URL, to destination: URL) throws {
        guard let masterKey = symmetricKey else { throw CryptoError.noKeyLoaded }
        guard let totalSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              totalSize <= maxTotalSize else {
            throw CryptoError.encryptionFailed
        }

        let fileID = try randomBytes(count: fileIDSize)
        var header = Data(chunkedFormatMagic)
        header.append(uint32Data(UInt32(streamChunkSize)))
        header.append(uint64Data(UInt64(totalSize)))
        header.append(fileID)

        let encKey = fileKey(from: masterKey, fileID: fileID)

        let staging = try makeStagingFile(for: destination)
        defer { try? FileManager.default.removeItem(at: staging.directory) }

        let outputHandle = try FileHandle(forWritingTo: staging.file)
        defer { try? outputHandle.close() }
        let inputHandle = try FileHandle(forReadingFrom: url)
        defer { try? inputHandle.close() }

        try outputHandle.write(contentsOf: header)

        var bytesRead = 0
        var chunkIndex = 0
        var sawPartialChunk = false
        while try autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try readFully(from: inputHandle, count: streamChunkSize), !chunk.isEmpty else { return false }
            // decryptChunk's offset math requires every chunk except the last to be full-size
            guard !sawPartialChunk else { throw CryptoError.encryptionFailed }
            sawPartialChunk = chunk.count < streamChunkSize

            let aad = chunkAAD(header: header, index: chunkIndex)
            guard let combined = try AES.GCM.seal(chunk, using: encKey, authenticating: aad).combined else {
                throw CryptoError.encryptionFailed
            }
            try outputHandle.write(contentsOf: uint32Data(UInt32(combined.count)) + combined)
            bytesRead += chunk.count
            chunkIndex += 1
            return true
        }) {}

        // totalSize is authenticated in every chunk, so it must match what was actually read
        guard bytesRead == totalSize else { throw CryptoError.encryptionFailed }
        try outputHandle.synchronize()
        try commitStagingFile(staging.file, to: destination)
    }

    func decryptFile(at url: URL, to destination: URL) throws {
        guard let masterKey = symmetricKey else { throw CryptoError.noKeyLoaded }
        let inputHandle = try FileHandle(forReadingFrom: url)
        defer { try? inputHandle.close() }
        let header = try readFully(from: inputHandle, count: headerSize) ?? Data()
        let info = try parseHeader(header)
        let encKey = fileKey(from: masterKey, fileID: info.fileID)

        let staging = try makeStagingFile(for: destination)
        defer { try? FileManager.default.removeItem(at: staging.directory) }

        let outputHandle = try FileHandle(forWritingTo: staging.file)
        defer { try? outputHandle.close() }

        var bytesWritten = 0
        var chunkIndex = 0
        while try autoreleasepool(invoking: { () -> Bool in
            let lengthData = try readFully(from: inputHandle, count: 4) ?? Data()
            if lengthData.isEmpty { return false } // clean end of file
            guard lengthData.count == 4 else { throw CryptoError.decryptionFailed }

            let length = Int(uint32Value(lengthData))
            guard (gcmOverhead + 1)...(info.chunkSize + gcmOverhead) ~= length else {
                throw CryptoError.decryptionFailed
            }

            let combined = try readFully(from: inputHandle, count: length) ?? Data()
            guard combined.count == length else { throw CryptoError.decryptionFailed }

            let plaintext = try openSealed(combined, using: encKey, authenticating: chunkAAD(header: header, index: chunkIndex))
            try outputHandle.write(contentsOf: plaintext)
            bytesWritten += plaintext.count
            chunkIndex += 1
            return true
        }) {}

        guard bytesWritten == info.totalSize else { throw CryptoError.decryptionFailed }
        try outputHandle.synchronize()
        try commitStagingFile(staging.file, to: destination)
    }

    /// Reads only the header — no decryption — to learn plaintext size and chunk size.
    func streamInfo(for url: URL) throws -> (totalSize: Int, chunkSize: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try readFully(from: handle, count: headerSize) ?? Data()
        let info = try parseHeader(header)
        return (info.totalSize, info.chunkSize)
    }

    /// Decrypts a single chunk by index without touching any other chunk.
    /// Relies on every chunk but the last being exactly `chunkSize` plaintext bytes,
    /// so its on-disk offset can be computed directly.
    func decryptChunk(at index: Int, from url: URL, chunkSize: Int, totalSize: Int) throws -> Data {
        guard let masterKey = symmetricKey else { throw CryptoError.noKeyLoaded }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // The header is part of every chunk's AAD; a caller passing stale sizes fails authentication
        let header = try readFully(from: handle, count: headerSize) ?? Data()
        guard header.count == headerSize else { throw CryptoError.decryptionFailed }

        let info = try parseHeader(header)
        guard info.chunkSize == chunkSize, info.totalSize == totalSize else {
            throw CryptoError.decryptionFailed
        }
        guard chunkSize > 0, index >= 0, index < (totalSize + chunkSize - 1) / chunkSize else {
            throw CryptoError.decryptionFailed
        }
        let fullCombinedSize = chunkSize + gcmOverhead
        let offset = headerSize + index * (4 + fullCombinedSize)
        let encKey = fileKey(from: masterKey, fileID: info.fileID)

        try handle.seek(toOffset: UInt64(offset))

        let lengthData = try readFully(from: handle, count: 4) ?? Data()
        guard lengthData.count == 4 else { throw CryptoError.decryptionFailed }
        let length = Int(uint32Value(lengthData))
        guard (gcmOverhead + 1)...fullCombinedSize ~= length else { throw CryptoError.decryptionFailed }
        let combined = try readFully(from: handle, count: length) ?? Data()
        guard combined.count == length else { throw CryptoError.decryptionFailed }

        return try openSealed(combined, using: encKey, authenticating: chunkAAD(header: header, index: index))
    }

    // Validates a stream header and returns its fields (chunkSize, totalSize, fileID).
    // Three fields are inherent to the format; introducing a named struct here would add indirection
    // for a private method used in a single place.
    // swiftlint:disable:next large_tuple
    private func parseHeader(_ header: Data) throws -> (chunkSize: Int, totalSize: Int, fileID: Data) {
        guard header.count == headerSize, Array(header.prefix(4)) == chunkedFormatMagic else {
            throw CryptoError.decryptionFailed
        }
        let chunkSize = Int(uint32Value(header.subdata(in: 4..<8)))
        let totalSize = uint64Value(header.subdata(in: 8..<16))
        guard (1...maxChunkSize).contains(chunkSize), totalSize <= UInt64(maxTotalSize) else {
            throw CryptoError.decryptionFailed
        }
        return (chunkSize, Int(totalSize), header.subdata(in: 16..<32))
    }

    /// AAD for a chunk: the full header (binds chunkSize, totalSize, fileID) plus the chunk index.
    private func chunkAAD(header: Data, index: Int) -> Data {
        header + uint64Data(UInt64(index))
    }

    private func uint32Data(_ value: UInt32) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
    private func uint32Value(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }
    private func uint64Data(_ value: UInt64) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
    private func uint64Value(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }
}

// MARK: - Supporting Types
nonisolated enum CryptoError: Error, Equatable {
    case noKeyLoaded
    case noMasterKeyBlob
    case masterKeyAlreadyExists
    case wrongPassword
    case encryptionFailed
    case decryptionFailed
    case keychain(OSStatus)
}

nonisolated extension CryptoError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noKeyLoaded:            return "No encryption key is loaded."
        case .noMasterKeyBlob:        return "No password has been set up."
        case .masterKeyAlreadyExists: return "A master key already exists."
        case .wrongPassword:          return "Incorrect password."
        case .encryptionFailed:       return "Encryption failed."
        case .decryptionFailed:       return "Decryption failed. The data may be damaged."
        case .keychain(let status):   return "Couldn't access secure storage (error \(status))."
        }
    }
}
