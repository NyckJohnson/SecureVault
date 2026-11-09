import Foundation
import Testing

@testable import KoalaTVault

/// Tests for `hasUnreadableTrash` and `clearUnreadableTrash` (unreadable trash: sealed with a key the vault no longer has).
@Suite struct VaultUnreadableTrashTests {
    // MARK: - Helpers

    private func makeVault(
        _ mode: LockMode = .password, keyLoaded: Bool = true, selective: Bool = false
    ) throws -> VaultStoreFixture {
        try VaultStoreFixture(lockMode: mode, keyLoaded: keyLoaded, headerAware: true, selective: selective)
    }

    /// Adds a file to the root and moves it to the trash; returns the trash item (found by name).
    @discardableResult
    private func trashFile(
        _ vault: VaultStoreFixture,
        _ name: String,
        _ content: String = "data"
    ) async throws -> VaultItem {
        let item = try await vault.add(name, content)
        try await vault.store.moveToTrash(item)
        let all = try await vault.store.trashContents()
        return try #require(all.first { $0.name == name })
    }

    /// Adds a folder holding one file to the root and moves the folder to the trash; returns the trashed folder.
    private func trashFolder(_ vault: VaultStoreFixture, _ name: String, file: String) async throws -> VaultItem {
        let folder = try await vault.store.createFolder(named: name, in: vault.root)
        let directory = try #require(folder.asDirectory)
        try await vault.add(file, "inner", to: directory)
        try await vault.store.moveToTrash(folder)
        let all = try await vault.store.trashContents()
        return try #require(all.first { $0.name == name })
    }

    /// Bytes that no key of this vault opens (any context).
    private static let foreignIndex = Data("foreign-sealed:.vault_map:{}".utf8)
    private static let foreignTrashIndex = Data("foreign-sealed:.trash_map:{}".utf8)

    /// Overwrites an SVC5 file so that its first chunk fails authentication (header intact, data not the key's).
    private func sealWithOtherKey(_ url: URL) throws {
        try HeaderAwareTestCipher.sealed(Data("zz".utf8), declaredSize: 4096).write(to: url)
    }

