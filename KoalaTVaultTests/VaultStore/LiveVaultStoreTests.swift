import Foundation
import Testing

@testable import KoalaTVault

@Suite struct LiveVaultStoreTests {
    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    // MARK: - Root

    @Test("The root directory is named KoalaTVault and points at the injected vault folder")
    func rootDirectory() throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let root = vault.store.root
        #expect(root.name == "KoalaTVault")
        #expect(resolved(root.diskURL) == resolved(vault.rootURL))
        #expect(resolved(root.rootURL) == resolved(vault.rootURL))
    }

    // MARK: - Encrypted-mode rule and .locked

    enum LockedOperation: String, CaseIterable, Sendable {
        case contents, open, write, createDocument, addFile, findItem, move, copy, rename
    }

    @Test(
        "Encrypted mode without a key throws locked and changes nothing",
        arguments: LockedOperation.allCases, [LockMode.password, .passwordAndBiometrics])
    func lockedThrowsAndChangesNothing(operation: LockedOperation, mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let encrypted = try await vault.add("secret.txt", "secret")
        let source = try vault.source("incoming.txt", "incoming")
        vault.keys.wipeKey()
        let before = try vault.snapshot()

        let error = await caught {
            switch operation {
            case .contents: _ = try await vault.list()
            case .open: _ = try await vault.store.open(encrypted)
            case .write: try await vault.store.write(Data("new".utf8), to: encrypted)
            case .createDocument: _ = try await vault.store.createDocument(named: "Doc", in: vault.root)
            case .addFile: _ = try await vault.store.addFile(from: source, named: "incoming.txt", to: vault.root)
            case .findItem: _ = try await vault.store.findItem(named: "secret.txt", in: vault.root)
            case .move: try await vault.store.move(encrypted, to: docs)
            case .copy: _ = try await vault.store.copy(encrypted, to: docs)
            case .rename: _ = try await vault.store.rename(encrypted, to: "renamed.txt")
            }
        }
        #expect(error as? VaultStoreError == .locked)
        #expect(try vault.snapshot() == before)
    }

    @Test("A key wipe never makes the store write plaintext: the import is refused")
    func wipedKeyNeverWritesPlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("first.txt")
        let indexBefore = vault.rawIndex()
        vault.keys.wipeKey()
        let error = await caught { _ = try await vault.add("second.txt") }
        #expect(error as? VaultStoreError == .locked)
        #expect(vault.rawIndex() == indexBefore)
        #expect(!(try vault.diskNames()).contains("second.txt"))
    }

    @Test("Plaintext mode needs no key")
    func plaintextModeWorksWithoutKey() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "hello")
        #expect(item.isEncrypted == false)
        #expect(try vault.diskNames() == ["a.txt"])
        #expect(try await vault.names() == ["a.txt"])
        #expect(try await vault.store.findItem(named: "a.txt", in: vault.root) != nil)
    }

    @Test("The lock mode is read from preferences at the start of each operation")
    func lockModeReadPerOperation() async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let plain = try await vault.add("plain.txt")
        #expect(plain.isEncrypted == false)
        vault.prefs.lockMode = .password
        let encrypted = try await vault.add("secret.txt")
        #expect(encrypted.isEncrypted)
        #expect(try vault.diskNames().contains("plain.txt"))
        #expect(!(try vault.diskNames()).contains("secret.txt"))
        vault.prefs.lockMode = .passwordAndBiometrics
        let third = try await vault.add("third.txt")
        #expect(third.isEncrypted)
    }

    @Test("An operation captures the key at most once")
    func keyCapturedOncePerOperation() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let source = try vault.source("a.txt")
        let before = vault.keys.calls.filter { $0 == .withKey }.count
        _ = try await vault.store.addFile(from: source, named: "a.txt", to: vault.root)
        let captures = vault.keys.calls.filter { $0 == .withKey }.count - before
        #expect(captures <= 1)
    }

    // MARK: - contents

    @Test("Hidden entries are never listed")
    func hiddenEntriesNotListed() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.diskFile("visible.txt")
        try vault.diskFile(".trash_map")
        try vault.writeIndex([:], context: nil)
        try vault.folder(".trash")
        #expect(try await vault.names() == ["visible.txt"])
    }

    @Test("Mapped files show their original name and are encrypted; unmapped files and folders show the disk name")
    func mappedAndUnmappedNames() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let uuid = "11111111-2222-3333-4444-555555555555"
        try vault.diskFile(uuid, "secret")
        try vault.diskFile("stray.txt", "plain")
        try vault.folder("Docs")
        try vault.writeIndex([uuid: "Original.pdf"], context: ".vault_map")
        let items = try await vault.list()
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Original.pdf", "stray.txt", "Docs"])
        #expect(byName["Original.pdf"]?.isEncrypted == true)
        #expect(byName["Original.pdf"]?.id == uuid)
        #expect(byName["Original.pdf"]?.kind == .pdf)
        #expect(byName["stray.txt"]?.isEncrypted == false)
        #expect(byName["Docs"]?.isEncrypted == false)
        #expect(byName["Docs"]?.isDirectory == true)
    }

    @Test("Files report their size and folders have no size; the modified date comes from disk")
    func sizeAndDate() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let url = try vault.diskFile("five.txt", "12345")
        try vault.folder("Dir")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try vault.setModified(url, to: date)
        let items = try await vault.list()
        let file = try #require(items.first { $0.name == "five.txt" })
        let dir = try #require(items.first { $0.name == "Dir" })
        #expect(file.fileSize == 5)
        #expect(abs(file.dateModified.timeIntervalSince(date)) < 1)
        #expect(dir.fileSize == nil)
        #expect(file.deletedAt == nil)
        #expect(file.isDirectory == false)
    }

    @Test("Ids are root-relative paths and equal across listings")
    func stableRootRelativeIds() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let deeper = try vault.folder("Deep", in: docs)
        try vault.diskFile("top.txt")
        try vault.diskFile("inner.txt", in: docs)
        try vault.diskFile("bottom.txt", in: deeper)
        let rootFirst = try await vault.list()
        let rootSecond = try await vault.list()
        #expect(rootFirst.map(\.id) == rootSecond.map(\.id))
        #expect(Set(rootFirst.map(\.id)) == ["Docs", "top.txt"])
        #expect(try await vault.list(docs).map(\.id).sorted() == ["Docs/Deep", "Docs/inner.txt"])
        #expect(try await vault.list(deeper).map(\.id) == ["Docs/Deep/bottom.txt"])
    }

    @Test("An encrypted file's id is its UUID disk path")
    func encryptedIdIsDiskPath() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("secret.txt", to: docs)
        let listed = try #require(try await vault.list(docs).first)
        #expect(listed.id == item.id)
        #expect(item.id.hasPrefix("Docs/"))
        #expect(!item.id.contains("secret"))
        #expect(item.name == "secret.txt")
    }

    @Test("Items carry the vault root and their disk URL")
    func itemsCarryURLs() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile("a.txt", in: docs)
        let item = try #require(try await vault.list(docs).first)
        #expect(resolved(item.rootURL) == resolved(vault.rootURL))
        #expect(resolved(item.diskURL) == resolved(docs.diskURL.appendingPathComponent("a.txt")))
    }

    @Test("An empty folder lists nothing")
    func emptyFolder() async throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        #expect(try await vault.list().isEmpty)
    }

    // MARK: Sorting

    private func sortedFixture() throws -> VaultStoreFixture {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        try vault.folder("alpha")
        try vault.folder("Zeta")
        try vault.diskFile("apple.pdf")
        try vault.diskFile("Banana.txt")
        try vault.diskFile("cherry.jpg")
        return vault
    }

    @Test("Name ascending is case-insensitive with folders first")
    func nameAscending() async throws {
        let vault = try sortedFixture()
        defer { vault.cleanUp() }
        #expect(
            try await vault.names(nil, .name, .ascending) == ["alpha", "Zeta", "apple.pdf", "Banana.txt", "cherry.jpg"])
    }

    @Test("Name descending reverses the order within folders and files, folders still first")
    func nameDescending() async throws {
        let vault = try sortedFixture()
        defer { vault.cleanUp() }
        let names = try await vault.names(nil, .name, .descending)
        #expect(names == ["Zeta", "alpha", "cherry.jpg", "Banana.txt", "apple.pdf"])
    }

    @Test("Type ascending orders by extension, then by name")
    func typeAscending() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        for name in ["b.pdf", "a.txt", "c.jpg", "a.jpg"] { try vault.diskFile(name) }
        try vault.folder("Dir")
        #expect(try await vault.names(nil, .type, .ascending) == ["Dir", "a.jpg", "c.jpg", "b.pdf", "a.txt"])
    }

    @Test("Type descending orders by extension in reverse, folders still first")
    func typeDescending() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        for name in ["b.pdf", "a.txt", "c.jpg", "a.jpg"] { try vault.diskFile(name) }
        try vault.folder("Dir")
        let names = try await vault.names(nil, .type, .descending)
        #expect(names.first == "Dir")
        #expect(names.dropFirst().map { ($0 as NSString).pathExtension } == ["txt", "pdf", "jpg", "jpg"])
    }

    @Test("Date modified ascending and descending, folders first in both")
    func dateModifiedOrder() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let now = Date()
        let oldFile = try vault.diskFile("old.txt")
        let midFile = try vault.diskFile("mid.txt")
        let newFile = try vault.diskFile("new.txt")
        let folder = try vault.folder("Newest")
        try vault.setModified(oldFile, to: now.addingTimeInterval(-3_000))
        try vault.setModified(midFile, to: now.addingTimeInterval(-2_000))
        try vault.setModified(newFile, to: now.addingTimeInterval(-1_000))
        try vault.setModified(folder.diskURL, to: now)
        #expect(try await vault.names(nil, .dateModified, .ascending) == ["Newest", "old.txt", "mid.txt", "new.txt"])
        #expect(try await vault.names(nil, .dateModified, .descending) == ["Newest", "new.txt", "mid.txt", "old.txt"])
    }

    @Test("Sorting uses the original names of encrypted files, not their disk names")
    func sortUsesDisplayNames() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let first = "ZZZZZZZZ-0000-0000-0000-000000000001"
        let second = "AAAAAAAA-0000-0000-0000-000000000002"
        try vault.diskFile(first)
        try vault.diskFile(second)
        try vault.writeIndex([first: "a.txt", second: "b.txt"], context: ".vault_map")
        #expect(try await vault.names(nil, .name, .ascending) == ["a.txt", "b.txt"])
        #expect(try await vault.names(nil, .name, .descending) == ["b.txt", "a.txt"])
    }

    // MARK: - open

    @Test("Opening a plaintext item returns its disk URL")
    func openPlaintextReturnsDiskURL() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.diskFile("a.txt", "hello")
        let item = try #require(try await vault.list().first)
        let url = try await vault.store.open(item)
        #expect(resolved(url) == resolved(item.diskURL))
        #expect(try vault.content(url) == "hello")
        #expect(vault.tempFiles().isEmpty)
    }

    @Test("Opening an encrypted item decrypts into a new temp folder as <temp>/<name>")
    func openEncryptedDecryptsToTemp() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("Report.pdf", "pdf bytes")
        let url = try await vault.store.open(item)
        #expect(url.lastPathComponent == "Report.pdf")
        #expect(resolved(url).hasPrefix(resolved(vault.tempRoot)))
        #expect(resolved(url.deletingLastPathComponent()) != resolved(vault.tempRoot))
        #expect(try vault.content(url) == "pdf bytes")
        #expect(vault.cipher.calls.contains { if case .decryptFile = $0 { return true } else { return false } })
    }

    @Test("Each open of an encrypted item uses its own temp folder")
    func openTwiceUsesDistinctFolders() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        let first = try await vault.store.open(item)
        let second = try await vault.store.open(item)
        #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
    }

    @Test("A failed open leaves no temp file and throws io")
    func failedOpenLeavesNoTempFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        try FileManager.default.removeItem(at: item.diskURL)
        let error = await caught { _ = try await vault.store.open(item) }
        let storeError = try #require(error as? VaultStoreError)
        switch storeError {
        case .io, .notFound: break
        default: Issue.record("expected io, got \(storeError)")
        }
        #expect(vault.tempFiles().isEmpty)
    }

    @Test("Opening an encrypted item without a key throws locked and leaves no temp file")
    func openLockedLeavesNoTempFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        vault.keys.wipeKey()
        let error = await caught { _ = try await vault.store.open(item) }
        #expect(error as? VaultStoreError == .locked)
        #expect(vault.tempFiles().isEmpty)
    }

    // MARK: - write

    @Test("Writing a plaintext item replaces its content")
    func writePlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.diskFile("a.txt", "old")
        let item = try #require(try await vault.list().first)
        try await vault.store.write(Data("new content".utf8), to: item)
        #expect(try vault.content(item.diskURL) == "new content")
        #expect(try vault.diskNames() == ["a.txt"])
    }

    @Test("Writing an encrypted item keeps its file and index entry, changes its content, and leaves no plaintext")
    func writeEncrypted() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("note.txt", "old")
        let indexBefore = vault.indexEntries()
        try await vault.store.write(Data("replacement".utf8), to: item)
        #expect(vault.indexEntries() == indexBefore)
        #expect(vault.tempFiles().isEmpty)
        #expect(try await vault.openedContent(item) == "replacement")
        #expect(try await vault.names() == ["note.txt"])
        #expect(vault.cipher.calls.contains { if case .encryptFile = $0 { return true } else { return false } })
        #expect(try vault.diskNames().filter { $0 != ".vault_map" } == [item.id])
    }

    @Test("Writing an encrypted item without a key throws locked and leaves the file unchanged")
    func writeLockedUnchanged() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("note.txt", "old")
        let before = try Data(contentsOf: item.diskURL)
        vault.keys.wipeKey()
        let error = await caught { try await vault.store.write(Data("new".utf8), to: item) }
        #expect(error as? VaultStoreError == .locked)
        #expect(try Data(contentsOf: item.diskURL) == before)
    }

    @Test("Writing empty data to a plaintext item empties it")
    func writeEmptyData() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.diskFile("a.txt", "old")
        let item = try #require(try await vault.list().first)
        try await vault.store.write(Data(), to: item)
        #expect(try vault.content(item.diskURL).isEmpty)
    }

    // MARK: - findItem

    @Test("findItem finds a plaintext item by name")
    func findPlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.diskFile("a.txt")
        let found = try await vault.store.findItem(named: "a.txt", in: vault.root)
        #expect(found?.name == "a.txt")
        #expect(found?.id == "a.txt")
    }

    @Test("findItem finds an encrypted item by its original name, not its UUID")
    func findEncryptedByDisplayName() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let added = try await vault.add("Secret.txt")
        let found = try await vault.store.findItem(named: "Secret.txt", in: vault.root)
        #expect(found?.id == added.id)
        #expect(found?.isEncrypted == true)
        #expect(try await vault.store.findItem(named: added.id, in: vault.root) == nil)
    }

    @Test("findItem returns nil for a missing name and only searches the given folder")
    func findMissing() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try vault.diskFile("inner.txt", in: docs)
        #expect(try await vault.store.findItem(named: "missing.txt", in: vault.root) == nil)
        #expect(try await vault.store.findItem(named: "inner.txt", in: vault.root) == nil)
        #expect(try await vault.store.findItem(named: "inner.txt", in: docs) != nil)
    }

    @Test("findItem finds a folder by name")
    func findFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        try vault.folder("Docs")
        let found = try await vault.store.findItem(named: "Docs", in: vault.root)
        #expect(found?.isDirectory == true)
    }
}
