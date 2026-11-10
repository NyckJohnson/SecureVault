import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultTrashTests {
    /// Moves `item` to the trash and returns its trash item.
    private func trash(_ vault: VaultStoreFixture, _ item: VaultItem) async throws -> VaultItem {
        try await vault.store.moveToTrash(item)
        let all = try await vault.store.trashContents()
        return try #require(all.first { $0.name == item.name })
    }

    // MARK: - moveToTrash

    @Test("moveToTrash moves a file into .trash/<uuid> and records an entry", arguments: [LockMode.none, .password])
    func moveToTrashRecordsEntry(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("report.pdf", "pdf bytes", to: docs)
        let before = Date()
        try await vault.store.moveToTrash(item)

        #expect(try await vault.names(docs).isEmpty)
        let names = vault.trashDiskNames().filter { $0 != ".trash_map" }
        #expect(names.count == 1)
        #expect(UUID(uuidString: names.first ?? "") != nil)
        #expect(FileManager.default.fileExists(atPath: vault.rootURL.appendingPathComponent(".trash/.trash_map").path))
        #expect(!FileManager.default.fileExists(atPath: vault.rootTrashMapURL.path))
        #expect(vault.trashDiskNames().contains(".trash_map"))
        let entries = try #require(vault.trashEntries())
        #expect(entries.count == 1)
        let entry = try #require(entries.values.first)
        #expect(entry["originalName"] as? String == "report.pdf")
        #expect(entry["isEncrypted"] as? Bool == (mode != .none))
        #expect(entry["originalDiskName"] as? String == (item.id as NSString).lastPathComponent)
        let folder = try #require(entry["originalDirectoryURL"] as? String)
        #expect(!folder.hasPrefix("/"))
        #expect(!folder.contains(vault.base.path))
        #expect(entry["deletedAt"] != nil)
        let trashed = try await vault.store.trashContents()
        let deletedAt = try #require(trashed.first?.deletedAt)
        #expect(abs(deletedAt.timeIntervalSince(before)) < 60)
    }

    @Test("moveToTrash in encrypted mode seals the trash map with the .trash_map context")
    func moveToTrashSealsMap() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        try await vault.store.moveToTrash(item)
        #expect(vault.trashMapContext() == ".trash_map")
        #expect(!vault.trashMapIsPlaintextJSON())
    }

    @Test("moveToTrash in plaintext mode writes the trash map as plaintext JSON")
    func moveToTrashPlaintextMap() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        try await vault.store.moveToTrash(item)
        #expect(vault.trashMapIsPlaintextJSON())
        #expect(vault.trashEntries()?.count == 1)
        #expect(!FileManager.default.fileExists(atPath: vault.rootTrashMapURL.path))
    }

    @Test("moveToTrash removes an encrypted file's entry from its folder index")
    func moveToTrashRemovesIndexEntry() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let keep = try await vault.add("keep.txt")
        let gone = try await vault.add("gone.txt")
        try await vault.store.moveToTrash(gone)
        let diskName = (keep.id as NSString).lastPathComponent
        #expect(vault.indexEntries() == [diskName: "keep.txt"])
        #expect(try await vault.names() == ["keep.txt"])
    }

    @Test("moveToTrash keeps a trashed folder a folder, with its contents", arguments: [LockMode.none, .password])
    func moveToTrashFolder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let inner = try #require(docs.asDirectory)
        try await vault.add("inside.txt", "inside", to: inner)
        try await vault.store.moveToTrash(docs)

        let trashed = try await vault.store.trashContents()
        #expect(trashed.count == 1)
        let item = try #require(trashed.first)
        #expect(item.name == "Docs")
        #expect(item.isDirectory)
        #expect(item.fileSize == nil)
        #expect(try await vault.names().isEmpty)
    }

    @Test("moveToTrash of a plaintext folder in an encrypted vault records isEncrypted false")
    func moveToTrashPlaintextFolderInEncryptedVault() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try await vault.store.createFolder(named: "Docs", in: vault.root)
        try await vault.store.moveToTrash(docs)
        let item = try #require(try await vault.store.trashContents().first)
        #expect(item.isEncrypted == false)
    }

    @Test("moveToTrash with an unreadable trash index throws indexUnreadable and leaves the item and map")
    func moveToTrashUnreadableTrashIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "keep me")
        try vault.writeRawTrashMap(Data("garbage".utf8))
        let before = try vault.snapshot()
        let error = await caught { try await vault.store.moveToTrash(item) }
        #expect(isIndexUnreadable(error))
        #expect(try vault.snapshot() == before)
        #expect(try await vault.names() == ["a.txt"])
    }

    @Test("Concurrent moveToTrash calls never lose a trash entry")
    func concurrentMoveToTrash() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        var items: [VaultItem] = []
        for index in 0..<10 { items.append(try await vault.add("file\(index).txt", "c\(index)")) }
        let store = vault.store
        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in items { group.addTask { try await store.moveToTrash(item) } }
            try await group.waitForAll()
        }
        let trashed = try await store.trashContents()
        #expect(Set(trashed.map(\.name)) == Set(items.map(\.name)))
        #expect(vault.trashEntries()?.count == 10)
        #expect(try await vault.names().isEmpty)
    }

    // MARK: - trashContents

    @Test("trashContents of a vault with no trash is empty", arguments: [LockMode.none, .password])
    func trashContentsEmpty(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        #expect(try await vault.store.trashContents().isEmpty)
    }

    @Test("trashContents is one flat list with original names, deletedAt, trash ids and kinds")
    func trashContentsFlatList() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let docsDir = try #require(docs.asDirectory)
        let photo = try await vault.add("photo.jpg", "pixels", to: docsDir)
        let note = try await vault.add("note.txt", "hello")
        try await vault.store.moveToTrash(photo)
        try await vault.store.moveToTrash(note)

        let trashed = try await vault.store.trashContents()
        #expect(Set(trashed.map(\.name)) == ["photo.jpg", "note.txt"])
        #expect(trashed.count == 2)
        #expect(!trashed.contains { $0.name == ".trash_map" || $0.id == ".trash/.trash_map" })
        for item in trashed {
            #expect(item.id.hasPrefix(".trash/"))
            #expect(UUID(uuidString: (item.id as NSString).lastPathComponent) != nil)
            #expect(item.deletedAt != nil)
            #expect(item.isEncrypted)
            #expect(item.isDirectory == false)
            #expect(item.rootURL == vault.rootURL)
        }
        #expect(trashed.first { $0.name == "photo.jpg" }?.kind == .image)
        #expect(trashed.first { $0.name == "note.txt" }?.kind == .text)
        let again = try await vault.store.trashContents()
        #expect(Set(again.map(\.id)) == Set(trashed.map(\.id)))
    }

    @Test("trashContents with an unreadable trash index throws indexUnreadable")
    func trashContentsUnreadable() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.writeRawTrashMap(Data("garbage".utf8))
        let error = await caught { _ = try await vault.store.trashContents() }
        #expect(isIndexUnreadable(error))
    }

    @Test("A plaintext trash map is read once a lock is on")
    func plaintextTrashMapReadableInEncryptedMode() async throws {
        var vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let item = try await vault.add("old.txt", "old")
        try await vault.store.moveToTrash(item)
        vault.reopen(encrypted: true)
        let trashed = try await vault.store.trashContents()
        #expect(trashed.map(\.name) == ["old.txt"])
    }

    @Test("A plaintext trash map is rewritten encrypted by the next trash write, keeping the earlier entry")
    func plaintextTrashMapResealedOnNextWrite() async throws {
        var vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let old = try await vault.add("old.txt", "old")
        try await vault.store.moveToTrash(old)
        #expect(vault.trashMapIsPlaintextJSON())
        vault.reopen(encrypted: true)
        let fresh = try await vault.add("fresh.txt", "fresh")
        try await vault.store.moveToTrash(fresh)
        #expect(!vault.trashMapIsPlaintextJSON())
        #expect(vault.trashMapContext() == ".trash_map")
        #expect(vault.trashEntries()?.count == 2)
        let trashed = try await vault.store.trashContents()
        #expect(trashed.map(\.name).sorted() == ["fresh.txt", "old.txt"])
    }

    // MARK: - restore

    @Test("restore puts the item back in its original folder with its content", arguments: [LockMode.none, .password])
    func restoreToOriginalFolder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("report.pdf", "pdf bytes", to: docs)
        let trashed = try await trash(vault, item)
        let restored = try await vault.store.restore(trashed)

        #expect(restored.name == "report.pdf")
        #expect(restored.id.hasPrefix("Docs/"))
        #expect(restored.isEncrypted == (mode != .none))
        #expect(restored.deletedAt == nil)
        #expect(try await vault.names(docs) == ["report.pdf"])
        #expect(try await vault.openedContent(restored) == "pdf bytes")
        #expect(try await vault.store.trashContents().isEmpty)
        #expect(vault.trashEntries()?.isEmpty ?? true)
    }

    @Test("restore of a root-level item returns it to the root", arguments: [LockMode.none, .password])
    func restoreToRoot(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "alpha")
        let trashed = try await trash(vault, item)
        let restored = try await vault.store.restore(trashed)
        #expect(try await vault.names() == ["a.txt"])
        #expect(try await vault.openedContent(restored) == "alpha")
    }

    @Test("restore recreates the original folder when it is gone", arguments: [LockMode.none, .password])
    func restoreRecreatesFolder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("report.pdf", "pdf bytes", to: docs)
        let trashed = try await trash(vault, item)
        try FileManager.default.removeItem(at: docs.diskURL)

        let restored = try await vault.store.restore(trashed)
        #expect(try await vault.names() == ["Docs"])
        #expect(try await vault.names(docs) == ["report.pdf"])
        #expect(try await vault.openedContent(restored) == "pdf bytes")
    }

    @Test("restore re-bases older absolute paths onto the current root", arguments: ["", "Docs", "Docs/Inner"])
    func restoreRebasesAbsolutePaths(relative: String) async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let target = relative.isEmpty ? vault.root : try vault.folder(relative)
        let item = try await vault.add("old.txt", "old", to: target)
        let trashed = try await trash(vault, item)
        let rootName = vault.rootURL.lastPathComponent
        let oldRoot = "/private/var/mobile/Containers/Data/Application/OLD-CONTAINER/Documents/\(rootName)"
        try vault.rewriteTrashEntries { entry in
            entry["originalDirectoryURL"] = relative.isEmpty ? oldRoot : oldRoot + "/" + relative
        }
        let restored = try await vault.store.restore(trashed)
        #expect(try await vault.names(target) == ["old.txt"])
        #expect(try await vault.openedContent(restored) == "old")
    }

    @Test("restore resolves a name conflict with a ' 1' suffix in plaintext mode")
    func restoreConflictPlaintext() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let first = try await vault.add("a.txt", "first")
        let trashed = try await trash(vault, first)
        try await vault.add("a.txt", "second")
        let restored = try await vault.store.restore(trashed)
        #expect(restored.name == "a 1.txt")
        #expect(try await vault.names() == ["a 1.txt", "a.txt"])
        #expect(try vault.content(restored.diskURL) == "first")
    }

    @Test("restore resolves a display-name conflict with a ' 1' suffix in encrypted mode")
    func restoreConflictEncrypted() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let first = try await vault.add("a.txt", "first")
        let trashed = try await trash(vault, first)
        let second = try await vault.add("a.txt", "second")
        let restored = try await vault.store.restore(trashed)
        #expect(restored.name == "a 1.txt")
        #expect(try await vault.names() == ["a 1.txt", "a.txt"])
        #expect(try await vault.openedContent(restored) == "first")
        #expect(try await vault.openedContent(second) == "second")
    }

    @Test("restore of an encrypted item re-indexes it in the original folder")
    func restoreReindexes() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("report.pdf", "x", to: docs)
        let trashed = try await trash(vault, item)
        let restored = try await vault.store.restore(trashed)
        let diskName = (restored.id as NSString).lastPathComponent
        #expect(vault.indexEntries(in: docs) == [diskName: "report.pdf"])
        #expect(restored.isEncrypted)
    }

    @Test("restore of a trashed folder brings back the folder and its contents", arguments: [LockMode.none, .password])
    func restoreFolder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let docsDir = try #require(docs.asDirectory)
        try await vault.add("inside.txt", "inside", to: docsDir)
        let trashed = try await trash(vault, docs)
        let restored = try await vault.store.restore(trashed)
        #expect(restored.isDirectory)
        #expect(restored.name == "Docs")
        let directory = try #require(restored.asDirectory)
        #expect(try await vault.names(directory) == ["inside.txt"])
    }

    @Test(
        "restore of an unknown trash item throws notFound and changes nothing", arguments: [LockMode.none, .password])
    func restoreUnknown(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        try await vault.store.moveToTrash(item)
        let before = try vault.snapshot()
        let error = await caught { _ = try await vault.store.restore(vault.ghostTrashItem()) }
        #expect(error as? VaultStoreError == .notFound)
        #expect(try vault.snapshot() == before)
    }

    // MARK: - deletePermanently

    @Test("deletePermanently removes the file and its entry", arguments: [LockMode.none, .password])
    func deletePermanentlyRemoves(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let doomed = try await vault.add("doomed.txt")
        let kept = try await vault.add("kept.txt")
        let doomedTrash = try await trash(vault, doomed)
        let keptTrash = try await trash(vault, kept)
        try await vault.store.deletePermanently(doomedTrash)

        let remaining = try await vault.store.trashContents()
        #expect(remaining.map(\.name) == ["kept.txt"])
        #expect(vault.trashEntries()?.count == 1)
        #expect(!FileManager.default.fileExists(atPath: doomedTrash.diskURL.path))
        #expect(FileManager.default.fileExists(atPath: keptTrash.diskURL.path))
    }

    @Test("deletePermanently removes a trashed folder with its contents")
    func deletePermanentlyFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let docs = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let docsDir = try #require(docs.asDirectory)
        try await vault.add("inside.txt", to: docsDir)
        let trashed = try await trash(vault, docs)
        try await vault.store.deletePermanently(trashed)
        #expect(try await vault.store.trashContents().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: trashed.diskURL.path))
    }

    @Test("deletePermanently of an unknown item throws notFound", arguments: [LockMode.none, .password])
    func deletePermanentlyUnknown(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        try await vault.store.moveToTrash(item)
        let before = try vault.snapshot()
        let error = await caught { try await vault.store.deletePermanently(vault.ghostTrashItem()) }
        #expect(error as? VaultStoreError == .notFound)
        #expect(try vault.snapshot() == before)
    }

    // MARK: - emptyTrash

    @Test("emptyTrash removes everything in .trash and its index", arguments: [LockMode.none, .password])
    func emptyTrashRemovesAll(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let file = try await vault.add("a.txt")
        try await vault.store.moveToTrash(docs)
        try await vault.store.moveToTrash(file)
        let kept = try await vault.add("kept.txt")
        await vault.store.emptyTrash()

        #expect(try await vault.store.trashContents().isEmpty)
        #expect(vault.trashDiskNames().isEmpty)
        #expect(vault.rawTrashMap() == nil)
        #expect(try await vault.names() == [kept.name])
    }

    @Test("emptyTrash on an empty trash does nothing and does not throw")
    func emptyTrashEmpty() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        await vault.store.emptyTrash()
        #expect(try await vault.store.trashContents().isEmpty)
    }

    @Test("emptyTrash is best-effort: it clears the trash even when the index is unreadable")
    func emptyTrashUnreadableIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        try await vault.store.moveToTrash(item)
        try vault.writeRawTrashMap(Data("garbage".utf8))
        await vault.store.emptyTrash()
        #expect(vault.trashDiskNames().filter { $0 != ".trash_map" }.isEmpty)
    }

    // MARK: - purgeExpiredTrash

    @Test("purgeExpiredTrash removes only entries deleted more than 30 days before now")
    func purgeBoundary() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let thirtyDays: TimeInterval = 30 * 24 * 60 * 60
        let old = try await vault.add("old.txt")
        try await vault.store.moveToTrash(old)
        try await Task.sleep(for: .seconds(2))
        let recent = try await vault.add("recent.txt")
        try await vault.store.moveToTrash(recent)
        let trashed = try await vault.store.trashContents()
        let oldDate = try #require(trashed.first { $0.name == "old.txt" }?.deletedAt)

        let now = Date()
        #expect(try await vault.store.purgeExpiredTrash(now: now) == 0)
        #expect(try await vault.store.trashContents().count == 2)
        #expect(try await vault.store.purgeExpiredTrash(now: oldDate.addingTimeInterval(thirtyDays - 1)) == 0)
        #expect(try await vault.store.purgeExpiredTrash(now: oldDate.addingTimeInterval(thirtyDays)) == 0)
        #expect(try await vault.store.trashContents().count == 2)

        let purged = try await vault.store.purgeExpiredTrash(now: oldDate.addingTimeInterval(thirtyDays + 0.5))
        #expect(purged == 1)
        let remaining = try await vault.store.trashContents()
        #expect(remaining.map(\.name) == ["recent.txt"])
        let oldTrash = try #require(trashed.first { $0.name == "old.txt" })
        #expect(!FileManager.default.fileExists(atPath: oldTrash.diskURL.path))
        #expect(vault.trashEntries()?.count == 1)
    }

    @Test("purgeExpiredTrash returns how many it removed", arguments: [LockMode.none, .password])
    func purgeCount(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        for index in 0..<3 {
            let item = try await vault.add("file\(index).txt")
            try await vault.store.moveToTrash(item)
        }
        let later = Date().addingTimeInterval(31 * 24 * 60 * 60)
        #expect(try await vault.store.purgeExpiredTrash(now: later) == 3)
        #expect(try await vault.store.trashContents().isEmpty)
        #expect(vault.trashDiskNames().filter { $0 != ".trash_map" }.isEmpty)
    }

    @Test("purgeExpiredTrash on an empty trash returns 0")
    func purgeEmpty() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        #expect(try await vault.store.purgeExpiredTrash(now: Date()) == 0)
    }

    @Test("purgeExpiredTrash with an unreadable index throws without writing")
    func purgeUnreadableIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt")
        try await vault.store.moveToTrash(item)
        try vault.writeRawTrashMap(Data("garbage".utf8))
        let before = try vault.snapshot()
        let later = Date().addingTimeInterval(60 * 24 * 60 * 60)
        let error = await caught { _ = try await vault.store.purgeExpiredTrash(now: later) }
        #expect(isIndexUnreadable(error))
        #expect(try vault.snapshot() == before)
    }

    // MARK: - Locked

    enum LockedTrashOperation: String, CaseIterable, Sendable {
        case moveToTrash, trashContents, restore, deletePermanently, purgeExpiredTrash
    }

    @Test(
        "Trash operations in encrypted mode without a key throw locked and change nothing",
        arguments: LockedTrashOperation.allCases, [LockMode.password, .passwordAndBiometrics])
    func lockedTrashOperations(operation: LockedTrashOperation, mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let live = try await vault.add("live.txt")
        let doomed = try await vault.add("doomed.txt")
        let trashed = try await trash(vault, doomed)
        vault.keys.wipeKey()
        let before = try vault.snapshot()

        let error = await caught {
            switch operation {
            case .moveToTrash: try await vault.store.moveToTrash(live)
            case .trashContents: _ = try await vault.store.trashContents()
            case .restore: _ = try await vault.store.restore(trashed)
            case .deletePermanently: try await vault.store.deletePermanently(trashed)
            case .purgeExpiredTrash:
                _ = try await vault.store.purgeExpiredTrash(now: Date().addingTimeInterval(90 * 24 * 60 * 60))
            }
        }
        #expect(error as? VaultStoreError == .locked)
        #expect(try vault.snapshot() == before)
    }
}

