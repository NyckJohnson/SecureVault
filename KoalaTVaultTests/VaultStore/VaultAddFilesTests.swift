import Foundation
import Testing

@testable import KoalaTVault

/// `addFiles(_:to:)`: a batch of files into one folder, the index read and written once per call.
@Suite struct VaultAddFilesTests {
    private func isEncryptFile(_ call: MockFileCipher.Call) -> Bool {
        if case .encryptFile = call { return true }
        return false
    }

    private func isIndexSeal(_ call: MockFileCipher.Call) -> Bool {
        if case .encrypt = call { return true }
        return false
    }

    private func isIndexOpen(_ call: MockFileCipher.Call) -> Bool {
        if case .decrypt = call { return true }
        return false
    }

    private func batch(_ vault: VaultStoreFixture, _ names: [String]) throws -> [VaultFileToAdd] {
        try names.map { VaultFileToAdd(source: try vault.source($0, "content of \($0)"), name: $0) }
    }

    // MARK: - Success

    @Test(
        "addFiles adds the files in order and returns matching items",
        arguments: [LockMode.none, .password])
    func addsInOrder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let files = try batch(vault, ["c.txt", "a.pdf", "b.jpg"])

        let items = try await vault.store.addFiles(files, to: docs)

        #expect(items.map(\.name) == ["c.txt", "a.pdf", "b.jpg"])
        #expect(items.map(\.isDirectory) == [false, false, false])
        #expect(items.map(\.isEncrypted) == Array(repeating: mode != .none, count: 3))
        #expect(items.map(\.kind) == [.text, .pdf, .image])
        for (item, name) in zip(items, ["c.txt", "a.pdf", "b.jpg"]) {
            #expect(item.id.hasPrefix("Docs/"))
            #expect(try await vault.openedContent(item) == "content of \(name)")
        }
        let listed = try await vault.list(docs)
        #expect(Set(listed.map(\.id)) == Set(items.map(\.id)))
        for file in files { #expect(FileManager.default.fileExists(atPath: file.source.path)) }
    }

    @Test("addFiles in plaintext mode copies the files under their names and writes no index")
    func plaintextCopiesWithNames() async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let items = try await vault.store.addFiles(try batch(vault, ["one.txt", "two.txt"]), to: vault.root)

