import Foundation
import Testing

@testable import KoalaTVault

/// `moveToTrash(_ items:)`: many items into the trash in one serialized step (feature multiple-vaults-duress-password,
/// large trash, device retest 2026-11-13). Each item is trashed exactly as the single call does it; the trash index and
/// each source folder's index are written once per call.
@Suite struct VaultTrashBatchTests {
    // MARK: - Helpers

    private struct Setup {
        let vault: VaultStoreFixture
        let docs: VaultDirectory
        let rootFile: VaultItem
        let docsFile: VaultItem
        let docsSecond: VaultItem
        let folder: VaultItem
        var all: [VaultItem] { [rootFile, docsFile, docsSecond, folder] }
    }

    /// A vault with two files in `Docs`, one at the root and a root folder `Sub` holding a file.
    private func makeSetup(_ mode: LockMode, selective: Bool = false) async throws -> Setup {
        let vault = try VaultStoreFixture(lockMode: mode, selective: selective)
        let docs = try vault.folder("Docs")
        let rootFile = try await vault.add("a.pdf", "aaa")
        let docsFile = try await vault.add("b.txt", "bbb", to: docs)
        let docsSecond = try await vault.add("c.jpg", "ccc", to: docs)
        let sub = try await vault.store.createFolder(named: "Sub", in: vault.root)
        let subDirectory = try #require(sub.asDirectory)
        try await vault.add("inner.txt", "inner", to: subDirectory)
        return Setup(
            vault: vault, docs: docs, rootFile: rootFile, docsFile: docsFile, docsSecond: docsSecond, folder: sub)
    }

    /// Per original name: the entry's folder and encryption flag.
    private func normalizedEntries(_ vault: VaultStoreFixture) throws -> [String: [String]] {
        let entries = try #require(vault.trashEntries())
        var result: [String: [String]] = [:]
        for entry in entries.values {
            let name = try #require(entry["originalName"] as? String)
            let folder = entry["originalDirectoryURL"] as? String ?? "<none>"
            let encrypted = (entry["isEncrypted"] as? Bool).map(String.init) ?? "<none>"
            result[name] = [folder, encrypted]
        }
        return result
    }

    private func count(_ vault: VaultStoreFixture, since start: Int, _ call: MockFileCipher.Call) -> Int {
        vault.cipher.calls.dropFirst(start).filter { $0 == call }.count
    }

    private func decrypts(_ vault: VaultStoreFixture, since start: Int) -> Int {
        vault.cipher.calls.dropFirst(start).filter {
            if case .decrypt = $0 { return true }
            return false
        }.count
    }

    private func ghostFile(in vault: VaultStoreFixture) -> VaultItem {
        let name = VaultStoreFixture.newDiskName()
        return VaultItem(
            id: name, name: "ghost.txt", isDirectory: false, dateModified: Date(), fileSize: 1, deletedAt: nil,
            diskURL: vault.rootURL.appendingPathComponent(name), rootURL: vault.rootURL,
            isEncrypted: vault.encrypted)
    }

    // MARK: - Same result as the single call