/// One way an entry can point a restore somewhere it must not go.
struct RestoreAttack: Sendable, CustomTestStringConvertible {
    let label: String
    /// New `originalDirectoryURL`; `{outside}` stands for a folder outside the vault. Nil keeps the entry's own.
    let directory: String?
    /// New `originalDiskName`; nil keeps the entry's own.
    let diskName: String?

    var testDescription: String { label }

    static let all: [RestoreAttack] = [
        RestoreAttack(label: "absolute path outside the root", directory: "{outside}", diskName: nil),
        RestoreAttack(label: "relative path through ..", directory: "../Outside", diskName: nil),
        RestoreAttack(label: "nested path through ..", directory: "Docs/../../Outside", diskName: nil),
        RestoreAttack(label: "hidden folder", directory: ".hidden", diskName: nil),
        RestoreAttack(label: "hidden nested folder", directory: "Docs/.secret", diskName: nil),
        RestoreAttack(label: "trash folder as target", directory: ".trash", diskName: nil),
        RestoreAttack(label: "symlink pointing outside", directory: "Link", diskName: nil),
        RestoreAttack(label: "disk name through ..", directory: nil, diskName: "../escape"),
        RestoreAttack(label: "disk name with a slash", directory: nil, diskName: "sub/escape"),
        RestoreAttack(label: "empty disk name", directory: nil, diskName: ""),
        RestoreAttack(label: "disk name ..", directory: nil, diskName: ".."),  // swiftlint:disable:this trailing_comma
    ]
}

