import Foundation
import Testing

@testable import KoalaTVault

/// `remove(_:)`: deletes an item (a folder with its whole tree) for good, never into the trash.
@Suite struct VaultRemoveTests {
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// An item that isn't on the disk.
    private func ghost(_ vault: VaultStoreFixture, encrypted: Bool) -> VaultItem {
        VaultItem(
            id: "ghost.txt", name: "ghost.txt", isDirectory: false, dateModified: Date(), fileSize: 1,
            deletedAt: nil, diskURL: vault.rootURL.appendingPathComponent("ghost.txt"), rootURL: vault.rootURL,
            isEncrypted: encrypted)
    }

    // MARK: - Files

    @Test("remove of an encrypted file deletes the file and its index entry, leaving the others")
    func removeEncryptedFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let doomed = try await vault.add("doomed.txt", "bye")
        let kept = try await vault.add("kept.txt", "stay")

        try await vault.store.remove(doomed)

        #expect(!exists(doomed.diskURL))
        #expect(exists(kept.diskURL))
        #expect(vault.indexEntries()?.values.sorted() == ["kept.txt"])
        #expect(try await vault.names() == ["kept.txt"])
        #expect(try await vault.openedContent(kept) == "stay")
    }

    @Test("remove of an encrypted file whose index entry is already gone just deletes the file")
    func removeStaleEncryptedFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let stale = try await vault.add("stale.txt", "old", to: docs)
        let kept = try await vault.add("kept.txt", "stay", to: docs)
        let context = try #require(vault.indexContext(in: docs))
        let keptEntry = [kept.diskURL.lastPathComponent: "kept.txt"]
        try vault.writeIndex(keptEntry, in: docs, context: context)

        try await vault.store.remove(stale)

        #expect(!exists(stale.diskURL))
        #expect(exists(kept.diskURL))
        #expect(vault.indexEntries(in: docs) == keptEntry)
        #expect(try await vault.names(docs) == ["kept.txt"])
        #expect(try await vault.openedContent(kept) == "stay")
    }

    @Test("remove of the only encrypted file leaves no entry for it and an empty listing")
    func removeOnlyEncryptedFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let doomed = try await vault.add("doomed.txt", "bye")

        try await vault.store.remove(doomed)

        #expect(!exists(doomed.diskURL))
        #expect(vault.indexEntries()?.isEmpty ?? true)
        #expect(try await vault.list().isEmpty)
    }

    @Test("remove of an encrypted file in a subfolder deletes it and its entry in that folder's index")
    func removeEncryptedFileInSubfolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let doomed = try await vault.add("doomed.txt", "bye", to: docs)
        let kept = try await vault.add("kept.txt", "stay", to: docs)

        try await vault.store.remove(doomed)

        #expect(!exists(doomed.diskURL))
        #expect(vault.indexEntries(in: docs)?.values.sorted() == ["kept.txt"])
        #expect(try await vault.names(docs) == ["kept.txt"])
        #expect(try await vault.openedContent(kept) == "stay")
    }

    @Test("remove of a plaintext file deletes the file")
    func removePlaintextFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let doomed = try await vault.add("doomed.txt", "bye")
        let kept = try await vault.add("kept.txt", "stay")

        try await vault.store.remove(doomed)

        #expect(!exists(doomed.diskURL))
        #expect(exists(kept.diskURL))
        #expect(try await vault.names() == ["kept.txt"])
    }

    // MARK: - Folders

    @Test("remove of a plaintext folder deletes its whole nested tree and the folder", arguments: [false, true])
    func removePlaintextFolderTree(nested: Bool) async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let top = try vault.folder("Top")
        let inner = try vault.folder("Inner", in: top)
        try await vault.add("a.txt", "a", to: top)
        if nested { try await vault.add("b.txt", "b", to: inner) }
        try await vault.add("keep.txt", "keep")
        let item = try #require(try await vault.store.findItem(named: "Top", in: vault.root))

        try await vault.store.remove(item)

        #expect(!exists(top.diskURL))
        #expect(try await vault.names() == ["keep.txt"])
    }

    @Test("remove of an encrypted vault's folder deletes the folder, its nested files and their indexes")
    func removeEncryptedFolderTree() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let top = try vault.folder("Top")
        let inner = try vault.folder("Inner", in: top)
        let first = try await vault.add("a.txt", "a", to: top)
        let second = try await vault.add("b.txt", "b", to: inner)
        let kept = try await vault.add("keep.txt", "keep")
        let item = try #require(try await vault.store.findItem(named: "Top", in: vault.root))

        try await vault.store.remove(item)

        #expect(!exists(top.diskURL))
        #expect(!exists(first.diskURL))
        #expect(!exists(second.diskURL))
        #expect(try await vault.names() == ["keep.txt"])
        #expect(vault.indexEntries()?.values.sorted() == ["keep.txt"])
        #expect(try await vault.openedContent(kept) == "keep")
    }

    @Test("remove of an empty folder deletes it", arguments: [LockMode.none, .password])
    func removeEmptyFolder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let empty = try vault.folder("Empty")
        let item = try #require(try await vault.store.findItem(named: "Empty", in: vault.root))

        try await vault.store.remove(item)

        #expect(!exists(empty.diskURL))
        #expect(try await vault.list().isEmpty)
    }

    // MARK: - Never the trash

    @Test("remove never puts anything in the trash", arguments: [LockMode.none, .password])
    func removeNeverTrashes(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let folder = try vault.folder("Folder")
        try await vault.add("inside.txt", "in", to: folder)
        let file = try await vault.add("file.txt", "f")
        let trashedSource = try await vault.add("old.txt", "old")
        try await vault.store.moveToTrash(trashedSource)
        let trashBefore = try await vault.store.trashContents().map(\.id)
        let trashNamesBefore = vault.trashDiskNames()
        let folderItem = try #require(try await vault.store.findItem(named: "Folder", in: vault.root))

        try await vault.store.remove(file)
        try await vault.store.remove(folderItem)

        #expect(try await vault.store.trashContents().map(\.id) == trashBefore)
        #expect(vault.trashDiskNames() == trashNamesBefore)
    }

    @Test("remove of a file in a vault without a trash does not create one", arguments: [LockMode.none, .password])
    func removeCreatesNoTrash(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let file = try await vault.add("file.txt", "f")

        try await vault.store.remove(file)

        #expect(!exists(vault.trashURL))
        #expect(try await vault.store.trashContents().isEmpty)
    }

    // MARK: - notFound

    @Test("remove of a trash item throws notFound and changes nothing", arguments: [LockMode.none, .password])
    func removeTrashItemNotFound(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let source = try await vault.add("old.txt", "old")
        try await vault.store.moveToTrash(source)
        let trashed = try #require(try await vault.store.trashContents().first)
        let before = try vault.snapshot()

        let error = await caught { try await vault.store.remove(trashed) }

        #expect(error as? VaultStoreError == .notFound)
        #expect(try vault.snapshot() == before)
        #expect(try await vault.store.trashContents().map(\.id) == [trashed.id])
    }

    @Test("remove of an unknown item throws notFound and changes nothing", arguments: [LockMode.none, .password])
    func removeUnknownNotFound(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        try await vault.add("real.txt", "real")
        let before = try vault.snapshot()

        let error = await caught { try await vault.store.remove(ghost(vault, encrypted: mode != .none)) }

        #expect(error as? VaultStoreError == .notFound)
        #expect(try vault.snapshot() == before)
    }

    @Test("remove of a file that was already removed throws notFound")
    func removeTwiceNotFound() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let doomed = try await vault.add("doomed.txt", "bye")
        try await vault.store.remove(doomed)

        let error = await caught { try await vault.store.remove(doomed) }

        #expect(error as? VaultStoreError == .notFound)
    }

    // MARK: - locked

    @Test("remove of an encrypted item without the key throws locked and deletes nothing")
    func removeLocked() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let doomed = try await vault.add("doomed.txt", "bye")
        vault.keys.wipeKey()
        let before = try vault.snapshot()

        let error = await caught { try await vault.store.remove(doomed) }

        #expect(error as? VaultStoreError == .locked)
        #expect(try vault.snapshot() == before)
        #expect(exists(doomed.diskURL))
    }

    // MARK: - Failures (index first, then part-way)

    @Test("remove of an encrypted file whose index write fails throws and deletes nothing: the index is written first")
    func removeIndexWriteFailsKeepsFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, selective: true)
        defer { vault.cleanUp() }
        let doomed = try await vault.add("doomed.txt", "bye")
        let kept = try await vault.add("kept.txt", "stay")
        let indexBefore = vault.rawIndex()
        let failing = try #require(vault.failing)
        failing.encryptError = VaultCryptoError.encryptionFailed

        let error = await caught { try await vault.store.remove(doomed) }

        failing.encryptError = nil
        #expect(error is VaultStoreError, "unexpected error \(String(describing: error))")
        #expect(exists(doomed.diskURL))
        #expect(vault.rawIndex() == indexBefore)
        #expect(try await vault.openedContent(doomed) == "bye")
        #expect(try await vault.openedContent(kept) == "stay")
    }

    @Test("remove of a plaintext file in a read-only folder throws io and keeps the file")
    func removePlaintextReadOnlyFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let doomed = try await vault.add("doomed.txt", "bye")
        let restore = try restrict(vault.rootURL)
        defer { restore() }

        let error = await caught { try await vault.store.remove(doomed) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(exists(doomed.diskURL))
        #expect(try vault.content(doomed.diskURL) == "bye")
    }

    @Test("remove of an encrypted file in a read-only folder throws io and changes nothing")
    func removeEncryptedFileDeleteFails() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let doomed = try await vault.add("doomed.txt", "bye", to: docs)
        let kept = try await vault.add("kept.txt", "stay", to: docs)
        let indexBefore = vault.rawIndex(in: docs)
        let restore = try restrict(docs.diskURL)
        defer { restore() }

        let error = await caught { try await vault.store.remove(doomed) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(exists(doomed.diskURL))
        #expect(vault.rawIndex(in: docs) == indexBefore)
        #expect(try await vault.openedContent(kept) == "stay")
    }

    @Test("remove of a folder with an undeletable subfolder throws io and what wasn't reached remains")
    func removeFolderPartWayFailure() async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let top = try vault.folder("Top")
        let stuck = try vault.folder("Stuck", in: top)
        let deepURL = try vault.diskFile("deep.txt", "deep", in: stuck)
        let item = try #require(try await vault.store.findItem(named: "Top", in: vault.root))
        let restore = try restrict(stuck.diskURL)
        defer { restore() }

        let error = await caught { try await vault.store.remove(item) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(exists(deepURL))
        #expect(exists(top.diskURL))
        #expect(vault.trashDiskNames().isEmpty)
    }

    @Test("remove of an encrypted file whose delete fails puts its entry back and throws io")
    func removeEncryptedFileDeleteFailsRestoresEntry() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let doomed = try await vault.add("doomed.txt", "bye")
        let kept = try await vault.add("kept.txt", "stay")
        let entriesBefore = vault.indexEntries()
        // An immutable file can't be deleted, while the folder (and so the index) stays writable.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: doomed.diskURL.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: doomed.diskURL.path) }

        let error = await caught { try await vault.store.remove(doomed) }

        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(exists(doomed.diskURL))
        #expect(vault.indexEntries() == entriesBefore)
        #expect(try await vault.names() == ["doomed.txt", "kept.txt"])
        #expect(try await vault.openedContent(doomed) == "bye")
        #expect(try await vault.openedContent(kept) == "stay")
    }
}