    @Test(
        "moveToTrash of many items records the same entries as one call per item",
        arguments: [LockMode.none, .password])
    func batchEntriesMatchSingleCalls(mode: LockMode) async throws {
        let batch = try await makeSetup(mode)
        defer { batch.vault.cleanUp() }
        let single = try await makeSetup(mode)
        defer { single.vault.cleanUp() }
        let before = Date()

        let failures = await batch.vault.store.moveToTrash(batch.all)
        for item in single.all { try await single.vault.store.moveToTrash(item) }

        #expect(failures.isEmpty)
        let batchEntries = try normalizedEntries(batch.vault)
        #expect(batchEntries.count == 4)
        #expect(batchEntries == (try normalizedEntries(single.vault)))
        #expect(Set(batchEntries.keys) == ["a.pdf", "b.txt", "c.jpg", "Sub"])
        let entries = try #require(batch.vault.trashEntries())
        for item in batch.all {
            let entry = try #require(entries.values.first { $0["originalName"] as? String == item.name })
            #expect(entry["originalDiskName"] as? String == (item.id as NSString).lastPathComponent)
            #expect(entry["deletedAt"] != nil)
            let folder = try #require(entry["originalDirectoryURL"] as? String)
            #expect(!folder.hasPrefix("/"))
        }
        // A folder is never encrypted in place, whatever the vault's mode.
        #expect(batchEntries["Sub"]?.last == "false")
        for name in ["a.pdf", "b.txt", "c.jpg"] { #expect(batchEntries[name]?.last == String(mode != .none)) }

        let trashed = try await batch.vault.store.trashContents()
        #expect(Set(trashed.map(\.name)) == ["a.pdf", "b.txt", "c.jpg", "Sub"])
        #expect(trashed.first { $0.name == "Sub" }?.isDirectory == true)
        #expect(trashed.filter { $0.name != "Sub" }.allSatisfy { !$0.isDirectory })
        for item in trashed {
            let deletedAt = try #require(item.deletedAt)
            #expect(abs(deletedAt.timeIntervalSince(before)) < 60)
        }
        let diskNames = batch.vault.trashDiskNames().filter { !$0.hasPrefix(".") }
        #expect(diskNames.count == 4)
        #expect(diskNames.allSatisfy { UUID(uuidString: $0) != nil })
        let subTrash = try #require(trashed.first { $0.name == "Sub" })
        let inside = try FileManager.default.contentsOfDirectory(atPath: subTrash.diskURL.path)
        #expect(inside.contains { !$0.hasPrefix(".") })
    }

    @Test("moveToTrash of many items removes them from their folders", arguments: [LockMode.none, .password])
    func batchRemovesItemsFromFolders(mode: LockMode) async throws {
        let setup = try await makeSetup(mode)
        defer { setup.vault.cleanUp() }
        let kept = try await setup.vault.add("kept.txt", "kept", to: setup.docs)

        let failures = await setup.vault.store.moveToTrash(setup.all)

        #expect(failures.isEmpty)
        #expect(try await setup.vault.names() == ["Docs"])
        #expect(try await setup.vault.names(setup.docs) == ["kept.txt"])
        #expect(try await setup.vault.openedContent(kept) == "kept")
        if mode != .none {
            #expect((setup.vault.indexEntries() ?? [:]).isEmpty)
            #expect(setup.vault.indexEntries(in: setup.docs)?.values.sorted() == ["kept.txt"])
        }
    }

    @Test(
        "A file trashed in a batch can be restored with its content",
        arguments: [LockMode.none, .password])
    func batchTrashedFileRestores(mode: LockMode) async throws {
        let setup = try await makeSetup(mode)
        defer { setup.vault.cleanUp() }
        _ = await setup.vault.store.moveToTrash(setup.all)
        let trashed = try #require(try await setup.vault.store.trashContents().first { $0.name == "b.txt" })

        let restored = try await setup.vault.store.restore(trashed)

        #expect(restored.name == "b.txt")
        #expect(restored.id.hasPrefix("Docs/"))
        #expect(try await setup.vault.openedContent(restored) == "bbb")
        #expect(try await setup.vault.names(setup.docs) == ["b.txt"])
    }

    @Test("moveToTrash of many items keeps the entries already in the trash")
    func batchKeepsEarlierEntries() async throws {
        let setup = try await makeSetup(.password)
        defer { setup.vault.cleanUp() }
        let older = try await setup.vault.add("older.txt", "older")
        try await setup.vault.store.moveToTrash(older)

        let failures = await setup.vault.store.moveToTrash(setup.all)

        #expect(failures.isEmpty)
        #expect(setup.vault.trashEntries()?.count == 5)
        #expect(try await setup.vault.store.trashContents().count == 5)
    }

    // MARK: - Writes once per call

    @Test("moveToTrash of many items writes the trash index once and each source folder's index once")
    func batchWritesIndexesOnce() async throws {
        let setup = try await makeSetup(.password)
        defer { setup.vault.cleanUp() }
        let start = setup.vault.cipher.calls.count

        let failures = await setup.vault.store.moveToTrash(setup.all)

        #expect(failures.isEmpty)
        #expect(count(setup.vault, since: start, .encrypt(context: ".trash_map")) == 1)
        // Two source folders: the root and Docs.
        #expect(count(setup.vault, since: start, .encrypt(context: ".vault_map")) == 2)
        // Each index is read at most once: the trash index and the two folder indexes.
        #expect(decrypts(setup.vault, since: start) <= 3)
    }

    @Test("moveToTrash of many items from one folder writes that folder's index once")
    func batchWritesOneFolderIndexOnce() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        var items: [VaultItem] = []
        for index in 0..<8 { items.append(try await vault.add("file\(index).txt", "c\(index)")) }
        let start = vault.cipher.calls.count

        let failures = await vault.store.moveToTrash(items)

        #expect(failures.isEmpty)
        #expect(count(vault, since: start, .encrypt(context: ".trash_map")) == 1)
        #expect(count(vault, since: start, .encrypt(context: ".vault_map")) == 1)
        #expect(vault.trashEntries()?.count == 8)
        #expect((vault.indexEntries() ?? [:]).isEmpty)
    }

