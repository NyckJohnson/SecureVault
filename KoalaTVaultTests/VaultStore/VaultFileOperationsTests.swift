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
        let fx = try VaultStoreFixture(lockMode: mode)
        defer { fx.cleanUp() }
        let folder = try await fx.store.createFolder(named: "Photos", in: fx.root)
        #expect(folder.name == "Photos")
        #expect(folder.isDirectory)
        #expect(folder.id == "Photos")
        #expect(folder.fileSize == nil)
        #expect(folder.isEncrypted == false)
        #expect(try fx.diskNames() == ["Photos"])
        #expect(fx.rawIndex() == nil)
    }

    @Test("createFolder inside a folder gives a nested id")
    func createNestedFolder() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let docs = try await fx.store.createFolder(named: "Docs", in: fx.root)
        let inner = try await fx.store.createFolder(named: "Inner", in: try #require(docs.asDirectory))
        #expect(inner.id == "Docs/Inner")
    }

    // MARK: - createDocument

    @Test("createDocument in plaintext mode makes an empty .rtf file")
    func createDocumentPlaintext() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let doc = try await fx.store.createDocument(named: "Notes", in: fx.root)
        #expect(doc.name == "Notes.rtf")
        #expect(doc.isDirectory == false)
        #expect(doc.isEncrypted == false)
        #expect(doc.kind == .text)
        #expect(try fx.content(doc.diskURL).isEmpty)
        #expect(try fx.diskNames() == ["Notes.rtf"])
    }

    @Test("createDocument in encrypted mode is encrypted and indexed under a UUID file name")
    func createDocumentEncrypted() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let doc = try await fx.store.createDocument(named: "Notes", in: fx.root)
        #expect(doc.name == "Notes.rtf")
        #expect(doc.isEncrypted)
        #expect(fx.indexEntries()?[doc.id] == "Notes.rtf")
        #expect(UUID(uuidString: doc.id) != nil)
        #expect(!(try fx.diskNames()).contains("Notes.rtf"))
        #expect(fx.cipher.calls.contains(where: isEncryptFile))
        #expect(try await fx.openedContent(doc).isEmpty)
    }

    @Test("createDocument never truncates an existing document of the same name", arguments: [LockMode.none, .password])
    func createDocumentKeepsExisting(mode: LockMode) async throws {
        let fx = try VaultStoreFixture(lockMode: mode)
        defer { fx.cleanUp() }
        let first = try await fx.store.createDocument(named: "Notes", in: fx.root)
        try await fx.store.write(Data("precious".utf8), to: first)
        let second = try await fx.store.createDocument(named: "Notes", in: fx.root)
        #expect(second.name == "Notes 1.rtf")
        #expect(try await fx.openedContent(first) == "precious")
    }

    // MARK: - addFile

    @Test("addFile in plaintext mode copies the file under its name and leaves the source")
    func addFilePlaintext() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let source = try fx.source("photo.jpg", "pixels")
        let item = try await fx.store.addFile(from: source, named: "photo.jpg", to: fx.root)
        #expect(item.name == "photo.jpg")
        #expect(item.id == "photo.jpg")
        #expect(item.isEncrypted == false)
        #expect(item.kind == .image)
        #expect(try fx.content(item.diskURL) == "pixels")
        #expect(try fx.content(source) == "pixels")
    }

    @Test("addFile uses the given name rather than the source's file name")
    func addFileUsesGivenName() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let source = try fx.source("tmp-1234.dat", "x")
        let item = try await fx.store.addFile(from: source, named: "Holiday.mov", to: fx.root)
        #expect(item.name == "Holiday.mov")
        #expect(try fx.diskNames() == ["Holiday.mov"])
    }

    @Test("addFile in encrypted mode stores a new extensionless UUID file and indexes the name in one step")
    func addFileEncrypted() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        let source = try fx.source("Report.pdf", "report bytes")
        let item = try await fx.store.addFile(from: source, named: "Report.pdf", to: docs)
        #expect(item.name == "Report.pdf")
        #expect(item.isEncrypted)
        #expect(item.kind == .pdf)
        let diskName = (item.id as NSString).lastPathComponent
        #expect(UUID(uuidString: diskName) != nil)
        #expect(item.id == "Docs/" + diskName)
        #expect(fx.indexEntries(in: docs) == [diskName: "Report.pdf"])
        #expect(try fx.diskNames(in: docs).sorted() == [".vault_map", diskName])
        #expect(fx.cipher.calls.contains(where: isEncryptFile))
        #expect(try await fx.openedContent(item) == "report bytes")
        #expect(try fx.content(source) == "report bytes")
    }

    @Test("addFile with a missing source throws io and writes nothing", arguments: [LockMode.none, .password])
    func addFileMissingSource(mode: LockMode) async throws {
        let fx = try VaultStoreFixture(lockMode: mode)
        defer { fx.cleanUp() }
        let missing = fx.sourcesURL.appendingPathComponent("nope.txt")
        let before = try fx.snapshot()
        let error = await caught { _ = try await fx.store.addFile(from: missing, named: "nope.txt", to: fx.root) }
        let storeError = try #require(error as? VaultStoreError)
        guard case .io = storeError else {
            Issue.record("expected io, got \(storeError)")
            return
        }
        #expect(try fx.snapshot() == before)
        #expect(try await fx.list().isEmpty)
    }

    @Test("addFile with an encryption failure throws and leaves the folder and index without the file")
    func addFileEncryptionFailure() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        try await fx.add("existing.txt")
        let source = try fx.source("new.txt")
        let indexBefore = fx.indexEntries()
        let filesBefore = try fx.diskNames()
        fx.cipher.errorToThrow = .encryptionFailed
        let error = await caught { _ = try await fx.store.addFile(from: source, named: "new.txt", to: fx.root) }
        #expect(error != nil)
        fx.cipher.errorToThrow = nil
        #expect(fx.indexEntries() == indexBefore)
        #expect(try fx.diskNames() == filesBefore)
    }

    // MARK: - move

    @Test("Moving a plaintext file relocates it", arguments: [LockMode.none, .password])
    func movePlaintextFile(mode: LockMode) async throws {
        let fx = try VaultStoreFixture(lockMode: mode)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        try fx.diskFile("loose.txt", "data")
        let item = try #require(try await fx.list().first { $0.name == "loose.txt" })
        try await fx.store.move(item, to: docs)
        #expect(try await fx.store.findItem(named: "loose.txt", in: fx.root) == nil)
        let moved = try #require(try await fx.store.findItem(named: "loose.txt", in: docs))
        #expect(moved.id == "Docs/loose.txt")
        #expect(try fx.content(moved.diskURL) == "data")
    }

    @Test("Moving an encrypted file moves the file and its index entry")
    func moveEncryptedFile() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        let item = try await fx.add("Secret.txt", "secret")
        let diskName = item.id
        try await fx.store.move(item, to: docs)
        #expect(fx.indexEntries()?.isEmpty ?? true)
        #expect(fx.indexEntries(in: docs) == [diskName: "Secret.txt"])
        #expect(try fx.diskNames(in: docs).contains(diskName))
        #expect(!(try fx.diskNames()).contains(diskName))
        let moved = try #require(try await fx.store.findItem(named: "Secret.txt", in: docs))
        #expect(moved.isEncrypted)
        #expect(try await fx.openedContent(moved) == "secret")
        #expect(try await fx.store.findItem(named: "Secret.txt", in: fx.root) == nil)
    }

    @Test("Moving an encrypted file onto a display-name conflict numbers it in the target index")
    func moveEncryptedConflict() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        try await fx.add("a.txt", "inside", to: docs)
        let item = try await fx.add("a.txt", "moving")
        try await fx.store.move(item, to: docs)
        #expect(Set(try #require(fx.indexEntries(in: docs)).values) == ["a.txt", "a 1.txt"])
        let renamed = try #require(try await fx.store.findItem(named: "a 1.txt", in: docs))
        #expect(try await fx.openedContent(renamed) == "moving")
    }

    @Test("Moving an item into its own folder changes nothing", arguments: [LockMode.none, .password])
    func moveIntoOwnFolder(mode: LockMode) async throws {
        let fx = try VaultStoreFixture(lockMode: mode)
        defer { fx.cleanUp() }
        let item = try await fx.add("a.txt", "data")
        let before = try await fx.list()
        let namesOnDisk = try fx.diskNames()
        try await fx.store.move(item, to: fx.root)
        #expect(try await fx.list() == before)
        #expect(try fx.diskNames() == namesOnDisk)
        #expect(try await fx.names() == ["a.txt"])
    }

    @Test("Moving a folder into itself throws moveIntoItself and changes nothing")
    func moveFolderIntoItself() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let folder = try await fx.store.createFolder(named: "A", in: fx.root)
        let before = try fx.snapshot()
        let error = await caught { try await fx.store.move(folder, to: try #require(folder.asDirectory)) }
        #expect(error as? VaultStoreError == .moveIntoItself)
        #expect(try fx.snapshot() == before)
    }

    @Test("Moving a folder into a descendant throws moveIntoItself and changes nothing")
    func moveFolderIntoDescendant() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let outer = try await fx.store.createFolder(named: "A", in: fx.root)
        let middle = try await fx.store.createFolder(named: "B", in: try #require(outer.asDirectory))
        let inner = try await fx.store.createFolder(named: "C", in: try #require(middle.asDirectory))
        let before = try fx.snapshot()
        let error = await caught { try await fx.store.move(outer, to: try #require(inner.asDirectory)) }
        #expect(error as? VaultStoreError == .moveIntoItself)
        #expect(try fx.snapshot() == before)
    }

    @Test("A folder with its contents moves into a sibling folder, encrypted files included")
    func moveFolderWithContents() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let source = try await fx.store.createFolder(named: "Source", in: fx.root)
        let target = try await fx.store.createFolder(named: "Target", in: fx.root)
        let sourceDir = try #require(source.asDirectory)
        try await fx.add("inside.txt", "inner data", to: sourceDir)
        try await fx.store.move(source, to: try #require(target.asDirectory))
        let moved = try #require(try await fx.store.findItem(named: "Source", in: try #require(target.asDirectory)))
        let movedDir = try #require(moved.asDirectory)
        let inside = try #require(try await fx.store.findItem(named: "inside.txt", in: movedDir))
        #expect(try await fx.openedContent(inside) == "inner data")
        #expect(try await fx.store.findItem(named: "Source", in: fx.root) == nil)
    }

    @Test("A move that fails leaves the item findable in exactly one place", arguments: [LockMode.none, .password])
    func failedMoveLeavesItemInOnePlace(mode: LockMode) async throws {
        let fx = try VaultStoreFixture(lockMode: mode)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        let item = try await fx.add("a.txt", "data")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: docs.diskURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docs.diskURL.path)
        }
        _ = await caught { try await fx.store.move(item, to: docs) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docs.diskURL.path)
        let inRoot = try await fx.store.findItem(named: "a.txt", in: fx.root)
        let inDocs = try await fx.store.findItem(named: "a.txt", in: docs)
        #expect([inRoot, inDocs].compactMap { $0 }.count == 1)
    }

    // MARK: - copy

    @Test("Copying a plaintext file adds a numbered copy and keeps the original")
    func copyPlaintext() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let item = try await fx.add("a.txt", "data")
        let copy = try await fx.store.copy(item, to: fx.root)
        #expect(copy.name == "a 1.txt")
        #expect(copy.id != item.id)
        #expect(try fx.content(copy.diskURL) == "data")
        #expect(try fx.content(item.diskURL) == "data")
        #expect(try await fx.names() == ["a 1.txt", "a.txt"])
    }

    @Test("Copying into another folder without a conflict keeps the name")
    func copyToOtherFolder() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        let item = try await fx.add("a.txt", "data")
        let copy = try await fx.store.copy(item, to: docs)
        #expect(copy.name == "a.txt")
        #expect(copy.id == "Docs/a.txt")
        #expect(try await fx.names() == ["Docs", "a.txt"])
    }

    @Test("An encrypted copy stays encrypted, has its own file and entry, and decrypts to the same content")
    func copyEncrypted() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let item = try await fx.add("Secret.txt", "same content")
        let first = try await fx.store.copy(item, to: fx.root)
        let second = try await fx.store.copy(item, to: fx.root)
        #expect([first.name, second.name] == ["Secret 1.txt", "Secret 2.txt"])
        #expect(first.isEncrypted && second.isEncrypted)
        #expect(Set([item.id, first.id, second.id]).count == 3)
        let entries = try #require(fx.indexEntries())
        #expect(entries.count == 3)
        #expect(entries[first.id] == "Secret 1.txt")
        for copy in [first, second] {
            #expect(try await fx.openedContent(copy) == "same content")
        }
        #expect(try await fx.openedContent(item) == "same content")
        #expect(!(try fx.diskNames()).contains("Secret 1.txt"))
    }

    @Test("Copying an encrypted file into another folder indexes it there")
    func copyEncryptedToOtherFolder() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        let item = try await fx.add("Secret.txt", "data")
        let copy = try await fx.store.copy(item, to: docs)
        #expect(copy.name == "Secret.txt")
        #expect(fx.indexEntries(in: docs)?.values.sorted() == ["Secret.txt"])
        #expect(fx.indexEntries()?.values.sorted() == ["Secret.txt"])
    }

    // MARK: - rename

    @Test("Renaming a plaintext file renames it on disk")
    func renamePlaintext() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let item = try await fx.add("old.txt", "data")
        let renamed = try await fx.store.rename(item, to: "new.pdf")
        #expect(renamed.name == "new.pdf")
        #expect(renamed.id == "new.pdf")
        #expect(renamed.kind == .pdf)
        #expect(try fx.diskNames() == ["new.pdf"])
        #expect(try fx.content(renamed.diskURL) == "data")
    }

    @Test("Renaming a plaintext folder renames it on disk")
    func renamePlaintextFolder() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let folder = try await fx.store.createFolder(named: "Old", in: fx.root)
        let renamed = try await fx.store.rename(folder, to: "New")
        #expect(renamed.isDirectory)
        #expect(renamed.name == "New")
        #expect(try fx.diskNames() == ["New"])
    }

    @Test("Renaming an encrypted file changes only the index entry")
    func renameEncrypted() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let item = try await fx.add("old.txt", "data")
        let namesOnDisk = try fx.diskNames()
        let renamed = try await fx.store.rename(item, to: "new.pdf")
        #expect(renamed.name == "new.pdf")
        #expect(renamed.id == item.id)
        #expect(renamed.isEncrypted)
        #expect(renamed.kind == .pdf)
        #expect(try fx.diskNames() == namesOnDisk)
        #expect(fx.indexEntries() == [item.id: "new.pdf"])
        #expect(try await fx.names() == ["new.pdf"])
        #expect(try await fx.openedContent(renamed) == "data")
    }
}