        #expect(try vault.diskNames() == ["one.txt", "two.txt"])
        #expect(items.map(\.id) == ["one.txt", "two.txt"])
        #expect(vault.rawIndex() == nil)
    }

    @Test("addFiles in encrypted mode stores each file encrypted under a new UUID and indexes every entry")
    func encryptedStoresAndIndexes() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")

        let items = try await vault.store.addFiles(try batch(vault, ["a.txt", "b.txt", "c.txt"]), to: docs)

        let diskNames = items.map { ($0.id as NSString).lastPathComponent }
        #expect(diskNames.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(Set(diskNames).count == 3)
        #expect(vault.indexEntries(in: docs) == Dictionary(uniqueKeysWithValues: zip(diskNames, ["a.txt", "b.txt", "c.txt"])))
        #expect(try vault.diskNames(in: docs).sorted() == (diskNames + [".vault_map"]).sorted())
        #expect(vault.cipher.calls.filter(isEncryptFile).count == 3)
        #expect(vault.indexContext(in: docs) != nil)
        #expect(!vault.indexIsPlaintextJSON(in: docs))
    }

    @Test("addFiles keeps the folder's existing index entries")
    func keepsExistingEntries() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let old = try await vault.add("old.txt", "old")

        let items = try await vault.store.addFiles(try batch(vault, ["new.txt"]), to: vault.root)

        let entries = try #require(vault.indexEntries())
        #expect(entries.values.sorted() == ["new.txt", "old.txt"])
        #expect(entries[(old.id as NSString).lastPathComponent] == "old.txt")
        #expect(items.count == 1)
        #expect(try await vault.openedContent(old) == "old")
    }

    // MARK: - Index once per call

    @Test("addFiles in encrypted mode writes the index once and reads it at most once for the whole call")
    func indexWrittenOncePerCall() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("existing.txt")
        let callsBefore = vault.cipher.calls.count
        let names = (0..<10).map { "file\($0).txt" }

        _ = try await vault.store.addFiles(try batch(vault, names), to: vault.root)

        let during = Array(vault.cipher.calls.dropFirst(callsBefore))
        #expect(during.filter(isIndexSeal).count == 1)
        #expect(during.filter(isIndexOpen).count <= 1)
        #expect(during.filter(isEncryptFile).count == 10)
        #expect(vault.indexEntries()?.count == 11)
    }

    @Test("addFiles leaves the index file untouched until the one write (index modified once)")
    func indexFileHasEveryEntryAfterOneCall() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let names = (0..<5).map { "f\($0).txt" }

        _ = try await vault.store.addFiles(try batch(vault, names), to: vault.root)

        #expect(vault.indexEntries()?.values.sorted() == names)
    }

    // MARK: - Names

    @Test(
        "addFiles resolves clashes with the folder and within the call with \" 1\" and \" 2\"",
        arguments: [LockMode.none, .password])
    func nameClashes(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        try await vault.add("a.txt", "existing")

        let items = try await vault.store.addFiles(try batch(vault, ["a.txt", "a.txt", "b.txt", "b.txt"]), to: vault.root)

        #expect(items.map(\.name) == ["a 1.txt", "a 2.txt", "b.txt", "b 1.txt"])
        #expect(try await vault.names().sorted() == ["a 1.txt", "a 2.txt", "a.txt", "b 1.txt", "b.txt"])
    }

    @Test("addFiles keeps names exactly as given, spaces and symbols included", arguments: [LockMode.none, .password])
    func keepsNames(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let names = ["My Photo & More!.jpg", "plain"]
        let items = try await vault.store.addFiles(try batch(vault, names), to: vault.root)
        #expect(items.map(\.name) == names)
    }

    // MARK: - Empty

    @Test("addFiles with an empty list returns [] and writes nothing", arguments: [LockMode.none, .password])
    func emptyList(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        let indexBefore = vault.rawIndex()
        let snapshotBefore = try vault.snapshot()
        let callsBefore = vault.cipher.calls.count

        let items = try await vault.store.addFiles([], to: vault.root)

        #expect(items.isEmpty)
        #expect(vault.rawIndex() == indexBefore)
        #expect(try vault.snapshot() == snapshotBefore)
        #expect(vault.cipher.calls.count == callsBefore)
    }

    @Test("addFiles with an empty list creates no index in an empty folder")
    func emptyListNoIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        _ = try await vault.store.addFiles([], to: vault.root)
        #expect(vault.rawIndex() == nil)
        #expect(try vault.diskNames().isEmpty)
    }

    // MARK: - Failures

    @Test("addFiles with the key missing throws locked and writes nothing")
    func lockedWritesNothing() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, keyLoaded: false)
        defer { vault.cleanUp() }
        let files = try batch(vault, ["a.txt", "b.txt"])
        let before = try vault.snapshot()

        let error = await caught { _ = try await vault.store.addFiles(files, to: vault.root) }

        #expect(error as? VaultStoreError == .locked)
        #expect(try vault.snapshot() == before)
        #expect(try vault.diskNames().isEmpty)
    }

    @Test("addFiles with an empty list and the key missing writes nothing")
    func lockedEmptyListWritesNothing() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, keyLoaded: false)
        defer { vault.cleanUp() }
        let before = try vault.snapshot()
        let error = await caught { _ = try await vault.store.addFiles([], to: vault.root) }
        if let error { #expect(error as? VaultStoreError == .locked) }
        #expect(try vault.snapshot() == before)
    }

    @Test(
        "addFiles with a missing source in the middle throws io, keeps and indexes the earlier files, and skips the later",
        arguments: [LockMode.none, .password])
    func missingSourceInMiddle(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let missing = VaultFileToAdd(
            source: vault.sourcesURL.appendingPathComponent("nope.txt"), name: "nope.txt")
        let files =
            try batch(vault, ["a.txt", "b.txt"]) + [missing] + (try batch(vault, ["d.txt", "e.txt"]))

        let error = await caught { _ = try await vault.store.addFiles(files, to: vault.root) }

        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try await vault.names() == ["a.txt", "b.txt"])
        if mode != .none {
            #expect(vault.indexEntries()?.values.sorted() == ["a.txt", "b.txt"])
            #expect(try vault.diskNames().count == 3)
        } else {
            #expect(try vault.diskNames() == ["a.txt", "b.txt"])
        }
        let kept = try await vault.list()
        for item in kept { #expect(try await vault.openedContent(item) == "content of \(item.name)") }
    }

    @Test("addFiles with a folder as a source throws io and stops there", arguments: [LockMode.none, .password])
    func folderAsSource(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let folderSource = VaultFileToAdd(source: vault.sourcesURL, name: "dir")
        let files = try batch(vault, ["a.txt"]) + [folderSource] + (try batch(vault, ["z.txt"]))

        let error = await caught { _ = try await vault.store.addFiles(files, to: vault.root) }

        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try await vault.names() == ["a.txt"])
    }

    @Test(
        "addFiles with an invalid name throws invalidName, keeps the earlier files and skips the later",
        arguments: [
            (LockMode.none, ""), (LockMode.none, "a/b.txt"),
            (LockMode.password, ""), (LockMode.password, "a/b.txt"),
        ])
    func invalidNameStops(mode: LockMode, badName: String) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let bad = VaultFileToAdd(source: try vault.source("bad.txt"), name: badName)
        let files = try batch(vault, ["a.txt", "b.txt"]) + [bad] + (try batch(vault, ["d.txt"]))

        let error = await caught { _ = try await vault.store.addFiles(files, to: vault.root) }

        #expect(error as? VaultStoreError == .invalidName)
        #expect(try await vault.names() == ["a.txt", "b.txt"])
        if mode != .none { #expect(vault.indexEntries()?.values.sorted() == ["a.txt", "b.txt"]) }
    }

    @Test("addFiles whose encryption fails on a file throws, keeping the earlier files indexed")
    func encryptionFailsMidway() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, selective: true)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let files = try batch(vault, ["a.txt", "b.txt", "c.txt"])
        // Fail only for the third file by failing every encryptFile once two have gone through.
        let first = try await vault.store.addFiles([files[0]], to: vault.root)
        #expect(first.count == 1)
        failing.encryptFileError = VaultCryptoError.encryptionFailed

        let error = await caught { _ = try await vault.store.addFiles(Array(files[1...]), to: vault.root) }

        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try await vault.names() == ["a.txt"])
        #expect(vault.indexEntries()?.values.sorted() == ["a.txt"])
        #expect(try vault.diskNames().count == 2)
    }

    @Test(
        "addFiles whose index write fails removes every file the call encrypted and throws",
        arguments: VaultFileOperationsFailureTests.SealFailure.allCases)
    func indexWriteFailureCleansUp(failure: VaultFileOperationsFailureTests.SealFailure) async throws {
        let vault = try VaultStoreFixture(lockMode: .password, selective: true)
        defer { vault.cleanUp() }
        let existing = try await vault.add("old.txt", "old")
        let indexBefore = vault.rawIndex()
        let diskBefore = try vault.diskNames()
        let failing = try #require(vault.failing)
        failing.encryptError = failure.cryptoError
        let files = try batch(vault, ["a.txt", "b.txt", "c.txt"])

        let error = await caught { _ = try await vault.store.addFiles(files, to: vault.root) }

        #expect(failure.matches(error), "unexpected error \(String(describing: error))")
        #expect(try vault.diskNames() == diskBefore)
        #expect(vault.rawIndex() == indexBefore)
        failing.encryptError = nil
        #expect(try await vault.names() == ["old.txt"])
        #expect(try await vault.openedContent(existing) == "old")
    }

    @Test("addFiles whose index write fails in an empty folder leaves the folder empty")
    func indexWriteFailureEmptyFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, selective: true)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        failing.encryptError = VaultCryptoError.encryptionFailed
        let files = try batch(vault, ["a.txt", "b.txt"])

        let error = await caught { _ = try await vault.store.addFiles(files, to: vault.root) }

        #expect(isIOError(error))
        #expect(try vault.diskNames().isEmpty)
    }

    @Test("addFiles into an unreadable index throws indexUnreadable and never overwrites it")
    func unreadableIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.writeRawIndex(Data("garbage".utf8))
        let files = try batch(vault, ["a.txt"])

        let error = await caught { _ = try await vault.store.addFiles(files, to: vault.root) }

        #expect(isIndexUnreadable(error))
        #expect(vault.rawIndex() == Data("garbage".utf8))
        #expect(try vault.diskNames() == [".vault_map"])
    }
}
