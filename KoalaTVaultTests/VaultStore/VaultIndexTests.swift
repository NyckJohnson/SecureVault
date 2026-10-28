import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultIndexTests {
    private let uuidA = "AAAAAAAA-0000-0000-0000-000000000001"
    private let uuidB = "BBBBBBBB-0000-0000-0000-000000000002"

    // MARK: - Index read

    @Test("A folder without an index lists its files under their disk names")
    func absentIndexIsEmpty() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        try fx.diskFile("plain.txt")
        let items = try await fx.list()
        #expect(items.map(\.name) == ["plain.txt"])
        #expect(items.first?.isEncrypted == false)
        #expect(fx.rawIndex() == nil)
    }

    @Test("An index encrypted with the accepted context is decoded", arguments: [".vault_map", "Docs", ""])
    func encryptedIndexAcceptsEachContext(context: String) async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        try fx.diskFile(uuidA, "secret", in: docs)
        try fx.writeIndex([uuidA: "Taxes.pdf"], in: docs, context: context)
        let items = try await fx.list(docs)
        #expect(items.map(\.name) == ["Taxes.pdf"])
        #expect(items.first?.isEncrypted == true)
    }

    @Test("Index decryption tries .vault_map first, then the folder-relative path, then the empty context")
    func decryptionContextOrder() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        try fx.diskFile(uuidA, in: docs)
        try fx.writeIndex([uuidA: "a.txt"], in: docs, context: ".vault_map")
        _ = try await fx.list(docs)
        let decrypts = fx.cipher.calls.compactMap { call -> [String]? in
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
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        try fx.diskFile(uuidA, "secret")
        try fx.writeIndex([uuidA: "Old.txt"], context: nil)
        let items = try await fx.list()
        #expect(items.map(\.name) == ["Old.txt"])
        #expect(items.first?.isEncrypted == true)
    }

    @Test("A plaintext JSON index is read in plaintext mode")
    func plaintextIndexReadInPlaintextMode() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        try fx.diskFile(uuidA, "secret")
        try fx.writeIndex([uuidA: "Old.txt"], context: nil)
        let items = try await fx.list()
        #expect(items.map(\.name) == ["Old.txt"])
        #expect(items.first?.isEncrypted == true)
    }

    @Test("A plaintext index is rewritten encrypted on the next write in encrypted mode")
    func plaintextIndexRewrittenEncrypted() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        try fx.diskFile(uuidA, "secret")
        try fx.writeIndex([uuidA: "Old.txt"], context: nil)
        let added = try await fx.add("New.txt")
        #expect(!fx.indexIsPlaintextJSON())
        #expect(fx.indexContext() == ".vault_map")
        let entries = try #require(fx.indexEntries())
        #expect(entries[uuidA] == "Old.txt")
        #expect(entries.values.contains("New.txt"))
        #expect(added.isEncrypted)
        #expect(Set(try await fx.names()) == ["Old.txt", "New.txt"])
    }

    @Test("A garbage index throws indexUnreadable and is not overwritten by a write attempt", arguments: [LockMode.password, .none])
    func unreadableIndexNeverOverwritten(mode: LockMode) async throws {
        let fx = try VaultStoreFixture(lockMode: mode)
        defer { fx.cleanUp() }
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01])
        try fx.writeRawIndex(garbage)
        let listError = await caught { _ = try await fx.list() }
        guard case .indexUnreadable = listError as? VaultStoreError else {
            Issue.record("expected indexUnreadable, got \(String(describing: listError))")
            return
        }
        if mode != .none {
            let addError = await caught { _ = try await fx.add("new.txt") }
            guard case .indexUnreadable = addError as? VaultStoreError else {
                Issue.record("expected indexUnreadable, got \(String(describing: addError))")
                return
            }
        }
        #expect(fx.rawIndex() == garbage)
    }

    @Test("An encrypted index sealed under an unknown context is unreadable and left untouched")
    func wrongContextIndexUnreadable() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        try fx.writeIndex([uuidA: "x.txt"], context: "Somewhere/else")
        let before = fx.rawIndex()
        let error = await caught { _ = try await fx.list() }
        guard case .indexUnreadable = error as? VaultStoreError else {
            Issue.record("expected indexUnreadable, got \(String(describing: error))")
            return
        }
        _ = await caught { _ = try await fx.add("new.txt") }
        #expect(fx.rawIndex() == before)
    }

    @Test("indexUnreadable names the folder whose index failed")
    func unreadableIndexNamesFolder() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        try fx.writeRawIndex(Data([1, 2, 3]), in: docs)
        let error = await caught { _ = try await fx.list(docs) }
        guard case .indexUnreadable(let folder) = error as? VaultStoreError else {
            Issue.record("expected indexUnreadable, got \(String(describing: error))")
            return
        }
        #expect(folder.contains("Docs"))
    }

    // MARK: - Index write

    @Test("In encrypted mode the index is written encrypted with context .vault_map and never as plaintext")
    func encryptedModeWritesEncryptedIndex() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let item = try await fx.add("Secret Plans.txt", "plans")
        #expect(!fx.indexIsPlaintextJSON())
        #expect(fx.indexContext() == ".vault_map")
        #expect(fx.cipher.calls.contains(.encrypt(context: ".vault_map")))
        let entries = try #require(fx.indexEntries())
        #expect(entries.count == 1)
        #expect(entries.values.first == "Secret Plans.txt")
        // The plaintext name is not a name on disk; the disk file is the indexed UUID.
        #expect(entries.keys.first.map { item.id.hasSuffix($0) } == true)
        #expect(!(try fx.diskNames()).contains("Secret Plans.txt"))
    }

    @Test("In plaintext mode a rename of a mapped file writes the index as plaintext JSON")
    func plaintextModeWritesPlaintextIndex() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        try fx.diskFile(uuidA, "secret")
        try fx.writeIndex([uuidA: "Old.txt"], context: nil)
        let item = try #require(try await fx.list().first)
        _ = try await fx.store.rename(item, to: "Renamed.txt")
        #expect(fx.indexIsPlaintextJSON())
        #expect(fx.indexEntries()?[uuidA] == "Renamed.txt")
    }

    @Test("Plaintext mode with no mapped files never creates an index")
    func plaintextModeCreatesNoIndex() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        _ = try await fx.add("a.txt")
        _ = try await fx.store.createFolder(named: "Docs", in: fx.root)
        #expect(fx.rawIndex() == nil)
        #expect(try fx.diskNames() == ["Docs", "a.txt"])
    }

    @Test("Each folder has its own index")
    func indexPerFolder() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        try await fx.add("root.txt")
        try await fx.add("inner.txt", to: docs)
        #expect(fx.indexEntries()?.values.sorted() == ["root.txt"])
        #expect(fx.indexEntries(in: docs)?.values.sorted() == ["inner.txt"])
        #expect(fx.indexContext(in: docs) == ".vault_map")
    }

    // MARK: - Serialization

    @Test("Concurrent imports into one folder never lose an index entry")
    func concurrentAddFileKeepsEveryEntry() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let count = 20
        let sources = try (0..<count).map { try fx.source("file\($0).txt", "content \($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    _ = try await fx.store.addFile(from: source, named: "file\(index).txt", to: fx.root)
                }
            }
            try await group.waitForAll()
        }
        let entries = try #require(fx.indexEntries())
        #expect(entries.count == count)
        #expect(Set(entries.values) == Set((0..<count).map { "file\($0).txt" }))
        #expect(try await fx.list().count == count)
    }

    @Test("Concurrent imports of the same name each get a distinct conflict-free name")
    func concurrentSameNameImports() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let sources = try (0..<5).map { try fx.source("same.txt", "c\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    _ = try await fx.store.addFile(from: source, named: "same.txt", to: fx.root)
                }
            }
            try await group.waitForAll()
        }
        let names = try await fx.names()
        #expect(names.count == 5)
        #expect(Set(names) == ["same.txt", "same 1.txt", "same 2.txt", "same 3.txt", "same 4.txt"])
    }

    @Test("Concurrent moves and imports into one folder never lose an entry")
    func concurrentMovesAndImports() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        var existing: [VaultItem] = []
        for index in 0..<10 { existing.append(try await fx.add("moved\(index).txt")) }
        let sources = try (0..<10).map { try fx.source("added\($0).txt") }
        let moving = existing
        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in moving {
                group.addTask { try await fx.store.move(item, to: docs) }
            }
            for (index, source) in sources.enumerated() {
                group.addTask {
                    _ = try await fx.store.addFile(from: source, named: "added\(index).txt", to: docs)
                }
            }
            try await group.waitForAll()
        }
        let docsEntries = try #require(fx.indexEntries(in: docs))
        #expect(docsEntries.count == 20)
        #expect(fx.indexEntries()?.isEmpty ?? true)
        #expect(try await fx.list(docs).count == 20)
        #expect(try await fx.list().filter { !$0.isDirectory }.isEmpty)
    }
}