@Suite struct VaultTrashRestoreSafetyTests {
    @Test(
        "restore refuses an unsafe target with io, moves nothing and keeps the trash item and map",
        arguments: RestoreAttack.all, [LockMode.none, .password])
    func restoreRefusesUnsafeTarget(attack: RestoreAttack, mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let outside = try vault.outsideFolder()
        try FileManager.default.createSymbolicLink(
            at: vault.rootURL.appendingPathComponent("Link"), withDestinationURL: outside)
        let item = try await vault.add("a.txt", "precious", to: docs)
        try await vault.store.moveToTrash(item)
        let trashed = try #require(try await vault.store.trashContents().first)
        try vault.rewriteTrashEntries { entry in
            if let directory = attack.directory {
                entry["originalDirectoryURL"] = directory.replacingOccurrences(of: "{outside}", with: outside.path)
            }
            if let diskName = attack.diskName { entry["originalDiskName"] = diskName }
        }
        let mapBefore = vault.rawTrashMap()
        let trashBefore = vault.trashDiskNames()
        let rootBefore = try vault.diskNames()
        let docsBefore = try vault.diskNames(in: docs)

        let error = await caught { _ = try await vault.store.restore(trashed) }

        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(vault.rawTrashMap() == mapBefore)
        #expect(vault.trashDiskNames() == trashBefore)
        #expect(FileManager.default.fileExists(atPath: trashed.diskURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try vault.diskNames() == rootBefore)
        #expect(try vault.diskNames(in: docs) == docsBefore)
        let stillTrashed = try await vault.store.trashContents()
        #expect(stillTrashed.map(\.id) == [trashed.id])
    }
}