    // MARK: - Per-item failures

    @Test(
        "An unknown item gets notFound under its id while the others are trashed",
        arguments: [LockMode.none, .password])
    func unknownItemIsNotFound(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let first = try await vault.add("first.txt", "1")
        let second = try await vault.add("second.txt", "2")
        let ghost = ghostFile(in: vault)

        let failures = await vault.store.moveToTrash([first, ghost, second])

        #expect(failures == [ghost.id: .notFound])
        #expect(try await vault.names().isEmpty)
        #expect(try await vault.store.trashContents().map(\.name).sorted() == ["first.txt", "second.txt"])
        #expect(vault.trashEntries()?.count == 2)
    }

    @Test(
        "An item whose move fails gets io under its id, stays listed where it was and leaves no trash entry",
        arguments: [LockMode.none, .password])
    func moveFailureIsIOAndLeavesItemInPlace(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let stuck = try await vault.add("stuck.txt", "stuck", to: docs)
        let fine = try await vault.add("fine.txt", "fine")
        let docsIndexBefore = vault.rawIndex(in: docs)
        let restore = try restrict(docs.diskURL)
        defer { restore() }

        let failures = await vault.store.moveToTrash([stuck, fine])

        restore()
        #expect(failures.keys.sorted() == [stuck.id])
        #expect(isIOError(failures[stuck.id]), "expected io, got \(String(describing: failures[stuck.id]))")
        #expect(try await vault.names(docs) == ["stuck.txt"])
        #expect(try await vault.openedContent(stuck) == "stuck")
        #expect(vault.rawIndex(in: docs) == docsIndexBefore)
        #expect(try await vault.names() == ["Docs"])
        #expect(try await vault.store.trashContents().map(\.name) == ["fine.txt"])
        let entries = try #require(vault.trashEntries())
        #expect(entries.count == 1)
        #expect(entries.values.first?["originalName"] as? String == "fine.txt")
        #expect(vault.trashDiskNames().filter { !$0.hasPrefix(".") }.count == 1)
    }

    @Test("Several failing items each get their own error and every other item is trashed")
    func mixedFailures() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let stuck = try await vault.add("stuck.txt", "stuck", to: docs)
        let one = try await vault.add("one.txt", "1")
        let two = try await vault.add("two.txt", "2")
        let ghost = ghostFile(in: vault)
        let restore = try restrict(docs.diskURL)
        defer { restore() }

        let failures = await vault.store.moveToTrash([one, stuck, ghost, two])

