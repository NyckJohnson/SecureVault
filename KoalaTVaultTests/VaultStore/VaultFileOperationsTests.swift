import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultFileOperationsTests {
    private func isEncryptFile(_ call: MockFileCipher.Call) -> Bool {
        if case .encryptFile = call { return true }
        return false
    }

    // MARK: - createFolder

    @Test("createFolder makes a plaintext-named folder in both modes", arguments: [LockMode.none, .password])
    func createFolderPlaintextName(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let folder = try await vault.store.createFolder(named: "Photos", in: vault.root)
        #expect(folder.name == "Photos")
        #expect(folder.isDirectory)
        #expect(folder.id == "Photos")
        #expect(folder.fileSize == nil)
        #expect(folder.isEncrypted == false)
        #expect(try vault.diskNames() == ["Photos"])
        #expect(vault.rawIndex() == nil)
    }

    @Test("createFolder inside a folder gives a nested id")
    func createNestedFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let docs = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let inner = try await vault.store.createFolder(named: "Inner", in: try #require(docs.asDirectory))
        #expect(inner.id == "Docs/Inner")
    }

    // MARK: - createDocument

    @Test("createDocument in plaintext mode makes an empty .rtf file")
    func createDocumentPlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let doc = try await vault.store.createDocument(named: "Notes", in: vault.root)
        #expect(doc.name == "Notes.rtf")
        #expect(doc.isDirectory == false)
        #expect(doc.isEncrypted == false)
        #expect(doc.kind == .text)
        #expect(try vault.content(doc.diskURL).isEmpty)
        #expect(try vault.diskNames() == ["Notes.rtf"])
    }

    @Test("createDocument in encrypted mode is encrypted and indexed under a UUID file name")
    func createDocumentEncrypted() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let doc = try await vault.store.createDocument(named: "Notes", in: vault.root)
        #expect(doc.name == "Notes.rtf")
        #expect(doc.isEncrypted)
        #expect(vault.indexEntries()?[doc.id] == "Notes.rtf")
        #expect(UUID(uuidString: doc.id) != nil)
        #expect(!(try vault.diskNames()).contains("Notes.rtf"))
        #expect(vault.cipher.calls.contains(where: isEncryptFile))
        #expect(try await vault.openedContent(doc).isEmpty)
    }

    @Test(
        "createDocument never truncates an existing document of the same name", arguments: [LockMode.none, .password])
    func createDocumentKeepsExisting(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let first = try await vault.store.createDocument(named: "Notes", in: vault.root)
        try await vault.store.write(Data("precious".utf8), to: first)
        let second = try await vault.store.createDocument(named: "Notes", in: vault.root)
        #expect(second.name == "Notes 1.rtf")
        #expect(try await vault.openedContent(first) == "precious")
    }

    // MARK: - addFile

    @Test("addFile in plaintext mode copies the file under its name and leaves the source")
    func addFilePlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let source = try vault.source("photo.jpg", "pixels")
        let item = try await vault.store.addFile(from: source, named: "photo.jpg", to: vault.root)
        #expect(item.name == "photo.jpg")
        #expect(item.id == "photo.jpg")
        #expect(item.isEncrypted == false)
        #expect(item.kind == .image)
        #expect(try vault.content(item.diskURL) == "pixels")
        #expect(try vault.content(source) == "pixels")
    }

    @Test("addFile uses the given name rather than the source's file name")
    func addFileUsesGivenName() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let source = try vault.source("tmp-1234.dat", "x")
        let item = try await vault.store.addFile(from: source, named: "Holiday.mov", to: vault.root)
        #expect(item.name == "Holiday.mov")
        #expect(try vault.diskNames() == ["Holiday.mov"])
    }

    @Test("addFile in encrypted mode stores a new extensionless UUID file and indexes the name in one step")
    func addFileEncrypted() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let source = try vault.source("Report.pdf", "report bytes")
        let item = try await vault.store.addFile(from: source, named: "Report.pdf", to: docs)
        #expect(item.name == "Report.pdf")
        #expect(item.isEncrypted)
        #expect(item.kind == .pdf)
        let diskName = (item.id as NSString).lastPathComponent
        #expect(UUID(uuidString: diskName) != nil)
        #expect(item.id == "Docs/" + diskName)
        #expect(vault.indexEntries(in: docs) == [diskName: "Report.pdf"])
        #expect(try vault.diskNames(in: docs).sorted() == [".vault_map", diskName])
        #expect(vault.cipher.calls.contains(where: isEncryptFile))
        #expect(try await vault.openedContent(item) == "report bytes")
        #expect(try vault.content(source) == "report bytes")
    }

    @Test("addFile with a missing source throws io and writes nothing", arguments: [LockMode.none, .password])
    func addFileMissingSource(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let missing = vault.sourcesURL.appendingPathComponent("nope.txt")
        let before = try vault.snapshot()
        let error = await caught { _ = try await vault.store.addFile(from: missing, named: "nope.txt", to: vault.root) }
        let storeError = try #require(error as? VaultStoreError)
        guard case .io = storeError else {
            Issue.record("expected io, got \(storeError)")
            return
        }
        #expect(try vault.snapshot() == before)
        #expect(try await vault.list().isEmpty)
    }

    @Test("addFile with an encryption failure throws and leaves the folder and index without the file")
    func addFileEncryptionFailure() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("existing.txt")
        let source = try vault.source("new.txt")
        let indexBefore = vault.indexEntries()
        let filesBefore = try vault.diskNames()
        vault.cipher.errorToThrow = .encryptionFailed
        let error = await caught { _ = try await vault.store.addFile(from: source, named: "new.txt", to: vault.root) }
        #expect(error != nil)
        vault.cipher.errorToThrow = nil
        #expect(vault.indexEntries() == indexBefore)
        #expect(try vault.diskNames() == filesBefore)
    }

    // MARK: - move

    @Test("Moving a plaintext file relocates it", arguments: [LockMode.none, .password])
    func movePlaintextFile(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile("loose.txt", "data")
        let item = try #require(try await vault.list().first { $0.name == "loose.txt" })
        try await vault.store.move(item, to: docs)
        #expect(try await vault.store.findItem(named: "loose.txt", in: vault.root) == nil)
        let moved = try #require(try await vault.store.findItem(named: "loose.txt", in: docs))
        #expect(moved.id == "Docs/loose.txt")
        #expect(try vault.content(moved.diskURL) == "data")
    }

    @Test("Moving an encrypted file moves the file and its index entry")
    func moveEncryptedFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("Secret.txt", "secret")
        let diskName = item.id
        try await vault.store.move(item, to: docs)
        #expect(vault.indexEntries()?.isEmpty ?? true)
        #expect(vault.indexEntries(in: docs) == [diskName: "Secret.txt"])
        #expect(try vault.diskNames(in: docs).contains(diskName))
        #expect(!(try vault.diskNames()).contains(diskName))
        let moved = try #require(try await vault.store.findItem(named: "Secret.txt", in: docs))
        #expect(moved.isEncrypted)
        #expect(try await vault.openedContent(moved) == "secret")
        #expect(try await vault.store.findItem(named: "Secret.txt", in: vault.root) == nil)
    }

    @Test("Moving an encrypted file onto a display-name conflict numbers it in the target index")
    func moveEncryptedConflict() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try await vault.add("a.txt", "inside", to: docs)
        let item = try await vault.add("a.txt", "moving")
        try await vault.store.move(item, to: docs)
        let entries = try #require(vault.indexEntries(in: docs))
        #expect(Set(entries.values) == ["a.txt", "a 1.txt"])
        let renamed = try #require(try await vault.store.findItem(named: "a 1.txt", in: docs))
        #expect(try await vault.openedContent(renamed) == "moving")
    }

    @Test("Moving an item into its own folder changes nothing", arguments: [LockMode.none, .password])
    func moveIntoOwnFolder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        let before = try await vault.list()
        let namesOnDisk = try vault.diskNames()
        try await vault.store.move(item, to: vault.root)
        #expect(try await vault.list() == before)
        #expect(try vault.diskNames() == namesOnDisk)
        #expect(try await vault.names() == ["a.txt"])
    }

    @Test("Moving a folder into itself throws moveIntoItself and changes nothing")
    func moveFolderIntoItself() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let folder = try await vault.store.createFolder(named: "A", in: vault.root)
        let before = try vault.snapshot()
        let error = await caught { try await vault.store.move(folder, to: try #require(folder.asDirectory)) }
        #expect(error as? VaultStoreError == .moveIntoItself)
        #expect(try vault.snapshot() == before)
    }

    @Test("Moving a folder into a descendant throws moveIntoItself and changes nothing")
    func moveFolderIntoDescendant() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let outer = try await vault.store.createFolder(named: "A", in: vault.root)
        let middle = try await vault.store.createFolder(named: "B", in: try #require(outer.asDirectory))
        let inner = try await vault.store.createFolder(named: "C", in: try #require(middle.asDirectory))
        let before = try vault.snapshot()
        let error = await caught { try await vault.store.move(outer, to: try #require(inner.asDirectory)) }
        #expect(error as? VaultStoreError == .moveIntoItself)
        #expect(try vault.snapshot() == before)
    }

    @Test("A folder with its contents moves into a sibling folder, encrypted files included")
    func moveFolderWithContents() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let source = try await vault.store.createFolder(named: "Source", in: vault.root)
        let target = try await vault.store.createFolder(named: "Target", in: vault.root)
        let sourceDir = try #require(source.asDirectory)
        try await vault.add("inside.txt", "inner data", to: sourceDir)
        try await vault.store.move(source, to: try #require(target.asDirectory))
        let targetDir = try #require(target.asDirectory)
        let moved = try #require(try await vault.store.findItem(named: "Source", in: targetDir))
        let movedDir = try #require(moved.asDirectory)
        let inside = try #require(try await vault.store.findItem(named: "inside.txt", in: movedDir))
        #expect(try await vault.openedContent(inside) == "inner data")
        #expect(try await vault.store.findItem(named: "Source", in: vault.root) == nil)
    }

    @Test("A move that fails leaves the item findable in exactly one place", arguments: [LockMode.none, .password])
    func failedMoveLeavesItemInOnePlace(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("a.txt", "data")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: docs.diskURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docs.diskURL.path)
        }
        _ = await caught { try await vault.store.move(item, to: docs) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docs.diskURL.path)
        let inRoot = try await vault.store.findItem(named: "a.txt", in: vault.root)
        let inDocs = try await vault.store.findItem(named: "a.txt", in: docs)
        #expect([inRoot, inDocs].compactMap { $0 }.count == 1)
    }

    // MARK: - copy

    @Test("Copying a plaintext file adds a numbered copy and keeps the original")
    func copyPlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        let copy = try await vault.store.copy(item, to: vault.root)
        #expect(copy.name == "a 1.txt")
        #expect(copy.id != item.id)
        #expect(try vault.content(copy.diskURL) == "data")
        #expect(try vault.content(item.diskURL) == "data")
        #expect(try await vault.names() == ["a 1.txt", "a.txt"])
    }

    @Test("Copying into another folder without a conflict keeps the name")
    func copyToOtherFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("a.txt", "data")
        let copy = try await vault.store.copy(item, to: docs)
        #expect(copy.name == "a.txt")
        #expect(copy.id == "Docs/a.txt")
        #expect(try await vault.names() == ["Docs", "a.txt"])
    }

    @Test("An encrypted copy stays encrypted, has its own file and entry, and decrypts to the same content")
    func copyEncrypted() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("Secret.txt", "same content")
        let first = try await vault.store.copy(item, to: vault.root)
        let second = try await vault.store.copy(item, to: vault.root)
        #expect([first.name, second.name] == ["Secret 1.txt", "Secret 2.txt"])
        #expect(first.isEncrypted && second.isEncrypted)
        #expect(Set([item.id, first.id, second.id]).count == 3)
        let entries = try #require(vault.indexEntries())
        #expect(entries.count == 3)
        #expect(entries[first.id] == "Secret 1.txt")
        for copy in [first, second] {
            #expect(try await vault.openedContent(copy) == "same content")
        }
        #expect(try await vault.openedContent(item) == "same content")
        #expect(!(try vault.diskNames()).contains("Secret 1.txt"))
    }

    @Test("Copying an encrypted file into another folder indexes it there")
    func copyEncryptedToOtherFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("Secret.txt", "data")
        let copy = try await vault.store.copy(item, to: docs)
        #expect(copy.name == "Secret.txt")
        #expect(vault.indexEntries(in: docs)?.values.sorted() == ["Secret.txt"])
        #expect(vault.indexEntries()?.values.sorted() == ["Secret.txt"])
    }

    // MARK: - rename

    @Test("Renaming a plaintext file renames it on disk")
    func renamePlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let item = try await vault.add("old.txt", "data")
        let renamed = try await vault.store.rename(item, to: "new.pdf")
        #expect(renamed.name == "new.pdf")
        #expect(renamed.id == "new.pdf")
        #expect(renamed.kind == .pdf)
        #expect(try vault.diskNames() == ["new.pdf"])
        #expect(try vault.content(renamed.diskURL) == "data")
    }

    @Test("Renaming a plaintext folder renames it on disk")
    func renamePlaintextFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let folder = try await vault.store.createFolder(named: "Old", in: vault.root)
        let renamed = try await vault.store.rename(folder, to: "New")
        #expect(renamed.isDirectory)
        #expect(renamed.name == "New")
        #expect(try vault.diskNames() == ["New"])
    }

    @Test("Renaming an encrypted file changes only the index entry")
    func renameEncrypted() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("old.txt", "data")
        let namesOnDisk = try vault.diskNames()
        let renamed = try await vault.store.rename(item, to: "new.pdf")
        #expect(renamed.name == "new.pdf")
        #expect(renamed.id == item.id)
        #expect(renamed.isEncrypted)
        #expect(renamed.kind == .pdf)
        #expect(try vault.diskNames() == namesOnDisk)
        #expect(vault.indexEntries() == [item.id: "new.pdf"])
        #expect(try await vault.names() == ["new.pdf"])
        #expect(try await vault.openedContent(renamed) == "data")
    }
}
