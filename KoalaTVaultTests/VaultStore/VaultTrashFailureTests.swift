import Foundation
import Testing

@testable import KoalaTVault

/// Trash operations when the disk fails: the error is reported, and the item and its entry stay consistent.
@Suite struct VaultTrashFailureTests {
    private func trashed(_ vault: VaultStoreFixture, _ item: VaultItem) async throws -> VaultItem {
        try await vault.store.moveToTrash(item)
        let listed = try await vault.store.trashContents()
        return try #require(listed.first { $0.name == item.name })
    }

    private func visibleTrashNames(_ vault: VaultStoreFixture) -> [String] {
        vault.trashDiskNames().filter { !$0.hasPrefix(".") }
    }

    @Test(
        "restore re-bases an absolute original folder inside the current root",
        arguments: [LockMode.none, .password])
    func restoreRebasesAbsolutePathInsideCurrentRoot(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("old.txt", "old", to: docs)
        let trashedItem = try await trashed(vault, item)
        try vault.rewriteTrashEntries { entry in entry["originalDirectoryURL"] = vault.rootURL.path + "/Docs" }

        let restored = try await vault.store.restore(trashedItem)

        #expect(restored.id.hasPrefix("Docs/"))
        #expect(try await vault.names(docs) == ["old.txt"])
        #expect(try await vault.openedContent(restored) == "old")
        #expect(try await vault.store.trashContents().isEmpty)
    }

    @Test(
        "moveToTrash with a plain file named .trash in the way throws io and leaves the item",
        arguments: [LockMode.none, .password])
    func moveToTrashWithoutTrashFolderThrowsIO(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        try vault.diskFile(".trash", "not a folder")
        let indexBefore = vault.rawIndex()

        let error = await caught { try await vault.store.moveToTrash(item) }

        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.content(vault.trashURL) == "not a folder")
        #expect(try await vault.openedContent(item) == "data")
        #expect(try await vault.names() == ["a.txt"])
        #expect(vault.rawIndex() == indexBefore)
    }

    @Test(
        "moveToTrash whose move fails throws io, rolls back the trash entry and keeps the item in place",
        arguments: [LockMode.none, .password])
    func moveToTrashMoveFailureRollsBack(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("a.txt", "data", to: docs)
        let indexBefore = vault.rawIndex(in: docs)
        let restore = try restrict(docs.diskURL)
        defer { restore() }

        let error = await caught { try await vault.store.moveToTrash(item) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(vault.trashEntries()?.isEmpty ?? true)
        #expect(visibleTrashNames(vault).isEmpty)
        #expect(try await vault.store.trashContents().isEmpty)
        #expect(try await vault.names(docs) == ["a.txt"])
        #expect(try await vault.openedContent(item) == "data")
        #expect(vault.rawIndex(in: docs) == indexBefore)
    }

    @Test(
        "restore whose original folder can't be recreated throws io, moves nothing and keeps the entry",
        arguments: [LockMode.none, .password])
    func restoreWithUnrecreatableFolderThrowsIO(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("a.txt", "data", to: docs)
        let trashedItem = try await trashed(vault, item)
        try FileManager.default.removeItem(at: docs.diskURL)
        let mapBefore = vault.rawTrashMap()
        let trashBefore = vault.trashDiskNames()
        let restore = try restrict(vault.rootURL)
        defer { restore() }

        let error = await caught { _ = try await vault.store.restore(trashedItem) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.diskNames() == [".trash"])
        #expect(vault.trashDiskNames() == trashBefore)
        #expect(vault.rawTrashMap() == mapBefore)
        #expect(try await vault.store.trashContents().map(\.id) == [trashedItem.id])
    }

    @Test("Restoring an encrypted item whose move out of the trash fails restores the index and keeps item and entry")
    func encryptedRestoreMoveFailure() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        let trashedItem = try await trashed(vault, item)
        let indexBefore = vault.rawIndex()
        let entriesBefore = vault.indexEntries()
        let mapBefore = vault.rawTrashMap()
        let diskBefore = try vault.diskNames()
        let restore = try restrict(vault.trashURL)
        defer { restore() }

        let error = await caught { _ = try await vault.store.restore(trashedItem) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(vault.indexEntries() == entriesBefore)
        #expect(vault.rawIndex() == indexBefore)
        #expect(!vault.indexIsPlaintextJSON())
        #expect(try vault.diskNames() == diskBefore)
        #expect(FileManager.default.fileExists(atPath: trashedItem.diskURL.path))
        #expect(vault.rawTrashMap() == mapBefore)
        #expect(try await vault.store.trashContents().map(\.id) == [trashedItem.id])
    }

    @Test("Restoring a plaintext item whose move out of the trash fails throws io and keeps item and entry")
    func plaintextRestoreMoveFailure() async throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        let trashedItem = try await trashed(vault, item)
        let mapBefore = vault.rawTrashMap()
        let restore = try restrict(vault.trashURL)
        defer { restore() }

        let error = await caught { _ = try await vault.store.restore(trashedItem) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.diskNames() == [".trash"])
        #expect(FileManager.default.fileExists(atPath: trashedItem.diskURL.path))
        #expect(vault.rawTrashMap() == mapBefore)
        #expect(try await vault.store.trashContents().map(\.id) == [trashedItem.id])
    }

    @Test(
        "deletePermanently whose removal fails throws io and keeps the file and its entry",
        arguments: [LockMode.none, .password])
    func deletePermanentlyRemovalFailure(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        let trashedItem = try await trashed(vault, item)
        let mapBefore = vault.rawTrashMap()
        let restore = try restrict(vault.trashURL)
        defer { restore() }

        let error = await caught { try await vault.store.deletePermanently(trashedItem) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(FileManager.default.fileExists(atPath: trashedItem.diskURL.path))
        #expect(vault.rawTrashMap() == mapBefore)
        #expect(try await vault.store.trashContents().map(\.id) == [trashedItem.id])
    }

    @Test(
        "purgeExpiredTrash keeps the entry of a file it can't remove, purges the rest, saves the map, then throws",
        arguments: [LockMode.none, .password])
    func purgeKeepsEntryOfUnremovableFile(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let stuck = try vault.folder("Stuck")
        let inner = try vault.folder("Inner", in: stuck)
        try vault.diskFile("deep.txt", "deep", in: inner)
        let first = try await vault.add("first.txt", "1")
        let second = try await vault.add("second.txt", "2")
        let stuckItem = try #require(try await vault.store.findItem(named: "Stuck", in: vault.root))
        try await vault.store.moveToTrash(first)
        try await vault.store.moveToTrash(stuckItem)
        try await vault.store.moveToTrash(second)
        let listed = try await vault.store.trashContents()
        let stuckTrash = try #require(listed.first { $0.name == "Stuck" })
        let innerInTrash = stuckTrash.diskURL.appendingPathComponent("Inner")
        let restore = try restrict(innerInTrash)
        defer { restore() }
        let future = Date().addingTimeInterval(31 * 24 * 60 * 60)

        let error = await caught { _ = try await vault.store.purgeExpiredTrash(now: future) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        let entries = try #require(vault.trashEntries())
        #expect(entries.count == 1)
        #expect(entries[stuckTrash.diskURL.lastPathComponent] != nil)
        #expect(visibleTrashNames(vault) == [stuckTrash.diskURL.lastPathComponent])
        #expect(try await vault.store.trashContents().map(\.name) == ["Stuck"])
    }
}