        restore()
        #expect(Set(failures.keys) == [stuck.id, ghost.id])
        #expect(failures[ghost.id] == .notFound)
        #expect(isIOError(failures[stuck.id]))
        #expect(try await vault.store.trashContents().map(\.name).sorted() == ["one.txt", "two.txt"])
        #expect(try await vault.names(docs) == ["stuck.txt"])
        #expect(vault.trashEntries()?.count == 2)
        #expect(vault.indexEntries()?.isEmpty ?? true)
    }

    // MARK: - Whole-call failures

    @Test(
        "A trash-index write failure gives every item that error and moves nothing",
        arguments: VaultFileOperationsFailureTests.SealFailure.allCases)
    func trashIndexWriteFailure(failure: VaultFileOperationsFailureTests.SealFailure) async throws {
        let setup = try await makeSetup(.password, selective: true)
        defer { setup.vault.cleanUp() }
        let older = try await setup.vault.add("older.txt", "older")
        try await setup.vault.store.moveToTrash(older)
        let before = try setup.vault.snapshot()
        let failing = try #require(setup.vault.failing)
        failing.encryptFailureContexts = [".trash_map"]
        failing.encryptError = failure.cryptoError

        let failures = await setup.vault.store.moveToTrash(setup.all)

        #expect(Set(failures.keys) == Set(setup.all.map(\.id)))
        for item in setup.all { #expect(failure.matches(failures[item.id]), "item \(item.name)") }
        #expect(try setup.vault.snapshot() == before)
        failing.encryptError = nil
        #expect(try await setup.vault.names().sorted() == ["a.pdf", "Docs", "Sub"].sorted())
        #expect(try await setup.vault.names(setup.docs) == ["b.txt", "c.jpg"])
        #expect(try await setup.vault.store.trashContents().map(\.name) == ["older.txt"])
    }

    @Test("In a plaintext vault a trash-index write failure gives every item io and moves nothing")
    func plaintextTrashIndexWriteFailure() async throws {
        let setup = try await makeSetup(.none)
        defer { setup.vault.cleanUp() }
        let older = try await setup.vault.add("older.txt", "older")
        try await setup.vault.store.moveToTrash(older)
        let before = try setup.vault.snapshot()
        let restore = try restrict(setup.vault.trashURL)
        defer { restore() }

        let failures = await setup.vault.store.moveToTrash(setup.all)

        restore()
        #expect(Set(failures.keys) == Set(setup.all.map(\.id)))
        for item in setup.all { #expect(isIOError(failures[item.id]), "item \(item.name)") }
        #expect(try setup.vault.snapshot() == before)
        #expect(try await setup.vault.names(setup.docs) == ["b.txt", "c.jpg"])
    }

    @Test("With the key missing every item gets locked and nothing changes")
    func keyMissingLocksEveryItem() async throws {
        let setup = try await makeSetup(.password)
        defer { setup.vault.cleanUp() }
        let older = try await setup.vault.add("older.txt", "older")
        try await setup.vault.store.moveToTrash(older)
        setup.vault.keys.wipeKey()
        let before = try setup.vault.snapshot()

        let failures = await setup.vault.store.moveToTrash(setup.all)

        #expect(Set(failures.keys) == Set(setup.all.map(\.id)))
        #expect(failures.values.allSatisfy { $0 == .locked })
        #expect(try setup.vault.snapshot() == before)
    }

    // MARK: - Empty list

    @Test(
        "moveToTrash of an empty list returns an empty result and writes nothing",
        arguments: [LockMode.none, .password])
    func emptyListWritesNothing(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "a")
        let before = try vault.snapshot()
        let callsBefore = vault.cipher.calls.count

        let failures = await vault.store.moveToTrash([])

        #expect(failures.isEmpty)
        #expect(vault.cipher.calls.count == callsBefore)
        #expect(try vault.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: vault.trashURL.path))
    }

    @Test("moveToTrash of an empty list with the key missing returns an empty result")
    func emptyListWithoutKey() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        vault.keys.wipeKey()
        let before = try vault.snapshot()

        let failures = await vault.store.moveToTrash([])

        #expect(failures.isEmpty)
        #expect(try vault.snapshot() == before)
    }
}
