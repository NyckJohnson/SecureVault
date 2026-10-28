import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultMigrationStepsTests {
    private func isEncryptFile(_ call: MockFileCipher.Call) -> Bool {
        if case .encryptFile = call { return true }
        return false
    }

    // MARK: - countFiles

    @Test(
        "countFiles counts files in subfolders, not folders, hidden entries or the trash",
        arguments: [LockMode.none, .password])
    func countFilesCountsFilesOnly(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let inner = try await vault.store.createFolder(named: "Inner", in: try #require(docs.asDirectory))
        try await vault.add("a.txt")
        let docsDir = try #require(docs.asDirectory)
        try await vault.add("b.txt", to: docsDir)
        let innerDir = try #require(inner.asDirectory)
        try await vault.add("c.txt", to: innerDir)
        let trashedItem = try await vault.add("trashed.txt")
        try await vault.store.moveToTrash(trashedItem)
        #expect(try await vault.store.countFiles() == 3)
    }

    @Test("countFiles of an empty vault is 0 and empty folders add nothing")
    func countFilesEmpty() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        #expect(try await vault.store.countFiles() == 0)
        try vault.folder("Empty")
        #expect(try await vault.store.countFiles() == 0)
    }

    // MARK: - itemsToMigrate

    @Test("itemsToMigrate(toEncrypted: true) lists every plaintext file under the root and in the trash")
    func itemsToEncryptListsPlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try await vault.add("a.txt")
        try await vault.add("b.txt", to: docs)
        let trashedSource = try await vault.add("c.txt")
        try await vault.store.moveToTrash(trashedSource)

        let items = try await vault.store.itemsToMigrate(toEncrypted: true)
        #expect(Set(items.map(\.name)) == ["a.txt", "b.txt", "c.txt"])
        #expect(items.allSatisfy { !$0.isDirectory && !$0.isEncrypted })
        #expect(items.first { $0.name == "b.txt" }?.id == "Docs/b.txt")
        #expect(items.first { $0.name == "c.txt" }?.id.hasPrefix(".trash/") == true)
    }

    @Test("itemsToMigrate(toEncrypted: true) skips files already encrypted but keeps leftover plaintext")
    func itemsToEncryptSkipsEncrypted() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("done.txt")
        try vault.diskFile("left.txt", "left")
        let items = try await vault.store.itemsToMigrate(toEncrypted: true)
        #expect(items.map(\.name) == ["left.txt"])
    }

    @Test("itemsToMigrate(toEncrypted: false) lists every encrypted file under the root and in the trash")
    func itemsToDecryptListsEncrypted() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try await vault.add("a.txt")
        try await vault.add("b.txt", to: docs)
        let trashedSource = try await vault.add("c.txt")
        try await vault.store.moveToTrash(trashedSource)
        try vault.diskFile("plain.txt", "plain")

        let items = try await vault.store.itemsToMigrate(toEncrypted: false)
        #expect(Set(items.map(\.name)) == ["a.txt", "b.txt", "c.txt"])
        #expect(items.allSatisfy { $0.isEncrypted && !$0.isDirectory })
        #expect(items.first { $0.name == "c.txt" }?.id.hasPrefix(".trash/") == true)
    }

    @Test("itemsToMigrate is empty for an empty vault in both directions")
    func itemsToMigrateEmpty() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        #expect(try await vault.store.itemsToMigrate(toEncrypted: true).isEmpty)
        #expect(try await vault.store.itemsToMigrate(toEncrypted: false).isEmpty)
    }

    // MARK: - migrateToEncrypted

    @Test("migrateToEncrypted turns a plaintext file into an indexed UUID file and removes the plaintext")
    func migrateToEncryptedBasic() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile("secret.txt", "secret", in: docs)
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)
        try await vault.store.migrateToEncrypted(item)

        let names = try vault.diskNames(in: docs)
        #expect(!names.contains("secret.txt"))
        let diskName = try #require(names.first { UUID(uuidString: $0) != nil })
        #expect(vault.indexEntries(in: docs) == [diskName: "secret.txt"])
        #expect(vault.indexContext(in: docs) == ".vault_map")
        #expect(vault.cipher.calls.contains(where: isEncryptFile))
        let listed = try await vault.list(docs)
        #expect(listed.map(\.name) == ["secret.txt"])
        #expect(listed.first?.isEncrypted == true)
        #expect(try await vault.openedContent(try #require(listed.first)) == "secret")
        #expect(try await vault.store.itemsToMigrate(toEncrypted: true).isEmpty)
    }

    @Test("Migrating every plaintext file in order encrypts all of them")
    func migrateToEncryptedAll() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile("a.txt", "A")
        try vault.diskFile("b.txt", "B", in: docs)
        try vault.diskFile("c.txt", "C", in: docs)
        for item in try await vault.store.itemsToMigrate(toEncrypted: true) {
            try await vault.store.migrateToEncrypted(item)
        }
        #expect(try await vault.names() == ["Docs", "a.txt"])
        #expect(try await vault.names(docs) == ["b.txt", "c.txt"])
        #expect(try await vault.store.hasUnencryptedFiles() == false)
        #expect(vault.indexEntries(in: docs)?.count == 2)
    }

    @Test("migrateToEncrypted with identical content already under that name only removes the plaintext")
    func migrateToEncryptedDedupes() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let existing = try await vault.add("a.txt", "same")
        let indexBefore = vault.indexEntries()
        try vault.diskFile("a.txt", "same")
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)
        try await vault.store.migrateToEncrypted(item)

        #expect(try await vault.names() == ["a.txt"])
        #expect(vault.indexEntries() == indexBefore)
        #expect(try vault.diskNames().filter { $0 != ".vault_map" }.count == 1)
        #expect(try await vault.openedContent(existing) == "same")
        #expect(try await vault.store.hasUnencryptedFiles() == false)
    }

    @Test("migrateToEncrypted with different content under the same name keeps both, the new one as ' 1'")
    func migrateToEncryptedDifferentContent() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let existing = try await vault.add("a.txt", "encrypted version")
        try vault.diskFile("a.txt", "plaintext version")
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)
        try await vault.store.migrateToEncrypted(item)

        let listed = try await vault.list()
        #expect(listed.map(\.name) == ["a 1.txt", "a.txt"])
        #expect(listed.allSatisfy { $0.isEncrypted })
        let renamed = try #require(listed.first { $0.name == "a 1.txt" })
        #expect(try await vault.openedContent(renamed) == "plaintext version")
        #expect(try await vault.openedContent(existing) == "encrypted version")
        #expect(try await vault.store.hasUnencryptedFiles() == false)
    }

    @Test("migrateToEncrypted re-encrypts a trash item in place and updates its entry")
    func migrateToEncryptedTrashItem() async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let item = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(item)
        vault.prefs.lockMode = .password

        let pending = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)
        try await vault.store.migrateToEncrypted(pending)

        let trashed = try await vault.store.trashContents()
        #expect(trashed.map(\.name) == ["old.txt"])
        #expect(trashed.first?.id == pending.id)
        #expect(trashed.first?.isEncrypted == true)
        let entry = try #require(vault.trashEntries()?.values.first)
        #expect(entry["isEncrypted"] as? Bool == true)
        #expect(vault.trashMapContext() == ".trash_map")
        #expect(vault.cipher.calls.contains(where: isEncryptFile))
        #expect(try await vault.store.itemsToMigrate(toEncrypted: true).isEmpty)

        let restored = try await vault.store.restore(try #require(trashed.first))
        #expect(restored.isEncrypted)
        #expect(try await vault.openedContent(restored) == "old content")
    }

    @Test("A failed encryption leaves the plaintext file, adds no entry and no stray file")
    func migrateToEncryptedFailure() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.diskFile("a.txt", "keep me")
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)
        let before = try vault.snapshot()
        vault.cipher.errorToThrow = .encryptionFailed
        let error = await caught { try await vault.store.migrateToEncrypted(item) }
        #expect(error != nil)
        #expect(try vault.snapshot() == before)
        #expect(try vault.content(item.diskURL) == "keep me")
    }

    // MARK: - migrateToDecrypted

    @Test("migrateToDecrypted writes the plaintext under its original name, drops the entry and the encrypted file")
    func migrateToDecryptedBasic() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let added = try await vault.add("report.pdf", "pdf bytes", to: docs)
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: false).first)
        try await vault.store.migrateToDecrypted(item)

        let names = try vault.diskNames(in: docs)
        #expect(names.contains("report.pdf"))
        #expect(!names.contains((added.id as NSString).lastPathComponent))
        #expect(try vault.content(docs.diskURL.appendingPathComponent("report.pdf")) == "pdf bytes")
        #expect(vault.indexEntries(in: docs)?.isEmpty ?? true)
        #expect(try await vault.store.itemsToMigrate(toEncrypted: false).isEmpty)
        #expect(try await vault.store.hasUnencryptedFiles())
    }

    @Test("migrateToDecrypted resolves a name conflict with ' 1'")
    func migrateToDecryptedConflict() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "encrypted")
        try vault.diskFile("a.txt", "already here")
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: false).first)
        try await vault.store.migrateToDecrypted(item)

        #expect(try vault.content(vault.rootURL.appendingPathComponent("a.txt")) == "already here")
        #expect(try vault.content(vault.rootURL.appendingPathComponent("a 1.txt")) == "encrypted")
        #expect(vault.indexEntries()?.isEmpty ?? true)
    }

    @Test("Migrating every encrypted file in order decrypts all of them")
    func migrateToDecryptedAll() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try await vault.add("a.txt", "A")
        try await vault.add("b.txt", "B", to: docs)
        try await vault.add("c.txt", "C", to: docs)
        for item in try await vault.store.itemsToMigrate(toEncrypted: false) {
            try await vault.store.migrateToDecrypted(item)
        }
        #expect(try vault.diskNames().filter { $0 != ".vault_map" } == ["Docs", "a.txt"])
        #expect(try vault.diskNames(in: docs).filter { $0 != ".vault_map" } == ["b.txt", "c.txt"])
        #expect(try vault.content(vault.rootURL.appendingPathComponent("a.txt")) == "A")
        #expect(try vault.content(docs.diskURL.appendingPathComponent("c.txt")) == "C")
        #expect(try await vault.store.itemsToMigrate(toEncrypted: false).isEmpty)
    }

    @Test("A decrypt failure leaves the encrypted file and its entry")
    func migrateToDecryptedFailure() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "keep me")
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: false).first)
        let before = try vault.snapshot()
        vault.cipher.errorToThrow = .decryptionFailed
        let error = await caught { try await vault.store.migrateToDecrypted(item) }
        #expect(error != nil)
        #expect(try vault.snapshot() == before)
        vault.cipher.errorToThrow = nil
        #expect(try await vault.names() == ["a.txt"])
        #expect(try await vault.openedContent(item) == "keep me")
    }

    @Test("migrateToDecrypted decrypts a trash item so it restores as plaintext")
    func migrateToDecryptedTrashItem() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(item)
        let pending = try #require(try await vault.store.itemsToMigrate(toEncrypted: false).first)
        try await vault.store.migrateToDecrypted(pending)

        #expect(try await vault.store.itemsToMigrate(toEncrypted: false).isEmpty)
        let trashed = try await vault.store.trashContents()
        #expect(trashed.map(\.name) == ["old.txt"])
        #expect(trashed.first?.isEncrypted == false)
        #expect(vault.trashEntries()?.values.first?["isEncrypted"] as? Bool == false)
    }

    // MARK: - finishDecryption

    @Test("finishDecryption with an encrypted file left throws stillEncrypted with the count and changes nothing")
    func finishDecryptionStillEncrypted() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try await vault.add("a.txt")
        try await vault.add("b.txt", to: docs)
        try await vault.add("c.txt", to: docs)
        let before = try vault.snapshot()
        let error = await caught { try await vault.store.finishDecryption() }
        #expect(error as? VaultStoreError == .stillEncrypted(count: 3))
        #expect(try vault.snapshot() == before)
    }

    @Test("finishDecryption counts a leftover encrypted file in the trash")
    func finishDecryptionCountsTrash() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        try await vault.store.moveToTrash(item)
        let error = await caught { try await vault.store.finishDecryption() }
        #expect(error as? VaultStoreError == .stillEncrypted(count: 1))
    }

    @Test("finishDecryption deletes every .vault_map, rewrites .trash_map as plaintext and the vault lists with no key")
    func finishDecryptionCleansUp() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let inner = try vault.folder("Inner", in: docs)
        try await vault.add("a.txt", "A")
        try await vault.add("b.txt", "B", to: docs)
        try await vault.add("c.txt", "C", to: inner)
        let trashedSource = try await vault.add("t.txt", "T")
        try await vault.store.moveToTrash(trashedSource)
        for item in try await vault.store.itemsToMigrate(toEncrypted: false) {
            try await vault.store.migrateToDecrypted(item)
        }
        try await vault.store.finishDecryption()

        #expect(vault.indexFilePaths().isEmpty)
        #expect(vault.trashMapIsPlaintextJSON())
        #expect(vault.trashEntries()?.count == 1)

        vault.prefs.lockMode = .none
        vault.keys.wipeKey()
        #expect(try await vault.names() == ["Docs", "a.txt"])
        #expect(try await vault.names(docs) == ["Inner", "b.txt"])
        #expect(try await vault.names(inner) == ["c.txt"])
        let trashed = try await vault.store.trashContents()
        #expect(trashed.map(\.name) == ["t.txt"])
        #expect(trashed.first?.isEncrypted == false)
        let restored = try await vault.store.restore(try #require(trashed.first))
        #expect(try vault.content(restored.diskURL) == "T")
    }

    @Test("finishDecryption on a vault with no indexes succeeds")
    func finishDecryptionNothingToDo() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.diskFile("plain.txt", "p")
        try await vault.store.finishDecryption()
        #expect(try vault.content(vault.rootURL.appendingPathComponent("plain.txt")) == "p")
    }

    // MARK: - hasUnencryptedFiles

    @Test("hasUnencryptedFiles is true for a plaintext file under the root", arguments: [LockMode.none, .password])
    func hasUnencryptedInRoot(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile("plain.txt", "p", in: docs)
        #expect(try await vault.store.hasUnencryptedFiles())
    }

    @Test("hasUnencryptedFiles is true for a plaintext file only in the trash")
    func hasUnencryptedInTrash() async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let item = try await vault.add("plain.txt")
        try await vault.store.moveToTrash(item)
        #expect(try await vault.store.hasUnencryptedFiles())
    }

    @Test("hasUnencryptedFiles is false when every file is encrypted or the vault is empty")
    func hasUnencryptedFalse() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        #expect(try await vault.store.hasUnencryptedFiles() == false)
        let kept = try await vault.add("a.txt")
        let trashedSource = try await vault.add("b.txt")
        try await vault.store.moveToTrash(trashedSource)
        #expect(kept.isEncrypted)
        #expect(try await vault.store.hasUnencryptedFiles() == false)
    }

    // MARK: - keyMatchesVault

    @Test("keyMatchesVault is true when the key decrypts the root index")
    func keyMatchesTrue() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        #expect(await vault.store.keyMatchesVault())
    }

    @Test("keyMatchesVault is true when there is no root index to check", arguments: [LockMode.none, .password])
    func keyMatchesNoIndex(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        #expect(await vault.store.keyMatchesVault())
    }

    @Test("keyMatchesVault is false when the key can't decrypt the root index")
    func keyMatchesFalse() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        try vault.writeRawIndex(Data("sealed with another key".utf8))
        #expect(await vault.store.keyMatchesVault() == false)
    }

    @Test("keyMatchesVault is false when an encrypted root index exists and no key is loaded")
    func keyMatchesNoKey() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        vault.keys.wipeKey()
        #expect(await vault.store.keyMatchesVault() == false)
    }

    // MARK: - Locked

    enum LockedMigrationOperation: String, CaseIterable, Sendable {
        case itemsToEncrypt, itemsToDecrypt, migrateToEncrypted, migrateToDecrypted
        case finishDecryption, hasUnencryptedFiles
    }

    @Test(
        "Migration operations in encrypted mode without a key throw locked and change nothing",
        arguments: LockedMigrationOperation.allCases, [LockMode.password, .passwordAndBiometrics])
    func lockedMigrationOperations(operation: LockedMigrationOperation, mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let encrypted = try await vault.add("secret.txt", "secret")
        let plain = try vault.diskFile("plain.txt", "plain")
        let plainItem = VaultItem(
            id: "plain.txt", name: "plain.txt", isDirectory: false, dateModified: Date(), fileSize: 5, deletedAt: nil,
            diskURL: plain, rootURL: vault.rootURL, isEncrypted: false)
        vault.keys.wipeKey()
        let before = try vault.snapshot()

        let error = await caught {
            switch operation {
            case .itemsToEncrypt: _ = try await vault.store.itemsToMigrate(toEncrypted: true)
            case .itemsToDecrypt: _ = try await vault.store.itemsToMigrate(toEncrypted: false)
            case .migrateToEncrypted: try await vault.store.migrateToEncrypted(plainItem)
            case .migrateToDecrypted: try await vault.store.migrateToDecrypted(encrypted)
            case .finishDecryption: try await vault.store.finishDecryption()
            case .hasUnencryptedFiles: _ = try await vault.store.hasUnencryptedFiles()
            }
        }
        #expect(error as? VaultStoreError == .locked)
        #expect(try vault.snapshot() == before)
    }
}
