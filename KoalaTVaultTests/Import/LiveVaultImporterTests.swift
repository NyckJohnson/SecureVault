import Foundation
import Testing

@testable import KoalaTVault

// Assumed: `LiveVaultImporter(store: any VaultStoring, proUnlock: any ProUnlocking)`, conforming to `VaultImporting`.
@MainActor
@Suite struct LiveVaultImporterTests {
    private struct Fixture {
        let store: DiskBackedVaultStore
        let source: SourceFolder
        let importer: LiveVaultImporter

        init(existingFiles: Int = 0, isPro: Bool = false, encrypted: Bool = false) throws {
            store = try DiskBackedVaultStore(extraFileCount: existingFiles, encrypted: encrypted)
            source = try SourceFolder()
            importer = LiveVaultImporter(store: store, proUnlock: MockProUnlocking(isUnlocked: isPro))
        }

        func cleanup() { store.cleanup(); source.cleanup() }

        func importItems(_ urls: [URL], progress: ProgressRecorder = ProgressRecorder()) async throws -> ImportResult {
            try await importer.importItems(urls, into: store.root, progress: { progress.record($0) })
        }
    }

    /// A photo whose loader writes a fresh temp file (in its own folder) and records what happened.
    private final class PhotoProbe: @unchecked Sendable {
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
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PhotoTemp-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        let f = try Fixture(existingFiles: 500, isPro: true)
        defer { f.cleanup() }
        try await f.importer.checkAllowed(adding: 100)
    }

    @Test("checkAllowed passes for a free user reaching exactly 100")
    func checkAllowedExactly100() async throws {
        let f = try Fixture(existingFiles: 98)
        defer { f.cleanup() }
        try await f.importer.checkAllowed(adding: 2)
    }

