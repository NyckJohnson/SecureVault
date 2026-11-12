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

    // MARK: - Housekeeping never holds up browsing

    @Test("A listing asked for while sweepOrphans runs finishes before the sweep does, and the sweep deletes the same orphans")
    func listingRunsBetweenSweepSteps() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        try await vault.add("r.txt")
        var folders: [VaultDirectory] = []
        var orphans: [URL] = []
        for index in 0..<40 {
            let folder = try vault.folder("F\(index)")
            try await vault.add("a.txt", to: folder)
            orphans.append(try vault.diskSealedFile(VaultStoreFixture.newDiskName(), "orphan", in: folder))
            folders.append(folder)
        }
        let gate = HousekeepingGate()
        failing.decryptErrorFor = { _ in
            gate.pass()
            return nil
        }
        let store = vault.store
        let target = folders[0]
        let log = EventLog()

        let sweep = Task {
            await store.sweepOrphans()
            log.add("sweep")
        }
        #expect(await gate.waitUntilEntered())
        let listing = Task {
            let items = try await store.contents(of: target, sortedBy: .name, .ascending)
            log.add("listing")
            return items.map(\.name)
        }
        gate.release()
        let listed = try await listing.value
        await sweep.value

        #expect(log.events == ["listing", "sweep"])
        #expect(listed == ["a.txt"])
        #expect(orphans.allSatisfy { !exists($0) })
        #expect(try await vault.names(target) == ["a.txt"])
    }

    @Test("sweepOrphans skips a folder removed while it runs and still sweeps the others without failing")
    func sweepSkipsFoldersRemovedBetweenSteps() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        try await vault.add("r.txt")
        let rootOrphan = vault.rootURL.appendingPathComponent(VaultStoreFixture.newDiskName())
        try HeaderAwareTestCipher.sealed(Data("orphan".utf8)).write(to: rootOrphan)
        var survivorOrphans: [URL] = []
        var doomed: [URL] = []
        for index in 0..<10 {
            let folder = try vault.folder("F\(index)")
            try await vault.add("a.txt", to: folder)
            let orphan = try vault.diskSealedFile(VaultStoreFixture.newDiskName(), "orphan", in: folder)
            if index >= 5 { doomed.append(folder.diskURL) } else { survivorOrphans.append(orphan) }
        }
        let removed = doomed
        let gate = HousekeepingGate(waits: false) {
            for url in removed { try? FileManager.default.removeItem(at: url) }
        }
        failing.decryptErrorFor = { _ in
            gate.pass()
            return nil
        }

        await vault.store.sweepOrphans()

        #expect(!exists(rootOrphan))
        #expect(survivorOrphans.allSatisfy { !exists($0) })
        #expect(doomed.allSatisfy { !exists($0) })
    }
}
