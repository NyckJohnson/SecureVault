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

// MARK: - Legacy vault harness

/// A real `LiveVaultStore` over a unique temporary vault, using the legacy storage's (in-memory) key
/// store and cipher, so legacy tests can exercise the real encryption through the module's contract.
/// Encrypted mode is the preferences' lock mode: set `preferences.lockMode` to `.password` for it.
final class LegacyVaultHarness: @unchecked Sendable {
    let base: URL
    let rootURL: URL
    let root: VaultDirectory
    let preferences: MockPreferencesStoring
    let store: LiveVaultStore

    init(lockMode: LockMode = .none) throws {
        TestCrypto.requireInMemoryKeychain()
        let manager = FileManager.default
        let raw = manager.temporaryDirectory.appendingPathComponent(
            "LegacyVaultHarness-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: raw, withIntermediateDirectories: true)
        base = raw.resolvingSymlinksInPath()
        rootURL = base.appendingPathComponent("Vault", isDirectory: true)
        let tempRoot = base.appendingPathComponent("Temp", isDirectory: true)
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        root = VaultDirectory(name: "KoalaTVault", diskURL: rootURL, rootURL: rootURL)
        preferences = MockPreferencesStoring(lockMode: lockMode)
        store = LiveVaultStore(
            root: rootURL, keyStore: TestCrypto.keyStore, cipher: TestCrypto.cipher,
            preferences: preferences, temporaryRoot: tempRoot)
    }

    /// Removes the temporary vault and resets the legacy key store.
    func cleanUp() {
        TestCrypto.reset()
        try? FileManager.default.removeItem(at: base)
    }

    /// Legacy import and export over this vault's store.
    func transfers() -> FileSystem {
        FileSystem(store: store)
    }

    /// Adds outside files to `directory` through the store, each under its own file name.
    func importFiles(_ urls: [URL], to directory: VaultDirectory) async throws {
        for url in urls {
            _ = try await store.addFile(from: url, named: url.lastPathComponent, to: directory)
        }
    }

    /// A file outside the vault, to import.
    func source(_ name: String, _ content: String) throws -> URL {
        let dir = base.appendingPathComponent("Sources/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// Writes a plaintext file straight onto the disk of `directory` (no index).
    @discardableResult
    func diskFile(_ name: String, _ content: String, in directory: VaultDirectory? = nil) throws -> URL {
        let url = (directory ?? root).diskURL.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// The folder's items, sorted by name.
    func items(in directory: VaultDirectory? = nil) async throws -> [VaultItem] {
        try await store.contents(of: directory ?? root, sortedBy: .name, .ascending)
    }

    /// A new folder under `parent` (the root by default).
    func folder(_ name: String, in parent: VaultDirectory? = nil) async throws -> VaultDirectory {
        let item = try await store.createFolder(named: name, in: parent ?? root)
        guard let directory = item.asDirectory else { throw VaultStoreError.notFound }
        return directory
    }

    /// The plaintext content of an item as the store opens it.
    func content(of item: VaultItem) async throws -> String {
        let url = try await store.open(item)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Whether the data is plaintext JSON.
    static func isPlaintextJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}

extension LegacyVaultHarness {
    /// An encrypted-mode store over an existing vault folder (the key must be loaded to write).
    static func encryptedStore(over root: URL) -> LiveVaultStore {
        TestCrypto.requireInMemoryKeychain()
        return LiveVaultStore(
            root: root, keyStore: TestCrypto.keyStore, cipher: TestCrypto.cipher,
            preferences: MockPreferencesStoring(lockMode: .password),
            temporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
                "LegacyEncryptedStore-\(UUID().uuidString)", isDirectory: true))
    }

    /// Adds one encrypted file (`secret.txt`) to the vault folder `root` with the loaded key, so the
    /// vault holds an encrypted file and an index.
    static func addEncryptedFile(to root: URL, named name: String = "secret.txt", content: String = "secret") async throws {
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let source = sourceDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: source)
        let directory = VaultDirectory(name: "test", diskURL: root, rootURL: root)
        _ = try await encryptedStore(over: root).addFile(from: source, named: name, to: directory)
    }
}