    private func innerFile(of folder: VaultItem) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.diskURL.path)
            .filter { !$0.hasPrefix(".") }
        return folder.diskURL.appendingPathComponent(try #require(names.first))
    }

    private func trashNames(_ vault: VaultStoreFixture) async throws -> [String] {
        try await vault.store.trashContents().map(\.name).sorted()
    }

    // MARK: - hasUnreadableTrash: true

    @Test("hasUnreadableTrash is true when the trash index is sealed with another key")
    func trueForForeignTrashIndex() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        try await vault.add("keep.txt")
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        #expect(await vault.store.hasUnreadableTrash())
    }

    @Test("hasUnreadableTrash is true when a top-level trash file is sealed with another key")
    func trueForForeignFile() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        try sealWithOtherKey(item.diskURL)
        #expect(await vault.store.hasUnreadableTrash())
    }

    @Test("hasUnreadableTrash is true when a trashed folder's index is sealed with another key")
    func trueForForeignFolderIndex() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let folder = try await trashFolder(vault, "Docs", file: "in.txt")
        try Self.foreignIndex.write(to: folder.diskURL.appendingPathComponent(".vault_map"))
        #expect(await vault.store.hasUnreadableTrash())
    }

    @Test("hasUnreadableTrash is true when an encrypted file inside a trashed folder is sealed with another key")
    func trueForForeignFileInFolder() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let folder = try await trashFolder(vault, "Docs", file: "in.txt")
        try sealWithOtherKey(try innerFile(of: folder))
        #expect(await vault.store.hasUnreadableTrash())
    }

    @Test("hasUnreadableTrash is true in password-and-biometrics mode too")
    func trueInBiometricMode() async throws {
        let vault = try makeVault(.passwordAndBiometrics)
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        try sealWithOtherKey(item.diskURL)
        #expect(await vault.store.hasUnreadableTrash())
    }

    // MARK: - hasUnreadableTrash: false

    @Test("hasUnreadableTrash is false when there is no trash")
    func falseWithoutTrash() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("hasUnreadableTrash is false for healthy encrypted trash, files and folders")
    func falseForHealthyTrash() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        _ = try await trashFolder(vault, "Docs", file: "in.txt")
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("hasUnreadableTrash is false for plaintext items in the trash, even with odd bytes")
    func falseForPlaintextItems() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        try Data("just plain text".utf8).write(to: item.diskURL)
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("hasUnreadableTrash is false in plaintext mode even with a foreign-sealed trash index")
    func falseInPlaintextMode() async throws {
        let vault = try makeVault(.none, keyLoaded: false)
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("hasUnreadableTrash is false in plaintext mode with a foreign-sealed file")
    func falseInPlaintextModeFile() async throws {
        let vault = try makeVault(.none, keyLoaded: false)
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        try sealWithOtherKey(item.diskURL)
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("hasUnreadableTrash is false when the key is not loaded")
    func falseWithoutKey() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        vault.keys.wipeKey()
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("hasUnreadableTrash is false when the key doesn't match the vault's root index")
    func falseWhenKeyDoesNotMatch() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        try await vault.add("keep.txt")
        try sealWithOtherKey(item.diskURL)
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        try vault.writeRawIndex(Self.foreignIndex)
        #expect(await vault.store.keyMatchesVault() == false)
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("hasUnreadableTrash is false when a trash file can't be read (permission error)")
    func falseForUnreadableFile() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        let restore = try restrict(item.diskURL, to: 0o000)
        defer { restore() }
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("hasUnreadableTrash is false when a file inside a trashed folder can't be read")
    func falseForUnreadableFileInFolder() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let folder = try await trashFolder(vault, "Docs", file: "in.txt")
        let restore = try restrict(try innerFile(of: folder), to: 0o000)
        defer { restore() }
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("hasUnreadableTrash is false when the trash index can't be read (permission error)")
    func falseForUnreadableTrashIndex() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        let restore = try restrict(vault.trashMapURL, to: 0o000)
        defer { restore() }
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test(
        "hasUnreadableTrash is false when the cipher fails with a read error rather than an authentication failure",
        arguments: [
            CocoaError(.fileReadNoPermission), CocoaError(.fileReadUnknown), CocoaError(.fileNoSuchFile),
        ])
    func falseForCipherReadError(error: CocoaError) async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        try sealWithOtherKey(item.diskURL)
        vault.failing?.decryptChunkError = error
        vault.failing?.streamInfoError = error
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("hasUnreadableTrash is false when the key vanishes mid-check (no key error from the cipher)")
    func falseWhenCipherLosesKey() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        try sealWithOtherKey(item.diskURL)
        vault.failing?.loseKeyForStreaming()
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    // MARK: - clearUnreadableTrash: kind (a)

    @Test("clearUnreadableTrash with a foreign trash index removes everything in .trash, the index included")
    func clearKindA() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        _ = try await trashFolder(vault, "Docs", file: "in.txt")
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        try await vault.store.clearUnreadableTrash()
        #expect(vault.trashDiskNames().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: vault.trashMapURL.path))
        #expect(await vault.store.hasUnreadableTrash() == false)
        #expect(try await vault.store.trashContents().isEmpty)
    }

    @Test("clearUnreadableTrash of kind (a) leaves the vault outside the trash untouched")
    func clearKindALeavesVault() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let keep = try await vault.add("keep.txt", "kept")
        _ = try await vault.store.createFolder(named: "Docs", in: vault.root)
        try await trashFile(vault, "a.txt")
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        let before = try vault.snapshot().filter { !$0.key.hasPrefix(vault.trashURL.path) }
        try await vault.store.clearUnreadableTrash()
        let after = try vault.snapshot().filter { !$0.key.hasPrefix(vault.trashURL.path) }
        #expect(before == after)
        #expect(try await vault.openedContent(keep) == "kept")
    }

    // MARK: - clearUnreadableTrash: kind (b)

    @Test("clearUnreadableTrash of kind (b) removes only the unreadable file and its entry")
    func clearKindBFile() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let bad = try await trashFile(vault, "bad.txt", "bad")
        try await trashFile(vault, "good.txt", "good")
        try sealWithOtherKey(bad.diskURL)
        try await vault.store.clearUnreadableTrash()

        #expect(!FileManager.default.fileExists(atPath: bad.diskURL.path))
        #expect(try await trashNames(vault) == ["good.txt"])
        #expect(vault.trashEntries()?.count == 1)
        #expect(await vault.store.hasUnreadableTrash() == false)
        let good = try #require(try await vault.store.trashContents().first)
        let restored = try await vault.store.restore(good)
        #expect(try await vault.openedContent(restored) == "good")
    }

    @Test("clearUnreadableTrash of kind (b) removes a folder with its whole tree and its entry")
    func clearKindBFolder() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let bad = try await trashFolder(vault, "Bad", file: "in.txt")
        try await trashFile(vault, "good.txt", "good")
        try sealWithOtherKey(try innerFile(of: bad))
        try await vault.store.clearUnreadableTrash()

        #expect(!FileManager.default.fileExists(atPath: bad.diskURL.path))
        #expect(try await trashNames(vault) == ["good.txt"])
        #expect(vault.trashEntries()?.count == 1)
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("clearUnreadableTrash removes a folder whose own index is sealed with another key and keeps a healthy folder")
    func clearKindBFolderIndex() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let bad = try await trashFolder(vault, "Bad", file: "in.txt")
        let good = try await trashFolder(vault, "Good", file: "ok.txt")
        try Self.foreignIndex.write(to: bad.diskURL.appendingPathComponent(".vault_map"))
        try await vault.store.clearUnreadableTrash()

        #expect(!FileManager.default.fileExists(atPath: bad.diskURL.path))
        #expect(FileManager.default.fileExists(atPath: good.diskURL.path))
        #expect(try await trashNames(vault) == ["Good"])
        let restored = try await vault.store.restore(try #require(try await vault.store.trashContents().first))
        #expect(restored.name == "Good")
        let restoredDirectory = try #require(restored.asDirectory)
        #expect(try await vault.names(restoredDirectory) == ["ok.txt"])
    }

    @Test("clearUnreadableTrash of kind (b) removes several unreadable items and keeps the rest readable")
    func clearKindBSeveral() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let bad1 = try await trashFile(vault, "bad1.txt")
        let bad2 = try await trashFile(vault, "bad2.txt")
        try await trashFile(vault, "good1.txt")
        try await trashFile(vault, "good2.txt")
        try sealWithOtherKey(bad1.diskURL)
        try sealWithOtherKey(bad2.diskURL)
        try await vault.store.clearUnreadableTrash()
        #expect(try await trashNames(vault) == ["good1.txt", "good2.txt"])
        #expect(vault.trashEntries()?.count == 2)
    }

    // MARK: - clearUnreadableTrash: no change, locked, re-check

    @Test("clearUnreadableTrash with nothing unreadable changes nothing, byte for byte")
    func clearNothingUnreadable() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        _ = try await trashFolder(vault, "Docs", file: "in.txt")
        let before = try vault.snapshot()
        try await vault.store.clearUnreadableTrash()
        #expect(try vault.snapshot() == before)
    }

    @Test("clearUnreadableTrash with no trash at all changes nothing and doesn't throw")
    func clearNoTrash() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        let before = try vault.snapshot()
        try await vault.store.clearUnreadableTrash()
        #expect(try vault.snapshot() == before)
    }

    @Test("clearUnreadableTrash in plaintext mode changes nothing even with a foreign-sealed trash index")
    func clearPlaintextMode() async throws {
        let vault = try makeVault(.none, keyLoaded: false)
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        let before = try vault.snapshot()
        try await vault.store.clearUnreadableTrash()
        #expect(try vault.snapshot() == before)
    }

    @Test("clearUnreadableTrash without a key throws locked and removes nothing")
    func clearLocked() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        try sealWithOtherKey(item.diskURL)
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        vault.keys.wipeKey()
        let before = try vault.snapshot()
        let error = await caught { try await vault.store.clearUnreadableTrash() }
        #expect(error as? VaultStoreError == .locked)
        #expect(try vault.snapshot() == before)
    }

    @Test("clearUnreadableTrash re-checks at call time: an item that was fixed is not removed")
    func clearRechecksFixedItem() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt", "data")
        let original = try Data(contentsOf: item.diskURL)
        try sealWithOtherKey(item.diskURL)
        #expect(await vault.store.hasUnreadableTrash())
        try original.write(to: item.diskURL)
        try await vault.store.clearUnreadableTrash()
        #expect(FileManager.default.fileExists(atPath: item.diskURL.path))
        #expect(try await trashNames(vault) == ["a.txt"])
    }

    @Test("clearUnreadableTrash re-checks at call time: an item that is now uncertain (unreadable) is not removed")
    func clearRechecksUncertainItem() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        try sealWithOtherKey(item.diskURL)
        let restore = try restrict(item.diskURL, to: 0o000)
        defer { restore() }
        try await vault.store.clearUnreadableTrash()
        #expect(FileManager.default.fileExists(atPath: item.diskURL.path))
        #expect(vault.trashEntries()?.count == 1)
    }

    @Test("clearUnreadableTrash re-checks at call time: a key that no longer matches the vault removes nothing")
    func clearRechecksKeyMismatch() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        try await vault.add("keep.txt")
        try sealWithOtherKey(item.diskURL)
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        try vault.writeRawIndex(Self.foreignIndex)
        let before = try vault.snapshot()
        try await vault.store.clearUnreadableTrash()
        #expect(try vault.snapshot() == before)
    }

    @Test("clearUnreadableTrash never removes files outside the trash, even if sealed with another key")
    func clearNeverTouchesOutsideTrash() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let outside = try await vault.add("outside.txt", "o")
        let docs = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let docsDirectory = try #require(docs.asDirectory)
        let inDocs = try await vault.add("deep.txt", "d", to: docsDirectory)
        let trashed = try await trashFile(vault, "bad.txt")
        try sealWithOtherKey(trashed.diskURL)
        try sealWithOtherKey(outside.diskURL)
        try sealWithOtherKey(inDocs.diskURL)
        let outsideBytes = try Data(contentsOf: outside.diskURL)
        let deepBytes = try Data(contentsOf: inDocs.diskURL)
        try await vault.store.clearUnreadableTrash()
        #expect(!FileManager.default.fileExists(atPath: trashed.diskURL.path))
        #expect(try Data(contentsOf: outside.diskURL) == outsideBytes)
        #expect(try Data(contentsOf: inDocs.diskURL) == deepBytes)
    }

    @Test("clearUnreadableTrash with a failing removal throws io after removing the rest")
    func clearRemovalFailureThrowsIO() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let stuck = try await trashFolder(vault, "Stuck", file: "in.txt")
        let other = try await trashFile(vault, "other.txt")
        try sealWithOtherKey(try innerFile(of: stuck))
        try sealWithOtherKey(other.diskURL)
        // A read-only trashed folder can't have its contents removed.
        let restore = try restrict(stuck.diskURL, to: 0o555)
        defer { restore() }
        let error = await caught { try await vault.store.clearUnreadableTrash() }
        #expect(isIOError(error))
        #expect(!FileManager.default.fileExists(atPath: other.diskURL.path))
    }

    // MARK: - Narrowed definition: uncertain index files

    private static let shortIndexes: [Data] = [
        Data(), Data("garbage".utf8), Data(repeating: 0x41, count: 27),
    ]

    @Test("An empty or too-short trash index is uncertain: not unreadable, and clearing removes nothing", arguments: shortIndexes)
    func shortTrashIndexIsUncertain(bytes: Data) async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        _ = try await trashFolder(vault, "Docs", file: "in.txt")
        try vault.writeRawTrashMap(bytes)
        let before = try vault.snapshot()
        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()
        #expect(try vault.snapshot() == before)
        #expect(try Data(contentsOf: vault.trashMapURL) == bytes)
    }

    @Test("A trashed folder whose index is empty or too short is not unreadable and is kept", arguments: shortIndexes)
    func shortFolderIndexIsUncertain(bytes: Data) async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let folder = try await trashFolder(vault, "Docs", file: "in.txt")
        try bytes.write(to: folder.diskURL.appendingPathComponent(".vault_map"))
        let before = try vault.snapshot()
        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()
        #expect(try vault.snapshot() == before)
        #expect(FileManager.default.fileExists(atPath: folder.diskURL.path))
    }

    // MARK: - Narrowed definition: .trash that is not a real folder

    @Test("A .trash that is a symlink to a folder with a foreign-sealed index is not unreadable and nothing is removed")
    func symlinkedTrashIsNeverCleared() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        let outside = vault.base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideIndex = outside.appendingPathComponent(".trash_map")
        let outsideFile = outside.appendingPathComponent("item.bin")
        try Self.foreignTrashIndex.write(to: outsideIndex)
        try Data("outside".utf8).write(to: outsideFile)
        try FileManager.default.removeItem(at: vault.trashURL)
        try FileManager.default.createSymbolicLink(at: vault.trashURL, withDestinationURL: outside)

        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()

        #expect(try Data(contentsOf: outsideIndex) == Self.foreignTrashIndex)
        #expect(try Data(contentsOf: outsideFile) == Data("outside".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted() == [".trash_map", "item.bin"])
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: vault.trashURL.path)
        #expect(destination != nil)
    }

    @Test("A .trash that is a regular file is not unreadable and nothing is removed")
    func fileInPlaceOfTrashIsNeverCleared() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await vault.add("keep.txt")
        let bytes = Self.foreignTrashIndex
        try bytes.write(to: vault.trashURL)
        let before = try vault.snapshot()
        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()
        #expect(try vault.snapshot() == before)
        #expect(try Data(contentsOf: vault.trashURL) == bytes)
    }

    // MARK: - Kind (b): the trash index is rewritten before anything is removed

    @Test("When the trash index can't be rewritten, clearing kind (b) throws and removes nothing")
    func indexWriteFailureRemovesNothing() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let bad = try await trashFile(vault, "bad.txt")
        let badFolder = try await trashFolder(vault, "Bad", file: "in.txt")
        try await trashFile(vault, "good.txt")
        try sealWithOtherKey(bad.diskURL)
        try sealWithOtherKey(try innerFile(of: badFolder))
        vault.failing?.encryptError = CocoaError(.fileWriteUnknown)
        vault.failing?.encryptFailureContexts = [".trash_map"]
        let before = try vault.snapshot()

        let error = await caught { try await vault.store.clearUnreadableTrash() }

        #expect(error != nil)
        #expect(try vault.snapshot() == before)
        #expect(FileManager.default.fileExists(atPath: bad.diskURL.path))
        #expect(FileManager.default.fileExists(atPath: badFolder.diskURL.path))
    }

    @Test("When the trash index can't be written because the key is gone at write time, nothing is removed")
    func indexWriteWithoutKeyRemovesNothing() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let bad = try await trashFile(vault, "bad.txt")
        try await trashFile(vault, "good.txt")
        try sealWithOtherKey(bad.diskURL)
        vault.failing?.encryptError = VaultCryptoError.noKeyLoaded
        vault.failing?.encryptFailureContexts = [".trash_map"]
        let before = try vault.snapshot()

        let error = await caught { try await vault.store.clearUnreadableTrash() }

        #expect(error != nil)
        #expect(try vault.snapshot() == before)
    }

    // MARK: - Judging uses the store's own bytes

    @Test("The cipher is never asked to read a trash item itself when judging it")
    func cipherNeverReadsTrashItems() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let healthy = try await trashFile(vault, "ok.txt", "fine")
        let bad = try await trashFile(vault, "bad.txt")
        let folder = try await trashFolder(vault, "Docs", file: "in.txt")
        try sealWithOtherKey(bad.diskURL)
        let inner = try innerFile(of: folder)

        #expect(await vault.store.hasUnreadableTrash())
        try await vault.store.clearUnreadableTrash()

        let failing = try #require(vault.failing)
        let touched = (failing.streamInfoURLs + failing.decryptChunkCalls.map(\.url)).map(\.standardizedFileURL.path)
        let forbidden = [healthy.diskURL, bad.diskURL, inner].map(\.standardizedFileURL.path)
        for path in forbidden { #expect(!touched.contains(path)) }
    }

    @Test("A healthy multi-chunk trash file is judged on its first chunk only")
    func largeHealthyFileJudgedOnFirstChunk() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let content = String(repeating: "a", count: MockFileCipher.chunkSize * 3 + 5)
        let item = try await trashFile(vault, "big.bin", content)
        #expect(try Data(contentsOf: item.diskURL).count > MockFileCipher.chunkSize * 3)

        #expect(await vault.store.hasUnreadableTrash() == false)

        let calls = try #require(vault.failing).decryptChunkCalls
        #expect(calls.allSatisfy { $0.index == 0 })
    }

    @Test("A multi-chunk trash file with a bad first chunk is unreadable, judged on the first chunk only")
    func largeBadFileJudgedOnFirstChunk() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "big.bin", "x")
        let size = MockFileCipher.chunkSize * 3
        try HeaderAwareTestCipher.sealed(Data("zz".utf8), declaredSize: size).write(to: item.diskURL)

        #expect(await vault.store.hasUnreadableTrash())

        let calls = try #require(vault.failing).decryptChunkCalls
        #expect(calls.allSatisfy { $0.index == 0 })
    }
}
