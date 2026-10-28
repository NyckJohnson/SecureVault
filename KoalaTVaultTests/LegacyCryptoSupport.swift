//
//  LegacyCryptoSupport.swift
//  KoalaTVault
//
//  Shared access for the legacy tests to the vault's key store, cipher and Keychain, the same
//  ones the legacy singletons use (`LegacyStorage.current`). The test plan launches the host app
//  with `-uiTesting`, so these are in memory and never the real Keychain.
//

import Foundation
@testable import KoalaTVault

enum TestCrypto {
    static var keyStore: any MasterKeyStoring {
        requireInMemoryKeychain()
        return LegacyStorage.current.masterKeyStore
    }

    static var cipher: any FileCipher {
        requireInMemoryKeychain()
        return LegacyStorage.current.fileCipher
    }

    static var keychain: any KeychainAccessing {
        requireInMemoryKeychain()
        return LegacyStorage.current.keychain
    }

    static var copyChecker: EncryptedCopyChecker {
        EncryptedCopyChecker(keyStore: keyStore, cipher: cipher)
    }

    static let blobAccount = "com.KoalaTVault.masterKeyBlob"
    static let biometricAccount = "com.KoalaTVault.biometricMasterKey"

    /// True when the legacy storage is the in-memory one (never the real Keychain).
    static var usesInMemoryKeychain: Bool { LegacyStorage.current.keychain is InMemoryKeychain }

    /// Stops the test run rather than let a test reach the real Keychain.
    static func requireInMemoryKeychain() {
        precondition(usesInMemoryKeychain, "legacy tests must run against the in-memory Keychain (-uiTesting)")
    }

    /// Unloads the key and removes the blob and the biometric item from the in-memory Keychain.
    static func reset() {
        keyStore.wipeKey()
        try? keyStore.deleteMasterKeyBlob()
        try? keyStore.deleteBiometricKey()
    }
}
