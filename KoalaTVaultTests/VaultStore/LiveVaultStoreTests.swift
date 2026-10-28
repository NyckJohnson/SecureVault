import Foundation
import Testing

@testable import KoalaTVault

@Suite struct LiveVaultStoreTests {
    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    // MARK: - Root

    @Test("The root directory is named KoalaTVault and points at the injected vault folder")
    func rootDirectory() throws {
        let fx = try VaultStoreFixture()
        defer { fx.cleanUp() }
        let root = fx.store.root
        #expect(root.name == "KoalaTVault")
        #expect(resolved(root.diskURL) == resolved(fx.rootURL))
        #expect(resolved(root.rootURL) == resolved(fx.rootURL))
    }

    // MARK: - Encrypted-mode rule and .locked

    enum LockedOperation: String, CaseIterable, Sendable {
        case contents, open, write, createDocument, addFile, findItem, move, copy, rename
    }

    @Test(
        "Encrypted mode without a key throws locked and changes nothing",
        arguments: LockedOperation.allCases, [LockMode.password, .passwordAndBiometrics])
    func lockedThrowsAndChangesNothing(operation: LockedOperation, mode: LockMode) async throws {
        let fx = try VaultStoreFixture(lockMode: mode)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        let encrypted = try await fx.add("secret.txt", "secret")
        let source = try fx.source("incoming.txt", "incoming")
        fx.keys.wipeKey()
        let before = try fx.snapshot()

        let error = await caught {
            switch operation {
            case .contents: _ = try await fx.list()
            case .open: _ = try await fx.store.open(encrypted)
            case .write: try await fx.store.write(Data("new".utf8), to: encrypted)
            case .createDocument: _ = try await fx.store.createDocument(named: "Doc", in: fx.root)
            case .addFile: _ = try await fx.store.addFile(from: source, named: "incoming.txt", to: fx.root)
            case .findItem: _ = try await fx.store.findItem(named: "secret.txt", in: fx.root)
            case .move: try await fx.store.move(encrypted, to: docs)
            case .copy: _ = try await fx.store.copy(encrypted, to: docs)
            case .rename: _ = try await fx.store.rename(encrypted, to: "renamed.txt")
            }
        }
        #expect(error as? VaultStoreError == .locked)
        #expect(try fx.snapshot() == before)
    }

