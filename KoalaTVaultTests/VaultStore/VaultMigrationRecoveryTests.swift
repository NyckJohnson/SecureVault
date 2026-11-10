import Foundation
import Testing

@testable import KoalaTVault

/// Interrupt-safety of the migration steps. These use the header-aware cipher, because a file's real form is
/// judged by its SVC5 header, not by an index or trash-entry flag.
@Suite struct VaultMigrationRecoveryTests {
    /// The names of everything the user could see: opened content of every listed file in `directory`.
    private func contents(of directory: VaultDirectory?, in vault: VaultStoreFixture) async throws -> [String] {
        var result: [String] = []
        for item in try await vault.list(directory) where !item.isDirectory {
            result.append(try await vault.openedContent(item))
        }
        return result
    }

    private func leftoverURL(for item: VaultItem, in vault: VaultStoreFixture) -> URL {
        vault.trashURL.appendingPathComponent(".\((item.id as NSString).lastPathComponent).migrating")
    }

    // MARK: - Interrupted trash conversion, encrypt direction

    @Test(
        "A trash item whose entry says encrypted but whose file is still plaintext is listed and encrypted on rerun",
        arguments: [false, true])
    func interruptedTrashEncryption(withLeftover: Bool) async throws {
        let vault = try VaultStoreFixture(lockMode: .none, headerAware: true)
        defer { vault.cleanUp() }
        let source = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(source)
        vault.prefs.lockMode = .password
        try vault.rewriteTrashEntries { $0["isEncrypted"] = true }
        let trashed = try #require(try await vault.store.trashContents().first)
        if withLeftover {
            try Data("half-written".utf8).write(to: leftoverURL(for: trashed, in: vault))
        }

        let pending = try await vault.store.itemsToMigrate(toEncrypted: true)
        #expect(pending.map(\.name) == ["old.txt"])
        #expect(try await vault.store.itemsToMigrate(toEncrypted: false).isEmpty)
        #expect(try await vault.store.hasUnencryptedFiles())
        #expect(try await vault.store.trashContents().map(\.name) == ["old.txt"])
        let item = try #require(pending.first)
        try await vault.store.migrateToEncrypted(item)

        #expect(vault.isSealedOnDisk(item.diskURL))
        #expect(vault.trashEntries()?.count == 1)
        #expect(vault.trashEntries()?.values.first?["isEncrypted"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: leftoverURL(for: trashed, in: vault).path))
        #expect(try await vault.store.itemsToMigrate(toEncrypted: true).isEmpty)
        #expect(try await vault.store.hasUnencryptedFiles() == false)
        let again = try #require(try await vault.store.trashContents().first)
        #expect(again.isEncrypted)
        let restored = try await vault.store.restore(again)
        #expect(try await vault.openedContent(restored) == "old content")
    }

