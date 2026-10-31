import Foundation
import Testing

@testable import KoalaTVault

// Assumed: `LiveVaultImporter(store: any VaultStoring, proUnlock: any ProUnlocking)`, conforming to `VaultImporting`.
@MainActor
@Suite struct LiveVaultImporterTests {
    @MainActor
    private struct Fixture {
        let store: DiskBackedVaultStore
        let source: SourceFolder
        let importer: LiveVaultImporter

        init(
            existingFiles: Int = 0, isPro: Bool = false, encrypted: Bool = false,
            scopedAccess: (any ScopedResourceAccessing)? = nil
        ) throws {
            store = try DiskBackedVaultStore(extraFileCount: existingFiles, encrypted: encrypted)
            source = try SourceFolder()
            let unlock = MockProUnlocking(isUnlocked: isPro)
            if let scopedAccess {
                importer = LiveVaultImporter(store: store, proUnlock: unlock, scopedAccess: scopedAccess)
            } else {
                importer = LiveVaultImporter(store: store, proUnlock: unlock)
            }
        }

        func cleanup() { store.cleanup(); source.cleanup() }

        func importItems(_ urls: [URL], progress: ProgressRecorder = ProgressRecorder()) async throws -> ImportResult {
            try await importer.importItems(urls, into: store.root, progress: { progress.record($0) })
        }
    }

    /// A photo whose loader writes a fresh file alone in its own store temp folder and records what happened.
    private final class PhotoProbe: @unchecked Sendable {
        private let store: DiskBackedVaultStore
        init(store: DiskBackedVaultStore) { self.store = store }
        private let lock = NSLock()
        private var _loads = 0, _running = 0, _maxRunning = 0
        private var _tempFiles: [URL] = []
        var loads: Int { lock.withLock { _loads } }
        var maxRunning: Int { lock.withLock { _maxRunning } }
        var tempFiles: [URL] { lock.withLock { _tempFiles } }

        func source(id: String?, name: String, content: String, fails: Bool = false) -> PhotoImportSource {
            PhotoImportSource(assetID: id, suggestedName: name) { [self] in
                lock.withLock {
                    _loads += 1
                    _running += 1
                    _maxRunning = max(_maxRunning, _running)
                }
                defer { lock.withLock { _running -= 1 } }
                try await Task.sleep(nanoseconds: 5_000_000)
                if fails { throw ImportError.unreadableSource(name) }
                let dir = try store.makeTempDirectory()
                let url = dir.appendingPathComponent(name.isEmpty ? "x" : "tmp-" + UUID().uuidString)
                try Data(content.utf8).write(to: url)
                lock.withLock { _tempFiles.append(url) }
                return url
            }
        }
    }

    // MARK: checkAllowed

    @Test("checkAllowed always passes for Pro")
    func checkAllowedPro() async throws {
        let fixture = try Fixture(existingFiles: 500, isPro: true)
        defer { fixture.cleanup() }
        try await fixture.importer.checkAllowed(adding: 100)
    }

    @Test("checkAllowed passes for a free user reaching exactly 100")
    func checkAllowedExactly100() async throws {
        let fixture = try Fixture(existingFiles: 98)
        defer { fixture.cleanup() }
        try await fixture.importer.checkAllowed(adding: 2)
    }