    @Test("checkAllowed throws fileLimitReached(limit: 100) for a free user passing 100")
    func checkAllowedOver() async throws {
        let f = try Fixture(existingFiles: 98)
        defer { f.cleanup() }
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            try await f.importer.checkAllowed(adding: 3)
        }
    }

    // MARK: importItems

    @Test("Importing files adds each one through the store with its own name")
    func importsFilesThroughAddFile() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let a = try f.source.file("a.txt", content: "A")
        let b = try f.source.file("b.txt", content: "B")
        let result = try await f.importItems([a, b])
        #expect(result == ImportResult(imported: 2, skippedDuplicates: 0, failed: 0))
        #expect(Set(f.store.addCalls.map(\.name)) == ["a.txt", "b.txt"])
        #expect(f.store.readString("a.txt") == "A")
        #expect(f.store.readString("b.txt") == "B")
    }

    @Test("Importing a folder recreates its structure")
    func importsFolderStructure() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.source.file("Trip/a.txt", content: "A")
        try f.source.file("Trip/Sub/b.txt", content: "B")
        try f.source.folder("Trip/Empty")
        let result = try await f.importItems([f.source.url.appendingPathComponent("Trip")])
        #expect(result.imported == 2)
        #expect(result.failed == 0)
        let paths = f.store.allPaths()
        #expect(paths.contains("Trip/"))
        #expect(paths.contains("Trip/Sub/"))
        #expect(paths.contains("Trip/a.txt"))
        #expect(paths.contains("Trip/Sub/b.txt"))
        #expect(f.store.readString("Trip/Sub/b.txt") == "B")
    }

    @Test("Same name and same content is skipped and counted as a duplicate")
    func skipsDuplicate() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.store.seed("a.txt", content: "same")
        let url = try f.source.file("a.txt", content: "same")
        let result = try await f.importItems([url])
        #expect(result == ImportResult(imported: 0, skippedDuplicates: 1, failed: 0))
        #expect(f.store.allPaths() == ["a.txt"])
    }

    @Test("Same name with different content is stored with a ' 1' suffix")
    func sameNameDifferentContentGetsSuffix() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.store.seed("a.txt", content: "old")
        let url = try f.source.file("a.txt", content: "new")
        let result = try await f.importItems([url])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 0, failed: 0))
        #expect(f.store.readString("a.txt") == "old")
        #expect(f.store.readString("a 1.txt") == "new")
    }

    @Test("Duplicate check in an encrypted vault skips a same-content file and removes its temp copy")
    func encryptedVaultDuplicateCleansUp() async throws {
        let f = try Fixture(encrypted: true)
        defer { f.cleanup() }
        try f.store.seed("a.txt", content: "same")
        let url = try f.source.file("a.txt", content: "same")
        let result = try await f.importItems([url])
        #expect(result == ImportResult(imported: 0, skippedDuplicates: 1, failed: 0))
        #expect(f.store.tempDirectoriesCreated >= 1)
        #expect(f.store.leftoverTempFiles.isEmpty)
    }

    @Test("Duplicate check in an encrypted vault gives a different-content file a ' 1' suffix and cleans up")
    func encryptedVaultDifferentContentCleansUp() async throws {
        let f = try Fixture(encrypted: true)
        defer { f.cleanup() }
        try f.store.seed("a.txt", content: "old")
        let url = try f.source.file("a.txt", content: "new")
        let result = try await f.importItems([url])
        #expect(result.imported == 1)
        #expect(f.store.readString("a 1.txt") == "new")
        #expect(f.store.leftoverTempFiles.isEmpty)
    }

    @Test("Progress runs from 0 to 1 without going backwards")
    func progressRunsZeroToOne() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let urls = try (1...4).map { try f.source.file("f\($0).txt", content: "c\($0)") }
        let progress = ProgressRecorder()
        _ = try await f.importItems(urls, progress: progress)
        let values = progress.recorded
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("A failure part-way keeps the earlier files and rethrows the error")
    func failurePartWayKeepsEarlierFiles() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let a = try f.source.file("a.txt", content: "A")
        let b = try f.source.file("b.txt", content: "B")
        let c = try f.source.file("c.txt", content: "C")
        f.store.failAdding("b.txt")
        await #expect(throws: VaultStoreError.io("boom")) {
            _ = try await f.importItems([a, b, c])
        }
        #expect(f.store.readString("a.txt") == "A")
        #expect(f.store.readString("b.txt") == nil)
    }

    @Test("A free import passing 100 files throws fileLimitReached and imports nothing")
    func overLimitImportsNothing() async throws {
        let f = try Fixture(existingFiles: 98)
        defer { f.cleanup() }
        let urls = try (1...3).map { try f.source.file("f\($0).txt", content: "c\($0)") }
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await f.importItems(urls)
        }
        #expect(f.store.addCalls.isEmpty)
        #expect(f.store.allPaths().isEmpty)
    }

    @Test("The limit check counts the files inside folders recursively")
    func limitCountsFolderFilesRecursively() async throws {
        let f = try Fixture(existingFiles: 97)
        defer { f.cleanup() }
        try f.source.file("Trip/a.txt")
        try f.source.file("Trip/Sub/b.txt", content: "b")
        try f.source.file("Trip/Sub/Deep/c.txt", content: "c")
        try f.source.file("Trip/Sub/Deep/d.txt", content: "d")
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await f.importItems([f.source.url.appendingPathComponent("Trip")])
        }
        #expect(f.store.addCalls.isEmpty)
    }

    @Test("A free import reaching exactly 100 files succeeds")
    func exactlyAtLimitSucceeds() async throws {
        let f = try Fixture(existingFiles: 98)
        defer { f.cleanup() }
        let urls = try (1...2).map { try f.source.file("f\($0).txt", content: "c\($0)") }
        let result = try await f.importItems(urls)
        #expect(result.imported == 2)
    }

    @Test("A Pro user can import past 100 files")
    func proImportsPastLimit() async throws {
        let f = try Fixture(existingFiles: 150, isPro: true)
        defer { f.cleanup() }
        let url = try f.source.file("a.txt")
        let result = try await f.importItems([url])
        #expect(result.imported == 1)
    }

    @Test("Plain (not security-scoped) URLs import normally")
    func plainURLsImport() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let url = try f.source.file("a.txt", content: "A")
        let result = try await f.importItems([url])
        #expect(result.imported == 1)
    }

    // MARK: Names starting with "."

    @Test("A directly picked file loses its leading dots before it is stored",
          arguments: [(".env", "env"), ("..env", "env"), (".trash", "trash"), (".gitignore.txt", "gitignore.txt")])
    func pickedFileLosesLeadingDots(picked: String, stored: String) async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let url = try f.source.file(picked, content: "X")
        let result = try await f.importItems([url])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 0, failed: 0))
        #expect(f.store.addCalls.map(\.name) == [stored])
        #expect(f.store.readString(stored) == "X")
    }

    @Test("A directly picked folder loses its leading dots and keeps its visible contents")
    func pickedFolderLosesLeadingDots() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.source.file(".trash/a.txt", content: "A")
        let result = try await f.importItems([f.source.url.appendingPathComponent(".trash")])
        #expect(result.imported == 1)
        let paths = f.store.allPaths()
        #expect(paths.contains("trash/"))
        #expect(paths.contains("trash/a.txt"))
        #expect(!paths.contains(".trash/"))
    }

    @Test("The duplicate check uses the name with the dots removed")
    func duplicateCheckUsesNewName() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.store.seed("env", content: "same")
        let url = try f.source.file(".env", content: "same")
        let result = try await f.importItems([url])
        #expect(result == ImportResult(imported: 0, skippedDuplicates: 1, failed: 0))
        #expect(f.store.allPaths() == ["env"])
    }

    @Test("A dot-named file with different content than the stored one gets a ' 1' suffix")
    func dotNamedFileSameNameDifferentContent() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.store.seed("env", content: "old")
        let url = try f.source.file(".env", content: "new")
        _ = try await f.importItems([url])
        #expect(f.store.readString("env 1") == "new")
    }

    @Test("Directly picked dot-named files count toward the limit")
    func dotNamedFilesCountTowardLimit() async throws {
        let f = try Fixture(existingFiles: 99)
        defer { f.cleanup() }
        let url = try f.source.file(".env")
        let ok = try f.source.file("ok.txt", content: "ok")
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await f.importItems([url, ok])
        }
        #expect(f.store.addCalls.isEmpty)
    }

    @Test("A picked name made only of dots counts as failed and imports nothing")
    func onlyDotsFileFails() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let url = try f.source.file("...", content: "X")
        let good = try f.source.file("good.txt", content: "G")
        let result = try await f.importItems([url, good])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 0, failed: 1))
        #expect(f.store.allPaths() == ["good.txt"])
    }

    @Test("Hidden files and folders inside a picked folder are skipped, uncounted and unreported")
    func hiddenItemsInsideFolderAreSkipped() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.source.file("Trip/visible.txt", content: "V")
        try f.source.file("Trip/.DS_Store", content: "junk")
        try f.source.file("Trip/.hidden/inner.txt", content: "H")
        try f.source.file("Trip/Sub/.secret", content: "S")
        try f.source.file("Trip/Sub/shown.txt", content: "T")
        let result = try await f.importItems([f.source.url.appendingPathComponent("Trip")])
        #expect(result == ImportResult(imported: 2, skippedDuplicates: 0, failed: 0))
        let paths = f.store.allPaths()
        #expect(paths.contains("Trip/visible.txt"))
        #expect(paths.contains("Trip/Sub/shown.txt"))
        #expect(!paths.contains { $0.contains(".DS_Store") || $0.contains(".hidden") || $0.contains(".secret") })
        #expect(!paths.contains { $0.contains("inner.txt") })
        #expect(!f.store.addCalls.map(\.name).contains { $0.hasPrefix(".") || $0 == "inner.txt" || $0 == "secret" })
    }

    @Test("Hidden items inside a picked folder are not counted toward the limit")
    func hiddenItemsNotCountedTowardLimit() async throws {
        let f = try Fixture(existingFiles: 99)
        defer { f.cleanup() }
        try f.source.file("Trip/visible.txt", content: "V")
        try f.source.file("Trip/.DS_Store", content: "junk")
        try f.source.file("Trip/.hidden/a.txt", content: "a")
        try f.source.file("Trip/.hidden/b.txt", content: "b")
        let result = try await f.importItems([f.source.url.appendingPathComponent("Trip")])
        #expect(result.imported == 1)
    }

    // MARK: importPhotos

    @Test("importPhotos checks the limit for the count first and loads nothing when over")
    func photosLimitFirst() async throws {
        let f = try Fixture(existingFiles: 99)
        defer { f.cleanup() }
        let probe = PhotoProbe()
        let assets = [
            probe.source(id: "1", name: "a.jpg", content: "a"),
            probe.source(id: "2", name: "b.jpg", content: "b"),
        ]
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await f.importer.importPhotos(assets, into: f.store.root)
        }
        #expect(probe.loads == 0)
        #expect(f.store.addCalls.isEmpty)
    }

    @Test("importPhotos stores each photo under its suggested name and returns its asset ID")
    func photosImported() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let probe = PhotoProbe()
        let assets = [
            probe.source(id: "id-1", name: "a.jpg", content: "a"),
            probe.source(id: "id-2", name: "b.mov", content: "b"),
        ]
        let result = try await f.importer.importPhotos(assets, into: f.store.root)
        #expect(result == PhotoImportResult(importedAssetIDs: ["id-1", "id-2"], failed: 0))
        #expect(f.store.readString("a.jpg") == "a")
        #expect(f.store.readString("b.mov") == "b")
    }

    @Test("importPhotos imports one photo at a time")
    func photosOneAtATime() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let probe = PhotoProbe()
        let assets = (1...5).map { probe.source(id: "id-\($0)", name: "p\($0).jpg", content: "c\($0)") }
        _ = try await f.importer.importPhotos(assets, into: f.store.root)
        #expect(probe.loads == 5)
        #expect(probe.maxRunning == 1)
    }

    @Test("A photo already in the vault (same name and content) still reports its asset ID")
    func photosAlreadyInVaultReported() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.store.seed("a.jpg", content: "same")
        let probe = PhotoProbe()
        let assets = [
            probe.source(id: "dup", name: "a.jpg", content: "same"),
            probe.source(id: "new", name: "b.jpg", content: "b"),
        ]
        let result = try await f.importer.importPhotos(assets, into: f.store.root)
        #expect(result.importedAssetIDs == ["dup", "new"])
        #expect(result.failed == 0)
        #expect(f.store.allPaths() == ["a.jpg", "b.jpg"])
    }

    @Test("A photo with the same name and different content is stored with a ' 1' suffix")
    func photoSameNameDifferentContent() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.store.seed("a.jpg", content: "old")
        let probe = PhotoProbe()
        let result = try await f.importer.importPhotos(
            [probe.source(id: "x", name: "a.jpg", content: "new")], into: f.store.root)
        #expect(result.importedAssetIDs == ["x"])
        #expect(f.store.readString("a 1.jpg") == "new")
    }

    @Test("A photo that fails to load counts as failed and the others still import")
    func photoLoadFailureCounted() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let probe = PhotoProbe()
        let assets = [
            probe.source(id: "ok-1", name: "a.jpg", content: "a"),
            probe.source(id: "bad", name: "b.jpg", content: "b", fails: true),
            probe.source(id: "ok-2", name: "c.jpg", content: "c"),
        ]
        let result = try await f.importer.importPhotos(assets, into: f.store.root)
        #expect(result.importedAssetIDs == ["ok-1", "ok-2"])
        #expect(result.failed == 1)
    }

    @Test("A photo the store refuses to add counts as failed")
    func photoStoreFailureCounted() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.store.failAdding("b.jpg")
        let probe = PhotoProbe()
        let assets = [
            probe.source(id: "ok", name: "a.jpg", content: "a"),
            probe.source(id: "bad", name: "b.jpg", content: "b"),
        ]
        let result = try await f.importer.importPhotos(assets, into: f.store.root)
        #expect(result.importedAssetIDs == ["ok"])
        #expect(result.failed == 1)
    }

    @Test("A photo without an asset ID imports but adds no ID")
    func photoWithoutAssetID() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let probe = PhotoProbe()
        let result = try await f.importer.importPhotos(
            [probe.source(id: nil, name: "a.jpg", content: "a")], into: f.store.root)
        #expect(result == PhotoImportResult(importedAssetIDs: [], failed: 0))
        #expect(f.store.readString("a.jpg") == "a")
    }

    @Test("Temporary photo copies are removed after importing, duplicates and failures included")
    func photoTempCopiesRemoved() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.store.seed("dup.jpg", content: "same")
        f.store.failAdding("bad.jpg")
        let probe = PhotoProbe()
        let assets = [
            probe.source(id: "1", name: "a.jpg", content: "a"),
            probe.source(id: "2", name: "dup.jpg", content: "same"),
            probe.source(id: "3", name: "bad.jpg", content: "b"),
        ]
        _ = try await f.importer.importPhotos(assets, into: f.store.root)
        #expect(probe.tempFiles.count == 3)
        for url in probe.tempFiles {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("A photo's suggested name loses its leading dots before storing and counts toward the limit")
    func photoNameLosesLeadingDots() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let probe = PhotoProbe()
        let result = try await f.importer.importPhotos(
            [probe.source(id: "id", name: ".hidden.jpg", content: "h")], into: f.store.root)
        #expect(result.importedAssetIDs == ["id"])
        #expect(f.store.addCalls.map(\.name) == ["hidden.jpg"])
        #expect(f.store.readString("hidden.jpg") == "h")
    }

    @Test("A dot-named photo counts toward the limit")
    func dotNamedPhotoCountsTowardLimit() async throws {
        let f = try Fixture(existingFiles: 99)
        defer { f.cleanup() }
        let probe = PhotoProbe()
        let assets = [
            probe.source(id: "1", name: ".a.jpg", content: "a"),
            probe.source(id: "2", name: "b.jpg", content: "b"),
        ]
        await #expect(throws: ImportError.fileLimitReached(limit: 100)) {
            _ = try await f.importer.importPhotos(assets, into: f.store.root)
        }
    }

    @Test("A photo's duplicate check uses the name with dots removed")
    func photoDuplicateCheckUsesNewName() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.store.seed("hidden.jpg", content: "same")
        let probe = PhotoProbe()
        let result = try await f.importer.importPhotos(
            [probe.source(id: "id", name: ".hidden.jpg", content: "same")], into: f.store.root)
        #expect(result.importedAssetIDs == ["id"])
        #expect(f.store.allPaths() == ["hidden.jpg"])
    }

    @Test("A photo whose name is only dots counts as failed with nothing imported")
    func onlyDotsPhotoFails() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let probe = PhotoProbe()
        let assets = [
            probe.source(id: "bad", name: "...", content: "x"),
            probe.source(id: "ok", name: "a.jpg", content: "a"),
        ]
        let result = try await f.importer.importPhotos(assets, into: f.store.root)
        #expect(result == PhotoImportResult(importedAssetIDs: ["ok"], failed: 1))
        #expect(f.store.allPaths() == ["a.jpg"])
    }
}