    @Test("A key wipe never makes the store write plaintext: the import is refused")
    func wipedKeyNeverWritesPlaintext() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        try await fx.add("first.txt")
        let indexBefore = fx.rawIndex()
        fx.keys.wipeKey()
        let error = await caught { _ = try await fx.add("second.txt") }
        #expect(error as? VaultStoreError == .locked)
        #expect(fx.rawIndex() == indexBefore)
        #expect(!(try fx.diskNames()).contains("second.txt"))
    }

    @Test("Plaintext mode needs no key")
    func plaintextModeWorksWithoutKey() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let item = try await fx.add("a.txt", "hello")
        #expect(item.isEncrypted == false)
        #expect(try fx.diskNames() == ["a.txt"])
        #expect(try await fx.names() == ["a.txt"])
        #expect(try await fx.store.findItem(named: "a.txt", in: fx.root) != nil)
    }

    @Test("The lock mode is read from preferences at the start of each operation")
    func lockModeReadPerOperation() async throws {
        let fx = try VaultStoreFixture(lockMode: .none)
        defer { fx.cleanUp() }
        let plain = try await fx.add("plain.txt")
        #expect(plain.isEncrypted == false)
        fx.prefs.lockMode = .password
        let encrypted = try await fx.add("secret.txt")
        #expect(encrypted.isEncrypted)
        #expect(try fx.diskNames().contains("plain.txt"))
        #expect(!(try fx.diskNames()).contains("secret.txt"))
        fx.prefs.lockMode = .passwordAndBiometrics
        let third = try await fx.add("third.txt")
        #expect(third.isEncrypted)
    }

    @Test("An operation captures the key at most once")
    func keyCapturedOncePerOperation() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let source = try fx.source("a.txt")
        let before = fx.keys.calls.filter { $0 == .withKey }.count
        _ = try await fx.store.addFile(from: source, named: "a.txt", to: fx.root)
        let captures = fx.keys.calls.filter { $0 == .withKey }.count - before
        #expect(captures <= 1)
    }

    // MARK: - contents

    @Test("Hidden entries are never listed")
    func hiddenEntriesNotListed() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        try fx.diskFile("visible.txt")
        try fx.diskFile(".trash_map")
        try fx.diskFile(".vault_map")
        try fx.folder(".trash")
        #expect(try await fx.names() == ["visible.txt"])
    }

    @Test("Mapped files show their original name and are encrypted; unmapped files and folders show the disk name")
    func mappedAndUnmappedNames() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let uuid = "11111111-2222-3333-4444-555555555555"
        try fx.diskFile(uuid, "secret")
        try fx.diskFile("stray.txt", "plain")
        try fx.folder("Docs")
        try fx.writeIndex([uuid: "Original.pdf"], context: ".vault_map")
        let items = try await fx.list()
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
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let url = try fx.diskFile("five.txt", "12345")
        try fx.folder("Dir")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try fx.setModified(url, to: date)
        let items = try await fx.list()
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
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        let deeper = try fx.folder("Deep", in: docs)
        try fx.diskFile("top.txt")
        try fx.diskFile("inner.txt", in: docs)
        try fx.diskFile("bottom.txt", in: deeper)
        let rootFirst = try await fx.list()
        let rootSecond = try await fx.list()
        #expect(rootFirst.map(\.id) == rootSecond.map(\.id))
        #expect(Set(rootFirst.map(\.id)) == ["Docs", "top.txt"])
        #expect(try await fx.list(docs).map(\.id).sorted() == ["Docs/Deep", "Docs/inner.txt"])
        #expect(try await fx.list(deeper).map(\.id) == ["Docs/Deep/bottom.txt"])
    }

    @Test("An encrypted file's id is its UUID disk path")
    func encryptedIdIsDiskPath() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        let item = try await fx.add("secret.txt", to: docs)
        let listed = try #require(try await fx.list(docs).first)
        #expect(listed.id == item.id)
        #expect(item.id.hasPrefix("Docs/"))
        #expect(!item.id.contains("secret"))
        #expect(item.name == "secret.txt")
    }

    @Test("Items carry the vault root and their disk URL")
    func itemsCarryURLs() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        try fx.diskFile("a.txt", in: docs)
        let item = try #require(try await fx.list(docs).first)
        #expect(resolved(item.rootURL) == resolved(fx.rootURL))
        #expect(resolved(item.diskURL) == resolved(docs.diskURL.appendingPathComponent("a.txt")))
    }

    @Test("An empty folder lists nothing")
    func emptyFolder() async throws {
        let fx = try VaultStoreFixture()
        defer { fx.cleanUp() }
        #expect(try await fx.list().isEmpty)
    }

    // MARK: Sorting

    private func sortedFixture() throws -> VaultStoreFixture {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        try fx.folder("alpha")
        try fx.folder("Zeta")
        try fx.diskFile("apple.pdf")
        try fx.diskFile("Banana.txt")
        try fx.diskFile("cherry.jpg")
        return fx
    }

    @Test("Name ascending is case-insensitive with folders first")
    func nameAscending() async throws {
        let fx = try sortedFixture()
        defer { fx.cleanUp() }
        #expect(try await fx.names(nil, .name, .ascending) == ["alpha", "Zeta", "apple.pdf", "Banana.txt", "cherry.jpg"])
    }

    @Test("Name descending reverses the order within folders and files, folders still first")
    func nameDescending() async throws {
        let fx = try sortedFixture()
        defer { fx.cleanUp() }
        #expect(try await fx.names(nil, .name, .descending) == ["Zeta", "alpha", "cherry.jpg", "Banana.txt", "apple.pdf"])
    }

    @Test("Type ascending orders by extension, then by name")
    func typeAscending() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        for name in ["b.pdf", "a.txt", "c.jpg", "a.jpg"] { try fx.diskFile(name) }
        try fx.folder("Dir")
        #expect(try await fx.names(nil, .type, .ascending) == ["Dir", "a.jpg", "c.jpg", "b.pdf", "a.txt"])
    }

    @Test("Type descending orders by extension in reverse, folders still first")
    func typeDescending() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        for name in ["b.pdf", "a.txt", "c.jpg", "a.jpg"] { try fx.diskFile(name) }
        try fx.folder("Dir")
        let names = try await fx.names(nil, .type, .descending)
        #expect(names.first == "Dir")
        #expect(names.dropFirst().map { ($0 as NSString).pathExtension } == ["txt", "pdf", "jpg", "jpg"])
    }

    @Test("Date modified ascending and descending, folders first in both")
    func dateModifiedOrder() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let now = Date()
        let oldFile = try fx.diskFile("old.txt")
        let midFile = try fx.diskFile("mid.txt")
        let newFile = try fx.diskFile("new.txt")
        let folder = try fx.folder("Newest")
        try fx.setModified(oldFile, to: now.addingTimeInterval(-3_000))
        try fx.setModified(midFile, to: now.addingTimeInterval(-2_000))
        try fx.setModified(newFile, to: now.addingTimeInterval(-1_000))
        try fx.setModified(folder.diskURL, to: now)
        #expect(try await fx.names(nil, .dateModified, .ascending) == ["Newest", "old.txt", "mid.txt", "new.txt"])
        #expect(try await fx.names(nil, .dateModified, .descending) == ["Newest", "new.txt", "mid.txt", "old.txt"])
    }

    @Test("Sorting uses the original names of encrypted files, not their disk names")
    func sortUsesDisplayNames() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let first = "ZZZZZZZZ-0000-0000-0000-000000000001"
        let second = "AAAAAAAA-0000-0000-0000-000000000002"
        try fx.diskFile(first)
        try fx.diskFile(second)
        try fx.writeIndex([first: "a.txt", second: "b.txt"], context: ".vault_map")
        #expect(try await fx.names(nil, .name, .ascending) == ["a.txt", "b.txt"])
        #expect(try await fx.names(nil, .name, .descending) == ["b.txt", "a.txt"])
    }

    // MARK: - open

    @Test("Opening a plaintext item returns its disk URL")
    func openPlaintextReturnsDiskURL() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        try fx.diskFile("a.txt", "hello")
        let item = try #require(try await fx.list().first)
        let url = try await fx.store.open(item)
        #expect(resolved(url) == resolved(item.diskURL))
        #expect(try fx.content(url) == "hello")
        #expect(fx.tempFiles().isEmpty)
    }

    @Test("Opening an encrypted item decrypts into a new temp folder as <temp>/<name>")
    func openEncryptedDecryptsToTemp() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let item = try await fx.add("Report.pdf", "pdf bytes")
        let url = try await fx.store.open(item)
        #expect(url.lastPathComponent == "Report.pdf")
        #expect(resolved(url).hasPrefix(resolved(fx.tempRoot)))
        #expect(resolved(url.deletingLastPathComponent()) != resolved(fx.tempRoot))
        #expect(try fx.content(url) == "pdf bytes")
        #expect(fx.cipher.calls.contains { if case .decryptFile = $0 { return true } else { return false } })
    }

    @Test("Each open of an encrypted item uses its own temp folder")
    func openTwiceUsesDistinctFolders() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let item = try await fx.add("a.txt")
        let first = try await fx.store.open(item)
        let second = try await fx.store.open(item)
        #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
    }

    @Test("A failed open leaves no temp file and throws io")
    func failedOpenLeavesNoTempFile() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let item = try await fx.add("a.txt")
        try FileManager.default.removeItem(at: item.diskURL)
        let error = await caught { _ = try await fx.store.open(item) }
        let storeError = try #require(error as? VaultStoreError)
        switch storeError {
        case .io, .notFound: break
        default: Issue.record("expected io, got \(storeError)")
        }
        #expect(fx.tempFiles().isEmpty)
    }

    @Test("Opening an encrypted item without a key throws locked and leaves no temp file")
    func openLockedLeavesNoTempFile() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let item = try await fx.add("a.txt")
        fx.keys.wipeKey()
        let error = await caught { _ = try await fx.store.open(item) }
        #expect(error as? VaultStoreError == .locked)
        #expect(fx.tempFiles().isEmpty)
    }

    // MARK: - write

    @Test("Writing a plaintext item replaces its content")
    func writePlaintext() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        try fx.diskFile("a.txt", "old")
        let item = try #require(try await fx.list().first)
        try await fx.store.write(Data("new content".utf8), to: item)
        #expect(try fx.content(item.diskURL) == "new content")
        #expect(try fx.diskNames() == ["a.txt"])
    }

    @Test("Writing an encrypted item keeps its file and index entry, changes its content, and leaves no plaintext")
    func writeEncrypted() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let item = try await fx.add("note.txt", "old")
        let indexBefore = fx.indexEntries()
        try await fx.store.write(Data("replacement".utf8), to: item)
        #expect(fx.indexEntries() == indexBefore)
        #expect(fx.tempFiles().isEmpty)
        #expect(try await fx.openedContent(item) == "replacement")
        #expect(try await fx.names() == ["note.txt"])
        #expect(fx.cipher.calls.contains { if case .encryptFile = $0 { return true } else { return false } })
        #expect(try fx.diskNames().filter { $0 != ".vault_map" } == [item.id])
    }

    @Test("Writing an encrypted item without a key throws locked and leaves the file unchanged")
    func writeLockedUnchanged() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let item = try await fx.add("note.txt", "old")
        let before = try Data(contentsOf: item.diskURL)
        fx.keys.wipeKey()
        let error = await caught { try await fx.store.write(Data("new".utf8), to: item) }
        #expect(error as? VaultStoreError == .locked)
        #expect(try Data(contentsOf: item.diskURL) == before)
    }

    @Test("Writing empty data to a plaintext item empties it")
    func writeEmptyData() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        try fx.diskFile("a.txt", "old")
        let item = try #require(try await fx.list().first)
        try await fx.store.write(Data(), to: item)
        #expect(try fx.content(item.diskURL).isEmpty)
    }

    // MARK: - findItem

    @Test("findItem finds a plaintext item by name")
    func findPlaintext() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        try fx.diskFile("a.txt")
        let found = try await fx.store.findItem(named: "a.txt", in: fx.root)
        #expect(found?.name == "a.txt")
        #expect(found?.id == "a.txt")
    }

    @Test("findItem finds an encrypted item by its original name, not its UUID")
    func findEncryptedByDisplayName() async throws {
        let fx = try VaultStoreFixture(lockMode: .password)
        defer { fx.cleanUp() }
        let added = try await fx.add("Secret.txt")
        let found = try await fx.store.findItem(named: "Secret.txt", in: fx.root)
        #expect(found?.id == added.id)
        #expect(found?.isEncrypted == true)
        #expect(try await fx.store.findItem(named: added.id, in: fx.root) == nil)
    }

    @Test("findItem returns nil for a missing name and only searches the given folder")
    func findMissing() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        let docs = try fx.folder("Docs")
        try fx.diskFile("inner.txt", in: docs)
        #expect(try await fx.store.findItem(named: "missing.txt", in: fx.root) == nil)
        #expect(try await fx.store.findItem(named: "inner.txt", in: fx.root) == nil)
        #expect(try await fx.store.findItem(named: "inner.txt", in: docs) != nil)
    }

    @Test("findItem finds a folder by name")
    func findFolder() async throws {
        let fx = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { fx.cleanUp() }
        try fx.folder("Docs")
        let found = try await fx.store.findItem(named: "Docs", in: fx.root)
        #expect(found?.isDirectory == true)
    }
}