    @Test("checkAllowed throws fileLimitReached(limit: 100) for a free user passing 100")
    func checkAllowedOver() async throws {
        let fixture = try Fixture(existingFiles: 98)
        defer { fixture.cleanup() }
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            try await fixture.importer.checkAllowed(adding: 3)
        }
    }

    // MARK: importItems

    @Test("Importing files adds each one through the store with its own name")
    func importsFilesThroughAddFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let firstItem = try fixture.source.file("a.txt", content: "A")
        let secondItem = try fixture.source.file("b.txt", content: "B")
        let result = try await fixture.importItems([firstItem, secondItem])
        #expect(result == ImportResult(imported: 2, skippedDuplicates: 0, failed: 0))
        #expect(Set(fixture.store.addCalls.map(\.name)) == ["a.txt", "b.txt"])
        #expect(fixture.store.readString("a.txt") == "A")
        #expect(fixture.store.readString("b.txt") == "B")
    }

    @Test("Importing a folder recreates its structure")
    func importsFolderStructure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.source.file("Trip/a.txt", content: "A")
        try fixture.source.file("Trip/Sub/b.txt", content: "B")
        try fixture.source.folder("Trip/Empty")
        let result = try await fixture.importItems([fixture.source.url.appendingPathComponent("Trip")])
        #expect(result.imported == 2)
        #expect(result.failed == 0)
        let paths = fixture.store.allPaths()
        #expect(paths.contains("Trip/"))
        #expect(paths.contains("Trip/Sub/"))
        #expect(paths.contains("Trip/a.txt"))
        #expect(paths.contains("Trip/Sub/b.txt"))
        #expect(fixture.store.readString("Trip/Sub/b.txt") == "B")
    }

    @Test("Same name and same content is skipped and counted as a duplicate")
    func skipsDuplicate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("a.txt", content: "same")
        let url = try fixture.source.file("a.txt", content: "same")
        let result = try await fixture.importItems([url])
        #expect(result == ImportResult(imported: 0, skippedDuplicates: 1, failed: 0))
        #expect(fixture.store.allPaths() == ["a.txt"])
    }

    @Test("Same name with different content is stored with a ' 1' suffix")
    func sameNameDifferentContentGetsSuffix() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("a.txt", content: "old")
        let url = try fixture.source.file("a.txt", content: "new")
        let result = try await fixture.importItems([url])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.readString("a.txt") == "old")
        #expect(fixture.store.readString("a 1.txt") == "new")
    }

    @Test("Duplicate check in an encrypted vault skips a same-content file and removes its temp copy")
    func encryptedVaultDuplicateCleansUp() async throws {
        let fixture = try Fixture(encrypted: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("a.txt", content: "same")
        let url = try fixture.source.file("a.txt", content: "same")
        let result = try await fixture.importItems([url])
        #expect(result == ImportResult(imported: 0, skippedDuplicates: 1, failed: 0))
        #expect(fixture.store.tempDirectoriesCreated >= 1)
        #expect(fixture.store.leftoverTempFiles.isEmpty)
    }

    @Test("Duplicate check in an encrypted vault gives a different-content file a ' 1' suffix and cleans up")
    func encryptedVaultDifferentContentCleansUp() async throws {
        let fixture = try Fixture(encrypted: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("a.txt", content: "old")
        let url = try fixture.source.file("a.txt", content: "new")
        let result = try await fixture.importItems([url])
        #expect(result.imported == 1)
        #expect(fixture.store.readString("a 1.txt") == "new")
        #expect(fixture.store.leftoverTempFiles.isEmpty)
    }

    @Test("Progress runs from 0 to 1 without going backwards")
    func progressRunsZeroToOne() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let urls = try (1...4).map { try fixture.source.file("f\($0).txt", content: "c\($0)") }
        let progress = ProgressRecorder()
        _ = try await fixture.importItems(urls, progress: progress)
        let values = progress.recorded
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Progress with a folder, a skipped duplicate and an only-dots pick runs 0 to 1 without going backwards")
    func progressWithMixedPicks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("dup.txt", content: "same")
        try fixture.source.file("Trip/a.txt", content: "A")
        try fixture.source.file("Trip/Sub/b.txt", content: "B")
        let urls = [
            fixture.source.url.appendingPathComponent("Trip"),
            try fixture.source.file("dup.txt", content: "same"),
            try fixture.source.file("...", content: "dots"),
            try fixture.source.file("plain.txt", content: "P")
        ]
        let progress = ProgressRecorder()
        let result = try await fixture.importItems(urls, progress: progress)
        #expect(result == ImportResult(imported: 3, skippedDuplicates: 1, failed: 1))
        let values = progress.recorded
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("A picked folder that cannot be listed throws unreadableSource with the folder's name")
    func unlistableFolderThrowsUnreadableSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.source.folder("Trip")
        try fixture.source.file("Trip/a.txt", content: "A")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        await #expect(throws: ImportError.unreadableSource("Trip")) {
            _ = try await fixture.importItems([folder])
        }
    }

    @Test("A failure part-way keeps the earlier files and rethrows the error")
    func failurePartWayKeepsEarlierFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let firstItem = try fixture.source.file("a.txt", content: "A")
        let secondItem = try fixture.source.file("b.txt", content: "B")
        let thirdItem = try fixture.source.file("c.txt", content: "C")
        fixture.store.failAdding("b.txt")
        await #expect(throws: VaultStoreError.io("boom")) {
            _ = try await fixture.importItems([firstItem, secondItem, thirdItem])
        }
        #expect(fixture.store.readString("a.txt") == "A")
        #expect(fixture.store.readString("b.txt") == nil)
    }

    @Test("A free import passing 100 files throws fileLimitReached and imports nothing")
    func overLimitImportsNothing() async throws {
        let fixture = try Fixture(existingFiles: 98)
        defer { fixture.cleanup() }
        let urls = try (1...3).map { try fixture.source.file("f\($0).txt", content: "c\($0)") }
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await fixture.importItems(urls)
        }
        #expect(fixture.store.addCalls.isEmpty)
        #expect(fixture.store.allPaths().isEmpty)
    }

    @Test("The limit check counts the files inside folders recursively")
    func limitCountsFolderFilesRecursively() async throws {
        let fixture = try Fixture(existingFiles: 97)
        defer { fixture.cleanup() }
        try fixture.source.file("Trip/a.txt")
        try fixture.source.file("Trip/Sub/b.txt", content: "b")
        try fixture.source.file("Trip/Sub/Deep/c.txt", content: "c")
        try fixture.source.file("Trip/Sub/Deep/d.txt", content: "d")
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await fixture.importItems([fixture.source.url.appendingPathComponent("Trip")])
        }
        #expect(fixture.store.addCalls.isEmpty)
    }

    @Test("A free import reaching exactly 100 files succeeds")
    func exactlyAtLimitSucceeds() async throws {
        let fixture = try Fixture(existingFiles: 98)
        defer { fixture.cleanup() }
        let urls = try (1...2).map { try fixture.source.file("f\($0).txt", content: "c\($0)") }
        let result = try await fixture.importItems(urls)
        #expect(result.imported == 2)
    }

    @Test("A Pro user can import past 100 files")
    func proImportsPastLimit() async throws {
        let fixture = try Fixture(existingFiles: 150, isPro: true)
        defer { fixture.cleanup() }
        let url = try fixture.source.file("a.txt")
        let result = try await fixture.importItems([url])
        #expect(result.imported == 1)
    }

    @Test("Plain (not security-scoped) URLs import normally")
    func plainURLsImport() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = try fixture.source.file("a.txt", content: "A")
        let result = try await fixture.importItems([url])
        #expect(result.imported == 1)
    }

    // MARK: Folder merge

    @Test("A picked folder named like an existing folder merges into it without a ' 1' folder")
    func mergesIntoExistingFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("Trip/old.txt", content: "old")
        try fixture.source.file("Trip/new.txt", content: "new")
        let result = try await fixture.importItems([fixture.source.url.appendingPathComponent("Trip")])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 0, failed: 0))
        let paths = fixture.store.allPaths()
        #expect(paths.contains("Trip/new.txt"))
        #expect(paths.contains("Trip/old.txt"))
        #expect(!paths.contains("Trip 1/"))
        #expect(paths.filter { $0.hasPrefix("Trip 1") }.isEmpty)
        #expect(fixture.store.readString("Trip/new.txt") == "new")
    }

    @Test("A nested subfolder named like an existing subfolder merges into it")
    func mergesNestedSubfolder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("Trip/Sub/old.txt", content: "old")
        try fixture.source.file("Trip/Sub/new.txt", content: "new")
        let result = try await fixture.importItems([fixture.source.url.appendingPathComponent("Trip")])
        #expect(result.imported == 1)
        let paths = fixture.store.allPaths()
        #expect(paths.contains("Trip/Sub/new.txt"))
        #expect(paths.contains("Trip/Sub/old.txt"))
        #expect(!paths.contains { $0.contains("Trip 1") })
        #expect(!paths.contains { $0.contains("Sub 1") })
    }

    @Test("A file already in the merged folder with the same name and content is skipped and counted")
    func mergedFolderSkipsDuplicate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("Trip/a.txt", content: "same")
        try fixture.source.file("Trip/a.txt", content: "same")
        try fixture.source.file("Trip/b.txt", content: "B")
        let result = try await fixture.importItems([fixture.source.url.appendingPathComponent("Trip")])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 1, failed: 0))
        let paths = fixture.store.allPaths()
        #expect(!paths.contains("Trip/a 1.txt"))
        #expect(paths.contains("Trip/b.txt"))
        #expect(!paths.contains { $0.contains("Trip 1") })
    }

    @Test("A picked folder whose name belongs to an existing file gets a free name")
    func folderNamedLikeFileGetsFreeName() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("Trip", content: "i am a file")
        try fixture.source.file("Trip/a.txt", content: "A")
        let result = try await fixture.importItems([fixture.source.url.appendingPathComponent("Trip")])
        #expect(result.imported == 1)
        #expect(fixture.store.readString("Trip") == "i am a file")
        #expect(fixture.store.readString("Trip 1/a.txt") == "A")
        #expect(fixture.store.allPaths().contains("Trip 1/"))
    }

    // MARK: Security-scoped URLs

    @Test("Every picked URL is opened and closed exactly once after a successful import")
    func scopedURLsClosedOnSuccess() async throws {
        let access = RecordingScopedAccess()
        let fixture = try Fixture(scopedAccess: access)
        defer { fixture.cleanup() }
        let firstItem = try fixture.source.file("a.txt", content: "A")
        let folder = try fixture.source.file("Trip/b.txt", content: "B").deletingLastPathComponent()
        _ = try await fixture.importItems([firstItem, folder])
        for url in [firstItem, folder] {
            #expect(access.startCount(url) == 1)
            #expect(access.stopCount(url) == 1)
        }
    }

    @Test("Every opened URL is closed exactly once when an import fails part-way")
    func scopedURLsClosedOnFailure() async throws {
        let access = RecordingScopedAccess()
        let fixture = try Fixture(scopedAccess: access)
        defer { fixture.cleanup() }
        let firstItem = try fixture.source.file("a.txt", content: "A")
        let secondItem = try fixture.source.file("b.txt", content: "B")
        let thirdItem = try fixture.source.file("c.txt", content: "C")
        fixture.store.failAdding("b.txt")
        await #expect(throws: VaultStoreError.io("boom")) {
            _ = try await fixture.importItems([firstItem, secondItem, thirdItem])
        }
        for url in access.started {
            #expect(access.stopCount(url) == 1)
            #expect(access.startCount(url) == 1)
        }
        #expect(access.stopped.count == access.started.count)
        #expect(access.startCount(firstItem) == 1)
    }

    @Test("A URL that refuses access is not stopped, while the others are closed once")
    func refusedURLIsNotStopped() async throws {
        let folder0 = try SourceFolder()
        defer { folder0.cleanup() }
        let refused = try folder0.file("refused.txt", content: "R")
        let granted = try folder0.file("granted.txt", content: "G")
        let access = RecordingScopedAccess(refusing: [refused])
        let fixture = try Fixture(scopedAccess: access)
        defer { fixture.cleanup() }
        _ = try? await fixture.importItems([refused, granted])
        #expect(access.startCount(refused) == 1)
        #expect(access.stopCount(refused) == 0)
        #expect(access.startCount(granted) == 1)
        #expect(access.stopCount(granted) == 1)
    }

    @Test("Opened URLs are closed when the import is refused for passing the free limit")
    func scopedURLsClosedOnLimit() async throws {
        let access = RecordingScopedAccess()
        let fixture = try Fixture(existingFiles: 99, scopedAccess: access)
        defer { fixture.cleanup() }
        let firstItem = try fixture.source.file("a.txt", content: "A")
        let secondItem = try fixture.source.file("b.txt", content: "B")
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await fixture.importItems([firstItem, secondItem])
        }
        #expect(access.stopped.count == access.started.count)
        for url in access.started { #expect(access.stopCount(url) == 1) }
    }

    // MARK: Names starting with "."

    @Test(
        "A directly picked file loses its leading dots before it is stored",
        arguments: [(".env", "env"), ("..env", "env"), (".trash", "trash"), (".gitignore.txt", "gitignore.txt")])
    func pickedFileLosesLeadingDots(picked: String, stored: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = try fixture.source.file(picked, content: "X")
        let result = try await fixture.importItems([url])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.addCalls.map(\.name) == [stored])
        #expect(fixture.store.readString(stored) == "X")
    }

    @Test("A directly picked folder loses its leading dots and keeps its visible contents")
    func pickedFolderLosesLeadingDots() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.source.file(".trash/a.txt", content: "A")
        let result = try await fixture.importItems([fixture.source.url.appendingPathComponent(".trash")])
        #expect(result.imported == 1)
        let paths = fixture.store.allPaths()
        #expect(paths.contains("trash/"))
        #expect(paths.contains("trash/a.txt"))
        #expect(!paths.contains(".trash/"))
    }

    @Test("The duplicate check uses the name with the dots removed")
    func duplicateCheckUsesNewName() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("env", content: "same")
        let url = try fixture.source.file(".env", content: "same")
        let result = try await fixture.importItems([url])
        #expect(result == ImportResult(imported: 0, skippedDuplicates: 1, failed: 0))
        #expect(fixture.store.allPaths() == ["env"])
    }

    @Test("A dot-named file with different content than the stored one gets a ' 1' suffix")
    func dotNamedFileSameNameDifferentContent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("env", content: "old")
        let url = try fixture.source.file(".env", content: "new")
        _ = try await fixture.importItems([url])
        #expect(fixture.store.readString("env 1") == "new")
    }

    @Test("Directly picked dot-named files count toward the limit")
    func dotNamedFilesCountTowardLimit() async throws {
        let fixture = try Fixture(existingFiles: 99)
        defer { fixture.cleanup() }
        let url = try fixture.source.file(".env")
        let okItem = try fixture.source.file("ok.txt", content: "ok")
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await fixture.importItems([url, okItem])
        }
        #expect(fixture.store.addCalls.isEmpty)
    }

    @Test("A picked name made only of dots counts as failed and imports nothing")
    func onlyDotsFileFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = try fixture.source.file("...", content: "X")
        let good = try fixture.source.file("good.txt", content: "G")
        let result = try await fixture.importItems([url, good])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 0, failed: 1))
        #expect(fixture.store.allPaths() == ["good.txt"])
    }

    @Test("Hidden files and folders inside a picked folder are skipped, uncounted and unreported")
    func hiddenItemsInsideFolderAreSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.source.file("Trip/visible.txt", content: "V")
        try fixture.source.file("Trip/.DS_Store", content: "junk")
        try fixture.source.file("Trip/.hidden/inner.txt", content: "H")
        try fixture.source.file("Trip/Sub/.secret", content: "S")
        try fixture.source.file("Trip/Sub/shown.txt", content: "T")
        let result = try await fixture.importItems([fixture.source.url.appendingPathComponent("Trip")])
        #expect(result == ImportResult(imported: 2, skippedDuplicates: 0, failed: 0))
        let paths = fixture.store.allPaths()
        #expect(paths.contains("Trip/visible.txt"))
        #expect(paths.contains("Trip/Sub/shown.txt"))
        #expect(!paths.contains { $0.contains(".DS_Store") || $0.contains(".hidden") || $0.contains(".secret") })
        #expect(!paths.contains { $0.contains("inner.txt") })
        #expect(
            !fixture.store.addCalls.map(\.name).contains { $0.hasPrefix(".") || $0 == "inner.txt" || $0 == "secret" })
    }

    @Test("Hidden items inside a picked folder are not counted toward the limit")
    func hiddenItemsNotCountedTowardLimit() async throws {
        let fixture = try Fixture(existingFiles: 99)
        defer { fixture.cleanup() }
        try fixture.source.file("Trip/visible.txt", content: "V")
        try fixture.source.file("Trip/.DS_Store", content: "junk")
        try fixture.source.file("Trip/.hidden/a.txt", content: "a")
        try fixture.source.file("Trip/.hidden/b.txt", content: "b")
        let result = try await fixture.importItems([fixture.source.url.appendingPathComponent("Trip")])
        #expect(result.imported == 1)
    }

    // MARK: importPhotos

    @Test("importPhotos checks the limit for the count first and loads nothing when over")
    func photosLimitFirst() async throws {
        let fixture = try Fixture(existingFiles: 99)
        defer { fixture.cleanup() }
        let probe = PhotoProbe(store: fixture.store)
        let photo1 = probe.source(id: "1", name: "a.jpg", content: "a")
        let photo2 = probe.source(id: "2", name: "b.jpg", content: "b")
        let assets = [photo1, photo2]
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await fixture.importer.importPhotos(assets, into: fixture.store.root)
        }
        #expect(probe.loads == 0)
        #expect(fixture.store.addCalls.isEmpty)
    }

    @Test("importPhotos stores each photo under its suggested name and returns its asset ID")
    func photosImported() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = PhotoProbe(store: fixture.store)
        let photo1 = probe.source(id: "id-1", name: "a.jpg", content: "a")
        let photo2 = probe.source(id: "id-2", name: "b.mov", content: "b")
        let assets = [photo1, photo2]
        let result = try await fixture.importer.importPhotos(assets, into: fixture.store.root)
        #expect(result == PhotoImportResult(importedAssetIDs: ["id-1", "id-2"], failed: 0))
        #expect(fixture.store.readString("a.jpg") == "a")
        #expect(fixture.store.readString("b.mov") == "b")
    }

    @Test("importPhotos imports one photo at a time")
    func photosOneAtATime() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = PhotoProbe(store: fixture.store)
        let assets = (1...5).map { probe.source(id: "id-\($0)", name: "p\($0).jpg", content: "c\($0)") }
        _ = try await fixture.importer.importPhotos(assets, into: fixture.store.root)
        #expect(probe.loads == 5)
        #expect(probe.maxRunning == 1)
    }

    @Test("A photo already in the vault (same name and content) still reports its asset ID")
    func photosAlreadyInVaultReported() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("a.jpg", content: "same")
        let probe = PhotoProbe(store: fixture.store)
        let photo1 = probe.source(id: "dup", name: "a.jpg", content: "same")
        let photo2 = probe.source(id: "new", name: "b.jpg", content: "b")
        let assets = [photo1, photo2]
        let result = try await fixture.importer.importPhotos(assets, into: fixture.store.root)
        #expect(result.importedAssetIDs == ["dup", "new"])
        #expect(result.failed == 0)
        #expect(fixture.store.allPaths() == ["a.jpg", "b.jpg"])
    }

    @Test("A photo with the same name and different content is stored with a ' 1' suffix")
    func photoSameNameDifferentContent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("a.jpg", content: "old")
        let probe = PhotoProbe(store: fixture.store)
        let result = try await fixture.importer.importPhotos(
            [probe.source(id: "x", name: "a.jpg", content: "new")], into: fixture.store.root)
        #expect(result.importedAssetIDs == ["x"])
        #expect(fixture.store.readString("a 1.jpg") == "new")
    }

    @Test("A photo that fails to load counts as failed and the others still import")
    func photoLoadFailureCounted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = PhotoProbe(store: fixture.store)
        let photo1 = probe.source(id: "ok-1", name: "a.jpg", content: "a")
        let photo2 = probe.source(id: "bad", name: "b.jpg", content: "b", fails: true)
        let photo3 = probe.source(id: "ok-2", name: "c.jpg", content: "c")
        let assets = [photo1, photo2, photo3]
        let result = try await fixture.importer.importPhotos(assets, into: fixture.store.root)
        #expect(result.importedAssetIDs == ["ok-1", "ok-2"])
        #expect(result.failed == 1)
    }

    @Test("A photo the store refuses to add counts as failed")
    func photoStoreFailureCounted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.failAdding("b.jpg")
        let probe = PhotoProbe(store: fixture.store)
        let photo1 = probe.source(id: "ok", name: "a.jpg", content: "a")
        let photo2 = probe.source(id: "bad", name: "b.jpg", content: "b")
        let assets = [photo1, photo2]
        let result = try await fixture.importer.importPhotos(assets, into: fixture.store.root)
        #expect(result.importedAssetIDs == ["ok"])
        #expect(result.failed == 1)
    }

    @Test("A photo without an asset ID imports but adds no ID")
    func photoWithoutAssetID() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = PhotoProbe(store: fixture.store)
        let result = try await fixture.importer.importPhotos(
            [probe.source(id: nil, name: "a.jpg", content: "a")], into: fixture.store.root)
        #expect(result == PhotoImportResult(importedAssetIDs: [], failed: 0))
        #expect(fixture.store.readString("a.jpg") == "a")
    }

    @Test("Temporary photo copies are removed after importing, duplicates and failures included")
    func photoTempCopiesRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("dup.jpg", content: "same")
        fixture.store.failAdding("bad.jpg")
        let probe = PhotoProbe(store: fixture.store)
        let photo1 = probe.source(id: "1", name: "a.jpg", content: "a")
        let photo2 = probe.source(id: "2", name: "dup.jpg", content: "same")
        let photo3 = probe.source(id: "3", name: "bad.jpg", content: "b")
        let assets = [photo1, photo2, photo3]
        _ = try await fixture.importer.importPhotos(assets, into: fixture.store.root)
        #expect(probe.tempFiles.count == 3)
        for url in probe.tempFiles {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("A photo whose file is outside the store's temp area leaves that file and its folder alone")
    func photoOutsideTempAreaIsLeftAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outside = try fixture.source.file("Elsewhere/original.jpg", content: "pic")
        let folder = outside.deletingLastPathComponent()
        let photo = PhotoImportSource(assetID: "id", suggestedName: "p.jpg") { outside }
        let result = try await fixture.importer.importPhotos([photo], into: fixture.store.root)
        #expect(result == PhotoImportResult(importedAssetIDs: ["id"], failed: 0))
        #expect(fixture.store.readString("p.jpg") == "pic")
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("A photo's suggested name loses its leading dots before storing and counts toward the limit")
    func photoNameLosesLeadingDots() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = PhotoProbe(store: fixture.store)
        let result = try await fixture.importer.importPhotos(
            [probe.source(id: "id", name: ".hidden.jpg", content: "h")], into: fixture.store.root)
        #expect(result.importedAssetIDs == ["id"])
        #expect(fixture.store.addCalls.map(\.name) == ["hidden.jpg"])
        #expect(fixture.store.readString("hidden.jpg") == "h")
    }

    @Test("A dot-named photo counts toward the limit")
    func dotNamedPhotoCountsTowardLimit() async throws {
        let fixture = try Fixture(existingFiles: 99)
        defer { fixture.cleanup() }
        let probe = PhotoProbe(store: fixture.store)
        let photo1 = probe.source(id: "1", name: ".a.jpg", content: "a")
        let photo2 = probe.source(id: "2", name: "b.jpg", content: "b")
        let assets = [photo1, photo2]
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await fixture.importer.importPhotos(assets, into: fixture.store.root)
        }
    }

    @Test("A photo's duplicate check uses the name with dots removed")
    func photoDuplicateCheckUsesNewName() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.seed("hidden.jpg", content: "same")
        let probe = PhotoProbe(store: fixture.store)
        let result = try await fixture.importer.importPhotos(
            [probe.source(id: "id", name: ".hidden.jpg", content: "same")], into: fixture.store.root)
        #expect(result.importedAssetIDs == ["id"])
        #expect(fixture.store.allPaths() == ["hidden.jpg"])
    }

    @Test("A photo whose name is only dots counts as failed with nothing imported")
    func onlyDotsPhotoFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = PhotoProbe(store: fixture.store)
        let photo1 = probe.source(id: "bad", name: "...", content: "x")
        let photo2 = probe.source(id: "ok", name: "a.jpg", content: "a")
        let assets = [photo1, photo2]
        let result = try await fixture.importer.importPhotos(assets, into: fixture.store.root)
        #expect(result == PhotoImportResult(importedAssetIDs: ["ok"], failed: 1))
        #expect(fixture.store.allPaths() == ["a.jpg"])
    }
}
