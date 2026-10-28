import CryptoKit
import Foundation
import os

/// The live master-key store: the key in memory, the password-wrapped blob and the biometric
/// item in the Keychain (through the injected `KeychainAccessing` seam).
final class LiveMasterKeyStore: MasterKeyStoring {
    /// Account of the password-wrapped master-key blob (v1 format, see `MasterKeyBlob`).
    static let blobAccount = "com.KoalaTVault.masterKeyBlob"
    /// Account of the biometric-protected item holding the raw 32-byte master key.
    static let biometricAccount = "com.KoalaTVault.biometricMasterKey"
    /// Account of the plaintext password item older app versions stored; deleted on unlock.
    static let legacyPasswordAccount = "com.KoalaTVault.password"

    private let keychain: any KeychainAccessing
    /// The loaded key; every access goes through the lock so a wipe can't race a reader.
    private let loadedKey = OSAllocatedUnfairLock<SymmetricKey?>(initialState: nil)

    /// A store over `keychain`, with no key loaded.
    init(keychain: any KeychainAccessing) {
        self.keychain = keychain
    }

    var isKeyLoaded: Bool { loadedKey.withLock { $0 != nil } }

    func hasMasterKeyBlob() throws -> Bool {
        try keychain.read(account: Self.blobAccount, prompt: nil) != nil
    }

    func createMasterKey(password: String) throws {
        guard !password.isEmpty else { throw VaultCryptoError.emptyPassword }
        guard !(try hasMasterKeyBlob()) else { throw VaultCryptoError.masterKeyAlreadyExists }
        let key = SymmetricKey(size: .bits256)
        let blob = try MasterKeyBlob.seal(key, password: password)
        try keychain.write(blob, account: Self.blobAccount, accessibility: .whenUnlocked)
        load(key)
    }

    func unlock(password: String) throws {
        guard let blob = try keychain.read(account: Self.blobAccount, prompt: nil) else {
            throw VaultCryptoError.noMasterKeyBlob
        }
        let key = try MasterKeyBlob.open(blob, password: password)
        load(key)
        // Best effort: a leftover plaintext password from older versions must not block unlock.
        try? keychain.delete(account: Self.legacyPasswordAccount)
    }

    func rewrap(newPassword: String) throws {
        let blob = try withKey { key in try MasterKeyBlob.seal(key, password: newPassword) }
        // The seam replaces the item in place, so a failed write leaves the old blob.
        try keychain.write(blob, account: Self.blobAccount, accessibility: .whenUnlocked)
    }

    func deleteMasterKeyBlob() throws {
        try keychain.delete(account: Self.blobAccount)
    }

    func storeBiometricKey() throws {
        var keyData = try withKey { key in key.withUnsafeBytes { Data($0) } }
        defer { MasterKeyBlob.zero(&keyData) }
        // A single write: the seam replaces any old item without removing it first.
        try keychain.write(keyData, account: Self.biometricAccount, accessibility: .biometryCurrentSetThisDeviceOnly)
    }

    func unlockWithBiometricKey(prompt: String) throws {
        let item: Data?
        do {
            item = try keychain.read(account: Self.biometricAccount, prompt: prompt)
        } catch VaultCryptoError.keychain(errSecUserCanceled) {
            throw VaultCryptoError.biometricCancelled
        } catch VaultCryptoError.keychain(errSecItemNotFound) {
            throw VaultCryptoError.biometricItemMissing
        }
        guard var keyData = item else { throw VaultCryptoError.biometricItemMissing }
        defer { MasterKeyBlob.zero(&keyData) }
        guard keyData.count == MasterKeyBlob.keySize else { throw VaultCryptoError.invalidKeyData }
        load(SymmetricKey(data: keyData))
    }

    func deleteBiometricKey() throws {
        try keychain.delete(account: Self.biometricAccount)
    }

    func wipeKey() {
        loadedKey.withLock { $0 = nil }
    }

    func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        // Captured once: a wipe while `body` runs doesn't affect the copy it holds.
        guard let key = loadedKey.withLock({ $0 }) else { throw VaultCryptoError.noKeyLoaded }
        return try body(key)
    }

    private func load(_ key: SymmetricKey) {
        loadedKey.withLock { $0 = key }
    }
}
