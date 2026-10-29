import Foundation
import Testing

@testable import KoalaTVault

@Suite struct OrphanSweepTests {
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test("sweepOrphans deletes extensionless UUID files the index doesn't list and keeps listed ones")
    func sweepDeletesUnlistedUUIDFiles() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let listed = try await vault.add("keep.txt", "keep", to: docs)
        let orphan = VaultStoreFixture.newDiskName()
        try vault.diskSealedFile(orphan, "orphan", in: docs)
        let indexBefore = vault.rawIndex(in: docs)
        await vault.store.sweepOrphans()

        #expect(!exists(docs.diskURL.appendingPathComponent(orphan)))
        #expect(exists(listed.diskURL))
        #expect(vault.rawIndex(in: docs) == indexBefore)
        #expect(try await vault.openedContent(listed) == "keep")
    }

    @Test("sweepOrphans sweeps the root and nested folders that have a readable index")
    func sweepCoversEveryIndexedFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let inner = try vault.folder("Inner", in: docs)
        try await vault.add("a.txt")
        try await vault.add("d.txt", to: docs)
        try await vault.add("b.txt", to: inner)
        let orphans = [vault.root, docs, inner].map { directory -> URL in
            directory.diskURL.appendingPathComponent(VaultStoreFixture.newDiskName())
        }
        for url in orphans { try HeaderAwareTestCipher.sealed(Data("orphan".utf8)).write(to: url) }
        await vault.store.sweepOrphans()
        #expect(orphans.allSatisfy { !exists($0) })
        #expect(try await vault.names() == ["Docs", "a.txt"])
        #expect(try await vault.names(docs) == ["Inner", "d.txt"])
        #expect(try await vault.names(inner) == ["b.txt"])
    }

    @Test("sweepOrphans keeps files that have an extension or a non-UUID name")
    func sweepKeepsOtherNames() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        let withExtension = "\(VaultStoreFixture.newDiskName()).txt"
        try vault.diskFile(withExtension)
        try vault.diskFile("notes")
        try vault.diskFile("photo.jpg")
        try vault.diskFile("1234")
        await vault.store.sweepOrphans()
        for name in [withExtension, "notes", "photo.jpg", "1234"] {
            #expect(exists(vault.rootURL.appendingPathComponent(name)), "\(name) must survive")
        }
    }

    @Test("sweepOrphans leaves folders with no index alone")
    func sweepSkipsFoldersWithoutIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        let plainFolder = try vault.folder("NoIndex")
        let uuidFile = VaultStoreFixture.newDiskName()
        try vault.diskFile(uuidFile, "plaintext that happens to look like a UUID", in: plainFolder)
        await vault.store.sweepOrphans()
        #expect(exists(plainFolder.diskURL.appendingPathComponent(uuidFile)))
        #expect(vault.rawIndex(in: plainFolder) == nil)
    }

    @Test("sweepOrphans leaves a folder with an unreadable index alone and doesn't touch the index")
    func sweepSkipsUnreadableIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        let broken = try vault.folder("Broken")
        let uuidFile = VaultStoreFixture.newDiskName()
        try vault.diskFile(uuidFile, "maybe precious", in: broken)
        try vault.writeRawIndex(Data("garbage".utf8), in: broken)
        await vault.store.sweepOrphans()
        #expect(exists(broken.diskURL.appendingPathComponent(uuidFile)))
        #expect(vault.rawIndex(in: broken) == Data("garbage".utf8))
    }

    @Test("sweepOrphans never sweeps the trash")
    func sweepSkipsTrash() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "trashed")
        try await vault.store.moveToTrash(item)
        let strayInTrash = vault.trashURL.appendingPathComponent(VaultStoreFixture.newDiskName())
        try Data("stray".utf8).write(to: strayInTrash)
        let before = vault.trashDiskNames()
        await vault.store.sweepOrphans()
        #expect(vault.trashDiskNames() == before)
        #expect(exists(strayInTrash))
        #expect(try await vault.store.trashContents().map(\.name) == ["a.txt"])
    }

    @Test("sweepOrphans does nothing in plaintext mode")
    func sweepSkipsPlaintextMode() async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        let uuidFile = VaultStoreFixture.newDiskName()
        try vault.diskFile(uuidFile)
        try vault.writeIndex([:], context: nil)
        let before = try vault.snapshot()
        await vault.store.sweepOrphans()
        #expect(try vault.snapshot() == before)
    }

    @Test("sweepOrphans does nothing in encrypted mode while no key is loaded")
    func sweepSkipsWithoutKey() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        try vault.diskFile(VaultStoreFixture.newDiskName(), "orphan")
        vault.keys.wipeKey()
        let before = try vault.snapshot()
        await vault.store.sweepOrphans()
        #expect(try vault.snapshot() == before)
    }

    @Test("sweepOrphans on an empty vault does nothing")
    func sweepEmptyVault() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        await vault.store.sweepOrphans()
        #expect(try vault.diskNames().isEmpty)
    }

    @Test("sweepOrphans keeps an unlisted UUID-named file that is plaintext and deletes unlisted SVC5 files")
    func sweepKeepsPlaintextUUIDNamedFiles() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let listed = try await vault.add("listed.txt", "listed", to: docs)
        let plaintextName = VaultStoreFixture.newDiskName()
        let sealedName = VaultStoreFixture.newDiskName()
        try vault.diskFile(plaintextName, "plaintext that must survive", in: docs)
        try vault.diskSealedFile(sealedName, "orphaned ciphertext", in: docs)
        await vault.store.sweepOrphans()

        #expect(try vault.content(docs.diskURL.appendingPathComponent(plaintextName)) == "plaintext that must survive")
        #expect(!exists(docs.diskURL.appendingPathComponent(sealedName)))
        #expect(exists(listed.diskURL))
    }

    @Test("sweepOrphans keeps an empty unlisted UUID-named file, which has no SVC5 header")
    func sweepKeepsEmptyUUIDNamedFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        let emptyName = VaultStoreFixture.newDiskName()
        try vault.diskFile(emptyName, "")
        await vault.store.sweepOrphans()
        #expect(exists(vault.rootURL.appendingPathComponent(emptyName)))
    }
}
