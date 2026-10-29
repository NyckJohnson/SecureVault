import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultIndexTests {
    private let uuidA = "AAAAAAAA-0000-0000-0000-000000000001"
    private let uuidB = "BBBBBBBB-0000-0000-0000-000000000002"

    // MARK: - Index read

    @Test("A folder without an index lists its files under their disk names")
    func absentIndexIsEmpty() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.diskFile("plain.txt")
        let items = try await vault.list()
        #expect(items.map(\.name) == ["plain.txt"])
        #expect(items.first?.isEncrypted == false)
        #expect(vault.rawIndex() == nil)
    }

    @Test("An index encrypted with the accepted context is decoded", arguments: [".vault_map", "Docs", ""])
    func encryptedIndexAcceptsEachContext(context: String) async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile(uuidA, "secret", in: docs)
        try vault.writeIndex([uuidA: "Taxes.pdf"], in: docs, context: context)
        let items = try await vault.list(docs)
        #expect(items.map(\.name) == ["Taxes.pdf"])
        #expect(items.first?.isEncrypted == true)
    }

    @Test("Index decryption tries .vault_map first, then the folder-relative path, then the empty context")
    func decryptionContextOrder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile(uuidA, in: docs)
        try vault.writeIndex([uuidA: "a.txt"], in: docs, context: ".vault_map")
        _ = try await vault.list(docs)
        let decrypts = vault.cipher.calls.compactMap { call -> [String]? in
            if case .decrypt(let contexts) = call { return contexts }
            return nil
        }
        let contexts = try #require(decrypts.first)
        #expect(contexts.first == ".vault_map")
        let relativeIndex = try #require(contexts.firstIndex(of: "Docs"))
        let emptyIndex = try #require(contexts.firstIndex(of: ""))
        #expect(relativeIndex < emptyIndex)
    }

    @Test("A plaintext JSON index is read in encrypted mode")
    func plaintextIndexReadInEncryptedMode() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.diskFile(uuidA, "secret")
        try vault.writeIndex([uuidA: "Old.txt"], context: nil)
        let items = try await vault.list()
        #expect(items.map(\.name) == ["Old.txt"])
        #expect(items.first?.isEncrypted == true)
    }

    @Test("A plaintext JSON index is read in plaintext mode")
    func plaintextIndexReadInPlaintextMode() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.diskFile(uuidA, "secret")
        try vault.writeIndex([uuidA: "Old.txt"], context: nil)
        let items = try await vault.list()
        #expect(items.map(\.name) == ["Old.txt"])
        #expect(items.first?.isEncrypted == true)
    }

    @Test("A plaintext index is rewritten encrypted on the next write in encrypted mode")
    func plaintextIndexRewrittenEncrypted() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.diskFile(uuidA, "secret")
        try vault.writeIndex([uuidA: "Old.txt"], context: nil)
        let added = try await vault.add("New.txt")
        #expect(!vault.indexIsPlaintextJSON())
        #expect(vault.indexContext() == ".vault_map")
        let entries = try #require(vault.indexEntries())
        #expect(entries[uuidA] == "Old.txt")
        #expect(entries.values.contains("New.txt"))
        #expect(added.isEncrypted)
        #expect(Set(try await vault.names()) == ["Old.txt", "New.txt"])
    }

    @Test(
        "A garbage index throws indexUnreadable and is not overwritten by a write attempt",
        arguments: [LockMode.password, .none])
    func unreadableIndexNeverOverwritten(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01])
        try vault.writeRawIndex(garbage)
        let listError = await caught { _ = try await vault.list() }
        guard case .indexUnreadable = listError as? VaultStoreError else {
            Issue.record("expected indexUnreadable, got \(String(describing: listError))")
            return
        }
        if mode != .none {
            let addError = await caught { _ = try await vault.add("new.txt") }
            guard case .indexUnreadable = addError as? VaultStoreError else {
                Issue.record("expected indexUnreadable, got \(String(describing: addError))")
                return
            }
        }
        #expect(vault.rawIndex() == garbage)
    }

    @Test("An encrypted index sealed under an unknown context is unreadable and left untouched")
    func wrongContextIndexUnreadable() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.writeIndex([uuidA: "x.txt"], context: "Somewhere/else")
        let before = vault.rawIndex()
        let error = await caught { _ = try await vault.list() }
        guard case .indexUnreadable = error as? VaultStoreError else {
            Issue.record("expected indexUnreadable, got \(String(describing: error))")
            return
        }
        _ = await caught { _ = try await vault.add("new.txt") }
        #expect(vault.rawIndex() == before)
    }

    @Test("indexUnreadable names the folder whose index failed")
    func unreadableIndexNamesFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.writeRawIndex(Data([1, 2, 3]), in: docs)
        let error = await caught { _ = try await vault.list(docs) }
        guard case .indexUnreadable(let folder) = error as? VaultStoreError else {
            Issue.record("expected indexUnreadable, got \(String(describing: error))")
            return
        }
        #expect(folder.contains("Docs"))
    }

    // MARK: - Index write

    @Test("In encrypted mode the index is written encrypted with context .vault_map and never as plaintext")
    func encryptedModeWritesEncryptedIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("Secret Plans.txt", "plans")
        #expect(!vault.indexIsPlaintextJSON())
        #expect(vault.indexContext() == ".vault_map")
        #expect(vault.cipher.calls.contains(.encrypt(context: ".vault_map")))
        let entries = try #require(vault.indexEntries())
        #expect(entries.count == 1)
        #expect(entries.values.first == "Secret Plans.txt")
        // The plaintext name is not a name on disk; the disk file is the indexed UUID.
        #expect(entries.keys.first.map { item.id.hasSuffix($0) } == true)
        #expect(!(try vault.diskNames()).contains("Secret Plans.txt"))
    }

    @Test("In plaintext mode a rename of a mapped file writes the index as plaintext JSON")
    func plaintextModeWritesPlaintextIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.diskFile(uuidA, "secret")
        try vault.writeIndex([uuidA: "Old.txt"], context: nil)
        let item = try #require(try await vault.list().first)
        _ = try await vault.store.rename(item, to: "Renamed.txt")
        #expect(vault.indexIsPlaintextJSON())
        #expect(vault.indexEntries()?[uuidA] == "Renamed.txt")
    }

    @Test("Plaintext mode with no mapped files never creates an index")
    func plaintextModeCreatesNoIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        _ = try await vault.add("a.txt")
        _ = try await vault.store.createFolder(named: "Docs", in: vault.root)
        #expect(vault.rawIndex() == nil)
        #expect(try vault.diskNames() == ["Docs", "a.txt"])
    }

    @Test("Each folder has its own index")
    func indexPerFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try await vault.add("root.txt")
        try await vault.add("inner.txt", to: docs)
        #expect(vault.indexEntries()?.values.sorted() == ["root.txt"])
        #expect(vault.indexEntries(in: docs)?.values.sorted() == ["inner.txt"])
        #expect(vault.indexContext(in: docs) == ".vault_map")
    }

    // MARK: - Serialization

    @Test("Concurrent imports into one folder never lose an index entry")
    func concurrentAddFileKeepsEveryEntry() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let count = 20
        let sources = try (0..<count).map { try vault.source("file\($0).txt", "content \($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    _ = try await vault.store.addFile(from: source, named: "file\(index).txt", to: vault.root)
                }
            }
            try await group.waitForAll()
        }
        let entries = try #require(vault.indexEntries())
        #expect(entries.count == count)
        #expect(Set(entries.values) == Set((0..<count).map { "file\($0).txt" }))
        #expect(try await vault.list().count == count)
    }

    @Test("Concurrent imports of the same name each get a distinct conflict-free name")
    func concurrentSameNameImports() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let sources = try (0..<5).map { try vault.source("same.txt", "c\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    _ = try await vault.store.addFile(from: source, named: "same.txt", to: vault.root)
                }
            }
            try await group.waitForAll()
        }
        let names = try await vault.names()
        #expect(names.count == 5)
        #expect(Set(names) == ["same.txt", "same 1.txt", "same 2.txt", "same 3.txt", "same 4.txt"])
    }

    @Test("Concurrent moves and imports into one folder never lose an entry")
    func concurrentMovesAndImports() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        var existing: [VaultItem] = []
        for index in 0..<10 { existing.append(try await vault.add("moved\(index).txt")) }
        let sources = try (0..<10).map { try vault.source("added\($0).txt") }
        let moving = existing
        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in moving {
                group.addTask { try await vault.store.move(item, to: docs) }
            }
            for (index, source) in sources.enumerated() {
                group.addTask {
                    _ = try await vault.store.addFile(from: source, named: "added\(index).txt", to: docs)
                }
            }
            try await group.waitForAll()
        }
        let docsEntries = try #require(vault.indexEntries(in: docs))
        #expect(docsEntries.count == 20)
        #expect(vault.indexEntries()?.isEmpty ?? true)
        #expect(try await vault.list(docs).count == 20)
        #expect(try await vault.list().filter { !$0.isDirectory }.isEmpty)
    }

    // MARK: - Legacy cases (unreadable folder indexes, fallback contexts)

    @Test("Renaming an item in a folder whose index is unreadable throws indexUnreadable and leaves the index")
    func renameWithUnreadableIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("a.txt", "data", to: docs)
        let garbage = Data([9, 8, 7, 6])
        try vault.writeRawIndex(garbage, in: docs)
        let error = await caught { _ = try await vault.store.rename(item, to: "b.txt") }
        #expect(isIndexUnreadable(error))
        #expect(vault.rawIndex(in: docs) == garbage)
    }

    @Test("Moving into a folder whose index is unreadable throws indexUnreadable and the item stays in its source")
    func moveIntoUnreadableIndexFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("a.txt", "data")
        let garbage = Data([9, 8, 7, 6])
        try vault.writeRawIndex(garbage, in: docs)
        let error = await caught { try await vault.store.move(item, to: docs) }
        #expect(isIndexUnreadable(error))
        #expect(vault.rawIndex(in: docs) == garbage)
        #expect(try vault.diskNames(in: docs) == [".vault_map"])
        let inRoot = try await vault.store.findItem(named: "a.txt", in: vault.root)
        #expect(inRoot?.id == item.id)
        #expect(vault.indexEntries()?[item.id] == "a.txt")
    }

    @Test(
        "addFile into a folder whose index uses a fallback context keeps the old entries and reseals with .vault_map",
        arguments: ["Docs", ""])
    func addFileResealsFallbackContextIndex(context: String) async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile(uuidA, "old", in: docs)
        try vault.writeIndex([uuidA: "Old.txt"], in: docs, context: context)
        let added = try await vault.add("New.txt", "new", to: docs)
        #expect(try await vault.names(docs) == ["New.txt", "Old.txt"])
        #expect(vault.indexContext(in: docs) == ".vault_map")
        let addedDiskName = (added.id as NSString).lastPathComponent
        let expectedEntries = [uuidA: "Old.txt", addedDiskName: "New.txt"]
        #expect(vault.indexEntries(in: docs) == expectedEntries)
        #expect(try await vault.openedContent(added) == "new")
    }
}