@Suite struct VaultTrashUnreadableFileTests {
    private func setPermissions(_ mode: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    @Test(
        "One unreadable trash file doesn't stop listing or restoring the others; migration steps stay strict",
        .disabled("feature multiple-vaults-duress-password: rebuilt in VaultStore unit 2"),
        arguments: [LockMode.none, .password])
    func unreadableTrashFile(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode, headerAware: true)
        defer { vault.cleanUp() }
        let broken = try await vault.add("broken.txt", "broken content")
        let fine = try await vault.add("fine.txt", "fine content")
        try await vault.store.moveToTrash(broken)
        try await vault.store.moveToTrash(fine)
        let before = try await vault.store.trashContents()
        let brokenItem = try #require(before.first { $0.name == "broken.txt" })
        let fineItem = try #require(before.first { $0.name == "fine.txt" })
        let storedFlag = mode != .none
        try setPermissions(0o000, of: brokenItem.diskURL)
        defer { try? setPermissions(0o644, of: brokenItem.diskURL) }

        let listed = try await vault.store.trashContents()
        #expect(Set(listed.map(\.name)) == ["broken.txt", "fine.txt"])
        #expect(listed.first { $0.name == "broken.txt" }?.isEncrypted == storedFlag)
        #expect(listed.first { $0.name == "fine.txt" }?.isEncrypted == storedFlag)

        let restored = try await vault.store.restore(fineItem)
        #expect(restored.name == "fine.txt")
        #expect(try await vault.openedContent(restored) == "fine content")
        #expect(try await vault.store.trashContents().map(\.name) == ["broken.txt"])

        let toEncrypt = await caught { _ = try await vault.store.itemsToMigrate(toEncrypted: true) }
        let toDecrypt = await caught { _ = try await vault.store.itemsToMigrate(toEncrypted: false) }
        let finish = await caught { try await vault.store.finishDecryption() }
        #expect(toEncrypt != nil)
        #expect(toDecrypt != nil)
        #expect(finish != nil)
    }
}
