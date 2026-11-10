import Foundation
import Testing

@testable import KoalaTVault

/// Failure paths of the per-file migration steps and the finish steps: each ends with an error (or a repair) and
/// nothing lost or changed.
@Suite struct VaultMigrationFailureTests {
    // MARK: - Helpers

    private func pending(_ vault: VaultStoreFixture, toEncrypted: Bool, diskName: String) async throws -> VaultItem {
        let items = try await vault.store.itemsToMigrate(toEncrypted: toEncrypted)
        return try #require(items.first { $0.diskURL.lastPathComponent == diskName })
    }

    private func trashedItem(_ vault: VaultStoreFixture, toEncrypted: Bool) async throws -> VaultItem {
        let items = try await vault.store.itemsToMigrate(toEncrypted: toEncrypted)
        return try #require(items.first { $0.id.hasPrefix(".trash/") })
    }

    private func firstEncrypted(_ vault: VaultStoreFixture) async throws -> VaultItem {
        try #require(try await vault.store.itemsToMigrate(toEncrypted: false).first)
    }

    private func listedContents(_ vault: VaultStoreFixture) async throws -> [String] {
        try await vault.list().asyncMap { try await vault.openedContent($0) }
    }

    /// Every file in the vault and temp folders (empty folders such as the temp parent are not state).
    private func files(_ vault: VaultStoreFixture) throws -> [String: Data] {
        try vault.snapshot().filter { $0.value != Data("<dir>".utf8) }
    }

    private func isLocked(_ error: (any Error)?) -> Bool { error as? VaultStoreError == .locked }

    private func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A trash item that is plaintext on disk, with the vault now in password mode.
    private func plaintextTrashVault() async throws -> (VaultStoreFixture, VaultItem) {
        let vault = try VaultStoreFixture(lockMode: .none, headerAware: true, selective: true)
        let source = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(source)
        vault.prefs.lockMode = .password
        return (vault, try await trashedItem(vault, toEncrypted: true))
    }

    /// A trash item that is encrypted on disk, in password mode.
    private func encryptedTrashVault() async throws -> (VaultStoreFixture, VaultItem) {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        let source = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(source)
        return (vault, try await trashedItem(vault, toEncrypted: false))
    }

    // MARK: - Key lost mid-check

    @Test("A key lost while checking an indexed file's form throws locked and changes nothing")
    func keyLostReadingFileForm() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let uuidName = VaultStoreFixture.newDiskName()
        try vault.writeIndex([uuidName: "ghost.txt"], context: ".vault_map")
        try vault.diskFile(uuidName, "plain content")
        let item = try await pending(vault, toEncrypted: true, diskName: uuidName)
        let before = try files(vault)
        vault.failing?.streamInfoError = VaultCryptoError.noKeyLoaded

