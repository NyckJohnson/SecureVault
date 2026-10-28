import Foundation
import Testing

@testable import KoalaTVault

/// Name validation and " 1" / " 2" conflict naming, observed through the store's operations.
@Suite struct VaultNamingTests {
    // MARK: - Conflict naming, plaintext mode

    @Test("A second folder with the same name gets ' 1', a third ' 2'")
    func folderConflictsNumbered() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let first = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let second = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let third = try await vault.store.createFolder(named: "Docs", in: vault.root)
        #expect([first.name, second.name, third.name] == ["Docs", "Docs 1", "Docs 2"])
        #expect(try vault.diskNames() == ["Docs", "Docs 1", "Docs 2"])
    }

    @Test("A conflicting file gets the number before the extension")
    func plaintextFileConflictsNumberedBeforeExtension() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let names = try await ["a.txt", "a.txt", "a.txt"].asyncMap { try await vault.add($0).name }
        #expect(names == ["a.txt", "a 1.txt", "a 2.txt"])
        #expect(try vault.diskNames() == ["a 1.txt", "a 2.txt", "a.txt"])
    }

    @Test("A conflicting file without an extension gets the number at the end")
    func plaintextFileWithoutExtension() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let names = try await ["README", "README"].asyncMap { try await vault.add($0).name }
        #expect(names == ["README", "README 1"])
    }

    @Test("The first free number is used when ' 1' is already taken")
    func firstFreeNumberUsed() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.diskFile("a.txt")
        try vault.diskFile("a 1.txt")
        let item = try await vault.add("a.txt")
        #expect(item.name == "a 2.txt")
    }

    @Test("A name that is free keeps its original form even if numbered siblings exist")
    func freeNameKept() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.diskFile("a 1.txt")
        let item = try await vault.add("a.txt")
        #expect(item.name == "a.txt")
    }

    @Test("A file conflicts with a folder of the same name")
    func fileConflictsWithFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.folder("stuff")
        let item = try await vault.add("stuff")
        #expect(item.name == "stuff 1")
    }

    // MARK: - Conflict naming, encrypted mode (on the display name)

    @Test("In encrypted mode conflicts are resolved on the display name and the index holds the numbered name")
    func encryptedConflictsOnDisplayName() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let names = try await ["a.txt", "a.txt", "a.txt"].asyncMap { try await vault.add($0).name }
        #expect(names == ["a.txt", "a 1.txt", "a 2.txt"])
        let entries = try #require(vault.indexEntries())
        #expect(Set(entries.values) == ["a.txt", "a 1.txt", "a 2.txt"])
        #expect(try await vault.names() == ["a 1.txt", "a 2.txt", "a.txt"])
    }

    @Test("An encrypted import conflicts with a plaintext file of the same display name")
    func encryptedConflictsWithPlainFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.diskFile("a.txt")
        let item = try await vault.add("a.txt")
        #expect(item.name == "a 1.txt")
    }

    // MARK: - Documents

    @Test("createDocument adds .rtf when missing and keeps it when present")
    func documentExtension() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let bare = try await vault.store.createDocument(named: "Notes", in: vault.root)
        let withExtension = try await vault.store.createDocument(named: "Letter.rtf", in: vault.root)
        #expect(bare.name == "Notes.rtf")
        #expect(withExtension.name == "Letter.rtf")
        #expect(try vault.diskNames() == ["Letter.rtf", "Notes.rtf"])
    }

    @Test("A document name that conflicts gets ' 1' before .rtf")
    func documentConflict() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        _ = try await vault.store.createDocument(named: "Notes", in: vault.root)
        let second = try await vault.store.createDocument(named: "Notes", in: vault.root)
        let third = try await vault.store.createDocument(named: "Notes.rtf", in: vault.root)
        #expect(second.name == "Notes 1.rtf")
        #expect(third.name == "Notes 2.rtf")
    }

    // MARK: - Move, copy, rename conflicts

    @Test("Moving into a folder that already has the name numbers the moved item")
    func moveConflictNumbered() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile("a.txt", "inside", in: docs)
        let item = try await vault.add("a.txt", "moving")
        try await vault.store.move(item, to: docs)
        #expect(try await vault.names(docs) == ["a 1.txt", "a.txt"])
    }

    @Test("Copying numbers the copy ' 1', then ' 2'")
    func copyNumbered() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        let first = try await vault.store.copy(item, to: vault.root)
        let second = try await vault.store.copy(item, to: vault.root)
        #expect([first.name, second.name] == ["a 1.txt", "a 2.txt"])
    }

    @Test("Renaming to an existing name numbers the renamed item", arguments: [LockMode.none, .password])
    func renameConflictNumbered(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode, keyLoaded: true)
        defer { vault.cleanUp() }
        _ = try await vault.add("taken.txt")
        let other = try await vault.add("other.txt")
        let renamed = try await vault.store.rename(other, to: "taken.txt")
        #expect(renamed.name == "taken 1.txt")
        #expect(Set(try await vault.names()) == ["taken.txt", "taken 1.txt"])
    }

    // MARK: - Invalid names

    @Test("createFolder rejects an empty name and a slash", arguments: ["", "/"])
    func createFolderInvalidName(name: String) async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let error = await caught { _ = try await vault.store.createFolder(named: name, in: vault.root) }
        #expect(error as? VaultStoreError == .invalidName)
        #expect(try vault.diskNames().isEmpty)
    }

    @Test("createDocument rejects an empty name and a slash", arguments: ["", "/"], [LockMode.none, .password])
    func createDocumentInvalidName(name: String, mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let error = await caught { _ = try await vault.store.createDocument(named: name, in: vault.root) }
        #expect(error as? VaultStoreError == .invalidName)
        #expect(try vault.diskNames().isEmpty)
    }

    @Test(
        "rename rejects an empty name and a slash and leaves the item", arguments: ["", "/"],
        [LockMode.none, .password])
    func renameInvalidName(name: String, mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let item = try await vault.add("keep.txt")
        let before = try vault.diskNames()
        let error = await caught { _ = try await vault.store.rename(item, to: name) }
        #expect(error as? VaultStoreError == .invalidName)
        #expect(try vault.diskNames() == before)
        #expect(try await vault.names() == ["keep.txt"])
    }
}
