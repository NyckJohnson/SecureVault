import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultCatalogTests {
    private struct Fixture {
        let root: URL
        let vaults: URL
        let keychain: MockKeychainAccessing
        let catalog: VaultCatalog

        init(blobs: [String] = []) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            vaults = root.appendingPathComponent("Vaults")
            try FileManager.default.createDirectory(at: vaults, withIntermediateDirectories: true)
            var items: [String: Data] = [:]
            for id in blobs { items[VaultCatalog.blobAccount(for: id)] = Data([1]) }
            keychain = MockKeychainAccessing(items: items)
            catalog = VaultCatalog(vaultsFolder: vaults, keychain: keychain)
        }

        func makeFolder(_ id: String) throws {
            try FileManager.default.createDirectory(
                at: vaults.appendingPathComponent(id), withIntermediateDirectories: true)
        }

        func exists(_ id: String) -> Bool {
            FileManager.default.fileExists(atPath: vaults.appendingPathComponent(id).path)
        }
    }

    // MARK: Accounts and constants

    @Test("The primary vault's blob account is the old master key account")
    func primaryBlobAccount() {
        #expect(VaultCatalog.blobAccount(for: "primary") == "com.KoalaTVault.masterKeyBlob")
    }

    @Test("Another vault's blob account carries its ID")
    func otherBlobAccount() {
        #expect(VaultCatalog.blobAccount(for: "abc-123") == "com.KoalaTVault.masterKeyBlob.abc-123")
    }

    @Test("The constants have the specified values")
    func constants() {
        #expect(VaultCatalog.primaryID == "primary")
        #expect(VaultCatalog.markerAccount == "com.KoalaTVault.biometricVaultID")
        #expect(VaultCatalog.defaultName == "My Vault")
    }

    @Test("A vault's folder is its ID under the vaults folder")
    func folderURL() throws {
        let fixture = try Fixture()
        let url = fixture.catalog.folderURL(for: "abc")
        #expect(url.standardizedFileURL == fixture.vaults.appendingPathComponent("abc").standardizedFileURL)
    }

    // MARK: vaultIDs

    @Test("vaultIDs lists only folders whose blob exists, sorted")
    func vaultIDsListsFoldersWithBlobSorted() throws {
        let fixture = try Fixture(blobs: ["zeta", "primary", "alpha"])
        for id in ["zeta", "primary", "alpha", "orphan"] { try fixture.makeFolder(id) }
        #expect(fixture.catalog.vaultIDs() == ["alpha", "primary", "zeta"])
    }

    @Test("vaultIDs ignores plain files even when a blob exists")
    func vaultIDsIgnoresPlainFiles() throws {
        let fixture = try Fixture(blobs: ["real", "file"])
        try fixture.makeFolder("real")
        try Data("x".utf8).write(to: fixture.vaults.appendingPathComponent("file"))
        #expect(fixture.catalog.vaultIDs() == ["real"])
    }

    @Test("vaultIDs counts a Keychain read error as the blob existing")
    func vaultIDsKeychainErrorCountsAsExisting() throws {
        let fixture = try Fixture()
        try fixture.makeFolder("b")
        try fixture.makeFolder("a")
        fixture.keychain.errorToThrow = .keychain(-25308)
        #expect(fixture.catalog.vaultIDs() == ["a", "b"])
    }

    @Test("vaultIDs is empty when the vaults folder is missing")
    func vaultIDsMissingFolder() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = VaultCatalog(vaultsFolder: missing, keychain: MockKeychainAccessing())
        #expect(catalog.vaultIDs().isEmpty)
    }

    @Test("vaultIDs is empty when the vaults folder is empty")
    func vaultIDsEmptyFolder() throws {
        let fixture = try Fixture()
        #expect(fixture.catalog.vaultIDs().isEmpty)
    }

    // MARK: removeInterruptedCreations

    @Test("removeInterruptedCreations removes folders without a blob and keeps the others")
    func removeInterruptedRemovesBloblessOnly() throws {
        let fixture = try Fixture(blobs: ["keep"])
        try fixture.makeFolder("keep")
        try fixture.makeFolder("orphan1")
        try fixture.makeFolder("orphan2")
        fixture.catalog.removeInterruptedCreations()
        #expect(fixture.exists("keep"))
        #expect(!fixture.exists("orphan1"))
        #expect(!fixture.exists("orphan2"))
    }

    @Test("removeInterruptedCreations removes nothing on a Keychain error")
    func removeInterruptedKeepsAllOnKeychainError() throws {
        let fixture = try Fixture()
        try fixture.makeFolder("a")
        try fixture.makeFolder("b")
        fixture.keychain.errorToThrow = .keychain(-25308)
        fixture.catalog.removeInterruptedCreations()
        #expect(fixture.exists("a"))
        #expect(fixture.exists("b"))
    }

    @Test("removeInterruptedCreations keeps a blobless folder holding a file and removes an empty one")
    func removeInterruptedKeepsFolderWithFile() throws {
        let fixture = try Fixture()
        try fixture.makeFolder("full")
        try fixture.makeFolder("empty")
        try Data("x".utf8).write(to: fixture.vaults.appendingPathComponent("full").appendingPathComponent("a"))
        fixture.catalog.removeInterruptedCreations()
        #expect(fixture.exists("full"))
        #expect(!fixture.exists("empty"))
        #expect(fixture.catalog.vaultIDs().isEmpty)
    }

    @Test("removeInterruptedCreations keeps a blobless folder holding only a hidden file")
    func removeInterruptedKeepsFolderWithHiddenFile() throws {
        let fixture = try Fixture()
        try fixture.makeFolder("hidden")
        try fixture.makeFolder("empty")
        try Data("x".utf8).write(
            to: fixture.vaults.appendingPathComponent("hidden").appendingPathComponent(".vault_map"))
        fixture.catalog.removeInterruptedCreations()
        #expect(fixture.exists("hidden"))
        #expect(!fixture.exists("empty"))
        #expect(fixture.catalog.vaultIDs().isEmpty)
    }

    @Test("removeInterruptedCreations keeps a blobless folder holding a subfolder")
    func removeInterruptedKeepsFolderWithSubfolder() throws {
        let fixture = try Fixture()
        try fixture.makeFolder("nested")
        try fixture.makeFolder("empty")
        try FileManager.default.createDirectory(
            at: fixture.vaults.appendingPathComponent("nested").appendingPathComponent("sub"),
            withIntermediateDirectories: true)
        fixture.catalog.removeInterruptedCreations()
        #expect(fixture.exists("nested"))
        #expect(!fixture.exists("empty"))
        #expect(fixture.catalog.vaultIDs().isEmpty)
    }

    @Test("removeInterruptedCreations with a missing vaults folder does nothing")
    func removeInterruptedMissingFolder() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = VaultCatalog(vaultsFolder: missing, keychain: MockKeychainAccessing())
        catalog.removeInterruptedCreations()
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // MARK: Names

    @Test("A written name reads back")
    func nameRoundTrip() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        let cipher = MockFileCipher()
        try fixture.catalog.writeName("Holiday photos", of: "v1", cipher: cipher)
        #expect(fixture.catalog.readName(of: "v1", cipher: cipher) == "Holiday photos")
    }

    @Test("The name is sealed under the .vault_info context in the vault's .vault_info file")
    func nameIsSealed() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        let cipher = MockFileCipher()
        try fixture.catalog.writeName("Secret", of: "v1", cipher: cipher)
        #expect(cipher.calls.contains(.encrypt(context: ".vault_info")))
        let raw = try Data(contentsOf: fixture.catalog.folderURL(for: "v1").appendingPathComponent(".vault_info"))
        #expect((try? JSONSerialization.jsonObject(with: raw)) == nil)
        _ = try cipher.decrypt(raw, contexts: [".vault_info"])
    }

    @Test("The sealed name holds JSON with a name key")
    func nameJSONShape() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        let cipher = MockFileCipher()
        try fixture.catalog.writeName("Docs", of: "v1", cipher: cipher)
        let raw = try Data(contentsOf: fixture.catalog.folderURL(for: "v1").appendingPathComponent(".vault_info"))
        let plain = try cipher.decrypt(raw, contexts: [".vault_info"])
        let object = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: String])
        #expect(object["name"] == "Docs")
    }

    @Test("The written .vault_info file has complete file protection")
    func vaultInfoHasCompleteProtection() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        try fixture.catalog.writeName("Protected", of: "v1", cipher: MockFileCipher())
        let url = fixture.catalog.folderURL(for: "v1").appendingPathComponent(".vault_info")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        #expect(protection == FileProtectionType.complete)
    }

    @Test("Writing a name again replaces the earlier name")
    func nameOverwrite() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        let cipher = MockFileCipher()
        try fixture.catalog.writeName("First", of: "v1", cipher: cipher)
        try fixture.catalog.writeName("Second", of: "v1", cipher: cipher)
        #expect(fixture.catalog.readName(of: "v1", cipher: cipher) == "Second")
    }

    @Test("A name with quotes and unicode round-trips")
    func nameSpecialCharacters() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        let cipher = MockFileCipher()
        let name = "Mum's \"best\" vault \u{1F43C}"
        try fixture.catalog.writeName(name, of: "v1", cipher: cipher)
        #expect(fixture.catalog.readName(of: "v1", cipher: cipher) == name)
    }

    @Test("readName is nil when .vault_info is missing")
    func readNameMissing() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        #expect(fixture.catalog.readName(of: "v1", cipher: MockFileCipher()) == nil)
    }

    @Test("readName is nil when the vault's folder is missing")
    func readNameMissingFolder() throws {
        let fixture = try Fixture()
        #expect(fixture.catalog.readName(of: "ghost", cipher: MockFileCipher()) == nil)
    }

    @Test("readName is nil when .vault_info is garbage")
    func readNameGarbage() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        try Data("not sealed at all".utf8).write(
            to: fixture.catalog.folderURL(for: "v1").appendingPathComponent(".vault_info"))
        #expect(fixture.catalog.readName(of: "v1", cipher: MockFileCipher()) == nil)
    }

    @Test("readName is nil when the name was sealed under another context")
    func readNameWrongContext() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        let cipher = MockFileCipher()
        let sealed = try cipher.encrypt(Data(#"{"name":"X"}"#.utf8), context: ".vault_map")
        try sealed.write(to: fixture.catalog.folderURL(for: "v1").appendingPathComponent(".vault_info"))
        #expect(fixture.catalog.readName(of: "v1", cipher: cipher) == nil)
    }

    @Test("readName is nil when the sealed content is not the name JSON")
    func readNameWrongJSON() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        let cipher = MockFileCipher()
        let sealed = try cipher.encrypt(Data("[1, 2]".utf8), context: ".vault_info")
        try sealed.write(to: fixture.catalog.folderURL(for: "v1").appendingPathComponent(".vault_info"))
        #expect(fixture.catalog.readName(of: "v1", cipher: cipher) == nil)
    }

    @Test("readName is nil when decryption fails")
    func readNameCipherError() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        let cipher = MockFileCipher()
        try fixture.catalog.writeName("Name", of: "v1", cipher: cipher)
        cipher.errorToThrow = .noKeyLoaded
        #expect(fixture.catalog.readName(of: "v1", cipher: cipher) == nil)
    }

    @Test("writeName throws when the cipher fails")
    func writeNameCipherError() throws {
        let fixture = try Fixture(blobs: ["v1"])
        try fixture.makeFolder("v1")
        let cipher = MockFileCipher()
        cipher.errorToThrow = .noKeyLoaded
        #expect(throws: (any Error).self) {
            try fixture.catalog.writeName("Name", of: "v1", cipher: cipher)
        }
    }

    // MARK: Biometric marker

    @Test("The marker is nil when absent")
    func markerAbsent() throws {
        let fixture = try Fixture()
        #expect(fixture.catalog.biometricVaultID() == nil)
    }

    @Test("The marker is written as UTF-8 under the marker account, accessible when unlocked")
    func markerWrite() throws {
        let fixture = try Fixture()
        try fixture.catalog.setBiometricVaultID("vault-é")
        #expect(fixture.keychain.items[VaultCatalog.markerAccount] == Data("vault-é".utf8))
        #expect(
            fixture.keychain.calls.contains(
                .write(account: VaultCatalog.markerAccount, accessibility: .whenUnlocked)))
    }

    @Test("A written marker reads back")
    func markerRoundTrip() throws {
        let fixture = try Fixture()
        try fixture.catalog.setBiometricVaultID("primary")
        #expect(fixture.catalog.biometricVaultID() == "primary")
    }

    @Test("Setting the marker again replaces it")
    func markerReplace() throws {
        let fixture = try Fixture()
        try fixture.catalog.setBiometricVaultID("one")
        try fixture.catalog.setBiometricVaultID("two")
        #expect(fixture.catalog.biometricVaultID() == "two")
    }

    @Test("Setting the marker to nil deletes the item")
    func markerDelete() throws {
        let fixture = try Fixture()
        try fixture.catalog.setBiometricVaultID("primary")
        try fixture.catalog.setBiometricVaultID(nil)
        #expect(fixture.keychain.items[VaultCatalog.markerAccount] == nil)
        #expect(fixture.keychain.calls.contains(.delete(account: VaultCatalog.markerAccount)))
        #expect(fixture.catalog.biometricVaultID() == nil)
    }

    @Test("Deleting an absent marker does not throw")
    func markerDeleteAbsent() throws {
        let fixture = try Fixture()
        try fixture.catalog.setBiometricVaultID(nil)
        #expect(fixture.catalog.biometricVaultID() == nil)
    }

    @Test("The marker reads as nil on a Keychain error")
    func markerKeychainErrorOnRead() throws {
        let fixture = try Fixture()
        try fixture.catalog.setBiometricVaultID("primary")
        fixture.keychain.errorToThrow = .keychain(-25308)
        #expect(fixture.catalog.biometricVaultID() == nil)
    }

    @Test("The marker reads as nil when its data is empty")
    func markerEmpty() {
        let keychain = MockKeychainAccessing(items: [VaultCatalog.markerAccount: Data()])
        let catalog = VaultCatalog(
            vaultsFolder: FileManager.default.temporaryDirectory, keychain: keychain)
        #expect(catalog.biometricVaultID() == nil)
    }

    @Test("The marker reads as nil when its data is not UTF-8")
    func markerUnreadable() throws {
        let keychain = MockKeychainAccessing(items: [VaultCatalog.markerAccount: Data([0xFF, 0xFE, 0xFD])])
        let catalog = VaultCatalog(
            vaultsFolder: FileManager.default.temporaryDirectory, keychain: keychain)
        #expect(catalog.biometricVaultID() == nil)
    }

    @Test("Writing the marker throws on a Keychain error")
    func markerWriteKeychainError() throws {
        let fixture = try Fixture()
        fixture.keychain.errorToThrow = .keychain(-25308)
        #expect(throws: (any Error).self) {
            try fixture.catalog.setBiometricVaultID("primary")
        }
    }
}