        let error = await caught { try await vault.store.migrateToEncrypted(item) }
        #expect(isLocked(error))
        #expect(try files(vault) == before)
    }

    @Test("A non-SVC5 file under an indexed same-name entry is an incomplete copy: dropped, plaintext encrypted fresh")
    func nonSealedFileUnderSameNameEntryIsDropped() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let junkName = VaultStoreFixture.newDiskName()
        try vault.diskFile(junkName, "not an encrypted file")
        try vault.writeIndex([junkName: "a.txt"], context: ".vault_map")
        let plaintext = try vault.diskFile("a.txt", "plain")
        let item = try await pending(vault, toEncrypted: true, diskName: "a.txt")

        try await vault.store.migrateToEncrypted(item)

        #expect(!fileExists(plaintext))
        #expect(!fileExists(vault.rootURL.appendingPathComponent(junkName)))
        let entries = try #require(vault.indexEntries())
        #expect(entries.count == 1)
        #expect(entries.values.first == "a.txt")
        #expect(entries[junkName] == nil)
        #expect(try await vault.names() == ["a.txt"])
        #expect(try await listedContents(vault) == ["plain"])
        #expect(try await vault.store.hasUnencryptedFiles() == false)
    }

    // MARK: - migrateToEncrypted

    @Test(
        "An incomplete same-name copy is dropped even beside an identical complete copy, in either order",
        arguments: [true, false])
    func incompleteCopyDroppedBesideIdenticalCopy(incompleteSortsFirst: Bool) async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let lowName = "00000000-0000-0000-0000-000000000001"
        let highName = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        let completeName = incompleteSortsFirst ? highName : lowName
        let incompleteName = incompleteSortsFirst ? lowName : highName
        try vault.diskSealedFile(completeName, "full content")
        try HeaderAwareTestCipher.sealed(Data("full content".utf8), truncatedBy: 1)
            .write(to: vault.rootURL.appendingPathComponent(incompleteName))
        try vault.writeIndex([completeName: "a.txt", incompleteName: "a.txt"], context: ".vault_map")
        let plaintext = try vault.diskFile("a.txt", "full content")
        let item = try await pending(vault, toEncrypted: true, diskName: "a.txt")

        try await vault.store.migrateToEncrypted(item)

        #expect(vault.indexEntries() == [completeName: "a.txt"])
        #expect(!fileExists(vault.rootURL.appendingPathComponent(incompleteName)))
        #expect(!fileExists(plaintext))
        #expect(try vault.diskNames().filter { $0 != ".vault_map" } == [completeName])
        #expect(try await vault.names() == ["a.txt"])
        #expect(try await listedContents(vault) == ["full content"])
    }

    @Test("An index entry that is not on disk after the write throws io and keeps the plaintext")
    func entryMissingAfterIndexWrite() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let plaintext = try vault.diskFile("a.txt", "keep me")
        let item = try await pending(vault, toEncrypted: true, diskName: "a.txt")
        vault.failing?.encryptSealsEmptyObject = true

        let error = await caught { try await vault.store.migrateToEncrypted(item) }
        #expect(isIOError(error))
        #expect(try vault.content(plaintext) == "keep me")
        #expect(try await vault.store.hasUnencryptedFiles())
    }

    @Test("A key lost while verifying the new encrypted copy throws locked and keeps the plaintext")
    func keyLostVerifyingNewCopy() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        try vault.diskFile("a.txt", "keep me")
        let item = try await pending(vault, toEncrypted: true, diskName: "a.txt")
        let before = try files(vault)
        vault.failing?.decryptChunkError = VaultCryptoError.noKeyLoaded

        let error = await caught { try await vault.store.migrateToEncrypted(item) }
        #expect(isLocked(error))
        #expect(try files(vault) == before)
    }

    @Test("A key lost while checking an indexed same-name copy's completeness throws locked and changes nothing")
    func keyLostCheckingCompleteness() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let copyName = VaultStoreFixture.newDiskName()
        try vault.diskSealedFile(copyName, "same")
        try vault.writeIndex([copyName: "a.txt"], context: ".vault_map")
        try vault.diskFile("a.txt", "same")
        let item = try await pending(vault, toEncrypted: true, diskName: "a.txt")
        let before = try files(vault)
        vault.failing?.decryptChunkError = VaultCryptoError.noKeyLoaded

        let error = await caught { try await vault.store.migrateToEncrypted(item) }
        #expect(isLocked(error))
        #expect(try files(vault) == before)
    }

    @Test("A key lost while reading an indexed same-name copy's header throws locked and changes nothing")
    func keyLostReadingCopyHeader() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let copyName = VaultStoreFixture.newDiskName()
        try vault.diskSealedFile(copyName, "same")
        try vault.writeIndex([copyName: "a.txt"], context: ".vault_map")
        try vault.diskFile("a.txt", "same")
        let item = try await pending(vault, toEncrypted: true, diskName: "a.txt")
        let before = try files(vault)
        vault.failing?.loseKeyForStreaming()

        let error = await caught { try await vault.store.migrateToEncrypted(item) }
        #expect(isLocked(error))
        #expect(try files(vault) == before)
    }

    // MARK: - migrateToDecrypted

    @Test("A decrypt failure throws and keeps the encrypted file, its entry and every other file")
    func decryptFailureKeepsEverything() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "keep me")
        let item = try await firstEncrypted(vault)
        let before = try files(vault)
        vault.failing?.decryptFileError = VaultCryptoError.decryptionFailed

        let error = await caught { try await vault.store.migrateToDecrypted(item) }
        #expect(error != nil)
        #expect(try files(vault) == before)
        vault.failing?.decryptFileError = nil
        #expect(try await listedContents(vault) == ["keep me"])
    }

    @Test("A plaintext that can't be placed (folder read-only) throws io and keeps the encrypted file and entry")
    func plaintextCannotBePlaced() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try await vault.add("a.txt", "keep me", to: docs)
        let item = try await firstEncrypted(vault)
        let before = try files(vault)
        let restore = try restrict(docs.diskURL)
        defer { restore() }

        let error = await caught { try await vault.store.migrateToDecrypted(item) }
        restore()
        #expect(isIOError(error))
        #expect(try files(vault) == before)
        #expect(vault.indexEntries(in: docs)?.count == 1)
        #expect(try await vault.names(docs) == ["a.txt"])
    }

    @Test("A failed index write after decrypting removes the new plaintext and restores the earlier state")
    func indexWriteFailureAfterDecrypt() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "keep me")
        let item = try await firstEncrypted(vault)
        let before = try files(vault)
        vault.failing?.encryptFailureContexts = [".vault_map"]
        vault.failing?.encryptError = VaultCryptoError.encryptionFailed

        let error = await caught { try await vault.store.migrateToDecrypted(item) }
        #expect(error != nil)
        #expect(!fileExists(vault.rootURL.appendingPathComponent("a.txt")))
        #expect(try files(vault) == before)
        vault.failing?.encryptError = nil
        #expect(try await listedContents(vault) == ["keep me"])
    }

    @Test("A same-name plaintext that can't be read throws io and changes nothing")
    func unreadableSameNamePlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "encrypted version")
        let item = try await firstEncrypted(vault)
        let sameName = try vault.diskFile("a.txt", "plaintext version")
        let before = try files(vault)
        let restore = try restrict(sameName, to: 0o000)
        defer { restore() }

        let error = await caught { try await vault.store.migrateToDecrypted(item) }
        restore()
        #expect(isIOError(error))
        #expect(try files(vault) == before)
    }

    @Test("itemsToMigrate throws io, never taking an unreadable indexed file for plaintext, and changes nothing")
    func unreadableIndexedFileIsNeverPlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "secret")
        let diskName = try #require(try vault.diskNames().first { $0 != ".vault_map" })
        let fileURL = vault.rootURL.appendingPathComponent(diskName)
        let before = try files(vault)
        vault.failing?.streamInfoError = VaultCryptoError.decryptionFailed
        let restore = try restrict(fileURL, to: 0o000)
        defer { restore() }

        let error = await caught { _ = try await vault.store.itemsToMigrate(toEncrypted: false) }
        restore()
        #expect(isIOError(error))
        #expect(try files(vault) == before)
    }

    @Test("A key lost while comparing with a same-name plaintext throws locked and changes nothing")
    func keyLostComparingForDecrypt() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "same")
        try vault.diskFile("a.txt", "same")
        let item = try await firstEncrypted(vault)
        let before = try files(vault)
        vault.failing?.decryptChunkError = VaultCryptoError.noKeyLoaded

        let error = await caught { try await vault.store.migrateToDecrypted(item) }
        #expect(isLocked(error))
        #expect(try files(vault) == before)
    }

    // MARK: - Trash items

    @Test(
        "A trash item whose new encrypted copy doesn't verify throws and leaves the item, entry and no staging file",
        arguments: [true, false])
    func trashItemCopyDoesNotVerify(truncated: Bool) async throws {
        let (vault, item) = try await plaintextTrashVault()
        defer { vault.cleanUp() }
        let before = try files(vault)
        if truncated {
            vault.headerCipher?.truncatesNewCopies = true
        } else {
            vault.failing?.encryptFileError = VaultCryptoError.encryptionFailed
        }

        let error = await caught { try await vault.store.migrateToEncrypted(item) }
        #expect(error != nil)
        #expect(try files(vault) == before)
        #expect(vault.trashEntries()?.values.first?["isEncrypted"] as? Bool == false)
        #expect(try await vault.store.trashContents().map(\.name) == ["old.txt"])
    }

    @Test("Decrypting a trash item whose decrypt fails throws and leaves the item, entry and no staging file")
    func trashItemDecryptFails() async throws {
        let (vault, item) = try await encryptedTrashVault()
        defer { vault.cleanUp() }
        let before = try files(vault)
        vault.failing?.decryptFileError = VaultCryptoError.decryptionFailed

        let error = await caught { try await vault.store.migrateToDecrypted(item) }
        #expect(error != nil)
        #expect(try files(vault) == before)
        #expect(vault.trashEntries()?.values.first?["isEncrypted"] as? Bool == true)
    }

    @Test("Either migration step on a trash item with no trash entry throws notFound and changes nothing")
    func stepOnGhostTrashItem() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let real = try await vault.add("real.txt", "real")
        try await vault.store.moveToTrash(real)
        let ghost = vault.ghostTrashItem()
        let before = try files(vault)

        let toEncrypted = await caught { try await vault.store.migrateToEncrypted(ghost) }
        let toDecrypted = await caught { try await vault.store.migrateToDecrypted(ghost) }
        #expect(toEncrypted as? VaultStoreError == .notFound)
        #expect(toDecrypted as? VaultStoreError == .notFound)
        #expect(try files(vault) == before)
    }

    @Test("A sealed trash item whose entry says plaintext gets its entry corrected and its bytes left alone")
    func sealedTrashItemWithPlaintextFlag() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let source = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(source)
        try vault.rewriteTrashEntries { $0["isEncrypted"] = false }
        let item = try #require(try await vault.store.trashContents().first)
        let fileURL = vault.trashURL.appendingPathComponent((item.id as NSString).lastPathComponent)
        let bytes = try Data(contentsOf: fileURL)

        try await vault.store.migrateToEncrypted(item)

        #expect(vault.trashEntries()?.values.first?["isEncrypted"] as? Bool == true)
        #expect(try Data(contentsOf: fileURL) == bytes)
        #expect(vault.trashDiskNames().filter { $0.hasSuffix(".migrating") }.isEmpty)
    }

    @Test("A plaintext trash item whose entry says encrypted gets its entry corrected and its bytes left alone")
    func plaintextTrashItemWithEncryptedFlag() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let source = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(source)
        vault.prefs.lockMode = .password
        try vault.rewriteTrashEntries { $0["isEncrypted"] = true }
        let item = try #require(try await vault.store.trashContents().first)
        let fileURL = vault.trashURL.appendingPathComponent((item.id as NSString).lastPathComponent)
        let bytes = try Data(contentsOf: fileURL)

        try await vault.store.migrateToDecrypted(item)

        #expect(vault.trashEntries()?.values.first?["isEncrypted"] as? Bool == false)
        #expect(try Data(contentsOf: fileURL) == bytes)
        #expect(vault.trashDiskNames().filter { $0.hasSuffix(".migrating") }.isEmpty)
    }

    @Test(
        "A trash-map write failure during in-place conversion removes the staging file and leaves item and entry",
        arguments: [true, false])
    func trashMapWriteFailure(toEncrypted: Bool) async throws {
        let (vault, item) = toEncrypted ? try await plaintextTrashVault() : try await encryptedTrashVault()
        defer { vault.cleanUp() }
        let before = try files(vault)
        vault.failing?.encryptFailureContexts = [".trash_map"]
        vault.failing?.encryptError = VaultCryptoError.encryptionFailed

        let error = await caught {
            if toEncrypted {
                try await vault.store.migrateToEncrypted(item)
            } else {
                try await vault.store.migrateToDecrypted(item)
            }
        }
        #expect(error != nil)
        #expect(vault.trashDiskNames().filter { $0.hasSuffix(".migrating") }.isEmpty)
        #expect(try files(vault) == before)
        #expect(vault.trashEntries()?.values.first?["isEncrypted"] as? Bool == !toEncrypted)
    }

    // MARK: - Finish steps

    @Test("finishEncryption with a subfolder that can't be listed throws io and leaves its plaintext index alone")
    func finishEncryptionUnlistableSubfolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let locked = try vault.folder("Locked")
        try vault.writeIndex([VaultStoreFixture.newDiskName(): "x.txt"], in: locked, context: nil)
        let indexBefore = try #require(vault.rawIndex(in: locked))
        let restore = try restrict(locked.diskURL, to: 0o000)
        defer { restore() }

        let error = await caught { try await vault.store.finishEncryption() }
        restore()
        #expect(isIOError(error))
        #expect(vault.rawIndex(in: locked) == indexBefore)
        #expect(vault.indexIsPlaintextJSON(in: locked))
    }

    @Test("finishDecryption throws io when a .vault_map can't be deleted")
    func finishDecryptionCannotDeleteIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        try vault.writeIndex([:], context: ".vault_map")
        let restore = try restrict(vault.rootURL)
        defer { restore() }

        let error = await caught { try await vault.store.finishDecryption() }
        restore()
        #expect(isIOError(error))
        #expect(vault.rawIndex() != nil)
    }
}