    @Test(
        "finishDecryption does not count a plaintext trash file whose entry wrongly says encrypted",
        .disabled("feature multiple-vaults-duress-password: rebuilt in VaultStore unit 2"))
    func plaintextTrashFileWithEncryptedFlagIsNotCounted() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, headerAware: true)
        defer { vault.cleanUp() }
        let source = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(source)
        vault.prefs.lockMode = .password
        try vault.rewriteTrashEntries { $0["isEncrypted"] = true }
        try await vault.store.finishDecryption()
        #expect(vault.indexFilePaths().isEmpty)
    }

    // MARK: - Interrupted trash conversion, decrypt direction

    @Test(
        "A trash item whose entry says plaintext but whose file is still ciphertext is listed, counted and decrypted on rerun",
        .disabled("feature multiple-vaults-duress-password: rebuilt in VaultStore unit 2"),
        arguments: [false, true])
    func interruptedTrashDecryption(withLeftover: Bool) async throws {
        #if false
            let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
            defer { vault.cleanUp() }
            let source = try await vault.add("old.txt", "old content")
            try await vault.store.moveToTrash(source)
            try vault.rewriteTrashEntries { $0["isEncrypted"] = false }
            let trashed = try #require(try await vault.store.trashContents().first)
            if withLeftover {
                try Data("half-written".utf8).write(to: leftoverURL(for: trashed, in: vault))
            }

            let pending = try await vault.store.itemsToMigrate(toEncrypted: false)
            #expect(pending.map(\.name) == ["old.txt"])
            #expect(try await vault.store.itemsToMigrate(toEncrypted: true).isEmpty)
            #expect(try await vault.store.hasUnencryptedFiles() == false)
            #expect(try await vault.store.trashContents().map(\.name) == ["old.txt"])
            let error = await caught { try await vault.store.finishDecryption() }
            #expect(error as? VaultStoreError == .stillEncrypted(count: 1))

            let item = try #require(pending.first)
            try await vault.store.migrateToDecrypted(item)

            #expect(!vault.isSealedOnDisk(item.diskURL))
            #expect(try vault.content(item.diskURL) == "old content")
            #expect(vault.trashEntries()?.values.first?["isEncrypted"] as? Bool == false)
            #expect(!FileManager.default.fileExists(atPath: leftoverURL(for: trashed, in: vault).path))
            #expect(try await vault.store.itemsToMigrate(toEncrypted: false).isEmpty)
            try await vault.store.finishDecryption()
            #expect(vault.indexFilePaths().isEmpty)
            #expect(vault.trashMapIsPlaintextJSON())
        #endif
    }

    @Test("A leftover .migrating staging file is never listed or counted as a file")
    func leftoverStagingFileIsNeverListed() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let source = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(source)
        let trashed = try #require(try await vault.store.trashContents().first)
        try Data("half-written".utf8).write(to: leftoverURL(for: trashed, in: vault))

        #expect(try await vault.store.trashContents().map(\.name) == ["old.txt"])
        let toEncrypt = try await vault.store.itemsToMigrate(toEncrypted: true)
        let toDecrypt = try await vault.store.itemsToMigrate(toEncrypted: false)
        for item in toEncrypt + toDecrypt { #expect(!item.diskURL.lastPathComponent.hasSuffix(".migrating")) }
        #expect(try await vault.store.countFiles() == 0)
    }

    // MARK: - Encrypt recovery

    @Test("A rerun with plaintext and an identical indexed encrypted copy only removes the plaintext")
    func encryptRerunWithIdenticalCopy() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let existing = try await vault.add("a.txt", "same")
        let entriesBefore = vault.indexEntries()
        try vault.diskFile("a.txt", "same")
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)
        try await vault.store.migrateToEncrypted(item)

        #expect(vault.indexEntries() == entriesBefore)
        #expect(try vault.diskNames().filter { $0 != ".vault_map" } == [(existing.id as NSString).lastPathComponent])
        #expect(try await vault.names() == ["a.txt"])
        #expect(try await contents(of: nil, in: vault) == ["same"])
    }

    @Test("A rerun with plaintext of different content keeps both, the plaintext one as ' 1'")
    func encryptRerunWithDifferentContent() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "indexed version")
        try vault.diskFile("a.txt", "leftover version")
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)
        try await vault.store.migrateToEncrypted(item)

        #expect(try await vault.names() == ["a 1.txt", "a.txt"])
        #expect(try await contents(of: nil, in: vault) == ["leftover version", "indexed version"])
        #expect(try await vault.store.hasUnencryptedFiles() == false)
    }

    @Test("An incomplete encrypted copy is dropped with its entry and the plaintext is kept")
    func incompleteCopyIsDropped() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        try vault.diskFile("a.txt", "full content")
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)
        vault.headerCipher?.truncatesNewCopies = true
        let error = await caught { try await vault.store.migrateToEncrypted(item) }

        #expect(error != nil)
        #expect(try vault.content(item.diskURL) == "full content")
        #expect(try vault.diskNames().filter { $0 != ".vault_map" } == ["a.txt"])
        #expect(vault.indexEntries()?.isEmpty ?? true)
        #expect(try await vault.names() == ["a.txt"])
    }

    @Test("A rerun that finds an incomplete indexed copy never leaves it visible and never loses the content")
    func rerunWithIncompleteIndexedCopy() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let copyName = VaultStoreFixture.newDiskName()
        let truncated = HeaderAwareTestCipher.sealed(Data("full content".utf8), truncatedBy: 1)
        try truncated.write(to: vault.rootURL.appendingPathComponent(copyName))
        try vault.writeIndex([copyName: "a.txt"], context: ".vault_map")
        try vault.diskFile("a.txt", "full content")
        let item = try #require(
            try await vault.store.itemsToMigrate(toEncrypted: true).first { $0.diskURL.lastPathComponent == "a.txt" })
        _ = await caught { try await vault.store.migrateToEncrypted(item) }

        #expect(vault.indexEntries()?[copyName] == nil)
        #expect(try await contents(of: nil, in: vault) == ["full content"])
    }

    @Test("A rerun with an indexed copy whose header size differs from the plaintext is not taken as identical")
    func rerunWithWrongHeaderSizeCopy() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let copyName = VaultStoreFixture.newDiskName()
        let wrongHeader = HeaderAwareTestCipher.sealed(Data("full content".utf8), declaredSize: 5)
        try wrongHeader.write(to: vault.rootURL.appendingPathComponent(copyName))
        try vault.writeIndex([copyName: "a.txt"], context: ".vault_map")
        let plaintext = try vault.diskFile("a.txt", "full content")
        let item = try #require(
            try await vault.store.itemsToMigrate(toEncrypted: true).first { $0.diskURL.lastPathComponent == "a.txt" })
        _ = await caught { try await vault.store.migrateToEncrypted(item) }

        // The plaintext must not be removed on the strength of the wrong-size copy.
        if FileManager.default.fileExists(atPath: plaintext.path) {
            #expect(try vault.content(plaintext) == "full content")
            let again = try #require(
                try await vault.store.itemsToMigrate(toEncrypted: true).first {
                    $0.diskURL.lastPathComponent == "a.txt"
                })
            try await vault.store.migrateToEncrypted(again)
        }

        #expect(!FileManager.default.fileExists(atPath: plaintext.path))
        #expect(try await vault.names() == ["a.txt"])
        #expect(try await contents(of: nil, in: vault) == ["full content"])
        #expect(vault.indexEntries()?[copyName] == nil)
        #expect(vault.indexEntries()?.values.filter { $0 == "a.txt" }.count == 1)
        #expect(try await vault.store.hasUnencryptedFiles() == false)
    }

    @Test("A key lost during the step throws locked, keeps the plaintext and writes no plaintext index")
    func keyLostDuringEncryptStep() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile("a.txt", "plain", in: docs)
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)
        let before = try vault.snapshot()
        vault.cipher.errorToThrow = .noKeyLoaded
        let error = await caught { try await vault.store.migrateToEncrypted(item) }

        #expect(error as? VaultStoreError == .locked)
        #expect(vault.rawIndex(in: docs) == nil)
        #expect(vault.indexIsPlaintextJSON(in: docs) == false)
        #expect(try vault.snapshot() == before)
    }

    @Test("A plaintext file named like an indexed UUID is still migrated, because it is not an SVC5 file")
    func plaintextFileNamedLikeIndexedUUID() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let uuidName = VaultStoreFixture.newDiskName()
        try vault.writeIndex([uuidName: "ghost.txt"], context: ".vault_map")
        try vault.diskFile(uuidName, "plain content")

        let pending = try await vault.store.itemsToMigrate(toEncrypted: true)
        let item = try #require(pending.first { $0.diskURL.lastPathComponent == uuidName })
        try await vault.store.migrateToEncrypted(item)

        #expect(try await vault.store.itemsToMigrate(toEncrypted: true).isEmpty)
        #expect(try await vault.store.hasUnencryptedFiles() == false)
        #expect(try await contents(of: nil, in: vault).contains("plain content"))
    }

    // MARK: - Decrypt rerun

    @Test("A decrypt rerun with the matching plaintext already present finishes without a duplicate")
    func decryptRerunWithMatchingPlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let existing = try await vault.add("a.txt", "same")
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: false).first)
        try vault.diskFile("a.txt", "same")
        try await vault.store.migrateToDecrypted(item)

        #expect(try vault.diskNames().filter { $0 != ".vault_map" } == ["a.txt"])
        #expect(try vault.content(vault.rootURL.appendingPathComponent("a.txt")) == "same")
        #expect(vault.indexEntries()?.isEmpty ?? true)
        #expect(!FileManager.default.fileExists(atPath: existing.diskURL.path))
        #expect(try await vault.store.itemsToMigrate(toEncrypted: false).isEmpty)
    }

    @Test("A decrypt rerun with different plaintext under the name keeps both, the decrypted one as ' 1'")
    func decryptRerunWithDifferentPlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "from the vault")
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: false).first)
        try vault.diskFile("a.txt", "someone else's")
        try await vault.store.migrateToDecrypted(item)
        #expect(try vault.content(vault.rootURL.appendingPathComponent("a.txt")) == "someone else's")
        #expect(try vault.content(vault.rootURL.appendingPathComponent("a 1.txt")) == "from the vault")
    }
}
