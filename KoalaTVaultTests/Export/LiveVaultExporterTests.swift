import Foundation
import Testing

@testable import KoalaTVault

// Assumed initialiser (see report):
//   LiveVaultExporter(store: any VaultStoring, photoSaver: PhotoLibrarySaver)

private struct ExporterTestFixture {
    let exporter: LiveVaultExporter
    let store: ExportTestStore
    let library: FakePhotoLibrary
}

@Suite struct LiveVaultExporterTests {
    private func makeExporter(
        accessGranted: Bool = true
    ) throws -> ExporterTestFixture {
        let store = try ExportTestStore()
        let library = FakePhotoLibrary(accessGranted: accessGranted)
        let saver = PhotoLibrarySaver(store: store, library: library)
        return ExporterTestFixture(
            exporter: LiveVaultExporter(store: store, photoSaver: saver), store: store, library: library)
    }

    private func parentPath(_ url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.path
    }

    private func isInside(_ url: URL, _ folder: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    // MARK: prepareForSharing

    @Test("Plaintext items give their disk URLs")
    func plaintextItemsGiveDiskURLs() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let first = try store.seedFile("first.txt")
        let second = try store.seedFile("second.pdf")

        let bundle = try await exporter.prepareForSharing([first, second])

        #expect(bundle.urls == [first.diskURL, second.diskURL])
        #expect(store.tempEntries().isEmpty)
    }

    @Test("Encrypted items give decrypted copies with their original names")
    func encryptedItemsGiveDecryptedCopies() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let note = try store.seedFile("note.txt", content: "hello", encrypted: true)
        let photo = try store.seedFile("photo.jpg", content: "pixels", encrypted: true)

        let bundle = try await exporter.prepareForSharing([note, photo])

        #expect(bundle.urls.map(\.lastPathComponent) == ["note.txt", "photo.jpg"])
        #expect(store.filesUnder(bundle.urls[0]) == ["note.txt": "hello"])
        #expect(store.filesUnder(bundle.urls[1]) == ["photo.jpg": "pixels"])
        #expect(bundle.urls.allSatisfy { isInside($0, store.tempArea) })
    }

    @Test("All decrypted copies of one export share a single store temp folder")
    func copiesShareOneTempFolder() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let first = try store.seedFile("one.txt", encrypted: true)
        let second = try store.seedFile("two.txt", encrypted: true)
        let third = try store.seedFile("three.txt", encrypted: true)

        let bundle = try await exporter.prepareForSharing([first, second, third])

        #expect(Set(bundle.urls.map(parentPath)).count == 1)
        #expect(store.tempEntries().filter { !$0.contains("/") }.count == 1)
    }

    @Test("A mixed selection keeps plaintext URLs and decrypts the encrypted items in order")
    func mixedSelection() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let plain = try store.seedFile("plain.txt")
        let secret = try store.seedFile("secret.txt", content: "shh", encrypted: true)

        let bundle = try await exporter.prepareForSharing([plain, secret])

        #expect(bundle.urls.count == 2)
        #expect(bundle.urls[0] == plain.diskURL)
        #expect(bundle.urls[1].lastPathComponent == "secret.txt")
        #expect(store.filesUnder(bundle.urls[1]) == ["secret.txt": "shh"])
    }

    @Test("An encrypted folder gives a decrypted copy of its whole tree with original names")
    func encryptedFolderGivesDecryptedTree() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let folder = try store.seedFolder("Trip", encrypted: true)
        try store.seedFile("map.png", content: "map", encrypted: true, in: folder)
        let inner = try store.seedFolder("Day1", encrypted: true, in: folder)
        try store.seedFile("beach.jpg", content: "sand", encrypted: true, in: inner)
        try store.seedFile("notes.txt", content: "plain note", in: inner)

        let bundle = try await exporter.prepareForSharing([folder])

        #expect(bundle.urls.count == 1)
        let copy = try #require(bundle.urls.first)
        #expect(copy.lastPathComponent == "Trip")
        #expect(isInside(copy, store.tempArea))
        let expected = ["map.png": "map", "Day1/beach.jpg": "sand", "Day1/notes.txt": "plain note"]
        #expect(store.filesUnder(copy) == expected)
        #expect(Set(store.pathsUnder(copy)) == ["map.png", "Day1", "Day1/beach.jpg", "Day1/notes.txt"])
    }

    @Test("A folder copy has no vault map and no UUID names")
    func folderCopyHasNoMapOrUUIDNames() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let folder = try store.seedFolder("Docs", encrypted: true)
        try store.seedFile("a.txt", encrypted: true, in: folder)
        let inner = try store.seedFolder("Sub", encrypted: true, in: folder)
        try store.seedFile("b.txt", encrypted: true, in: inner)

        let bundle = try await exporter.prepareForSharing([folder])

        let copy = try #require(bundle.urls.first)
        let names = store.pathsUnder(copy).flatMap { $0.split(separator: "/").map(String.init) }
        #expect(!names.isEmpty)
        #expect(!names.contains(".vault_map"))
        #expect(names.allSatisfy { UUID(uuidString: $0) == nil })
    }

    @Test("A plaintext folder holding encrypted items still gives a decrypted tree copy")
    func plaintextFolderWithEncryptedItemsIsDecrypted() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let folder = try store.seedFolder("Mixed")
        try store.seedFile("open.txt", content: "open", in: folder)
        try store.seedFile("hidden.txt", content: "hidden", encrypted: true, in: folder)

        let bundle = try await exporter.prepareForSharing([folder])

        let copy = try #require(bundle.urls.first)
        #expect(copy.lastPathComponent == "Mixed")
        #expect(store.filesUnder(copy) == ["open.txt": "open", "hidden.txt": "hidden"])
    }

    @Test("A plaintext folder gives its disk URL")
    func plaintextFolderGivesDiskURL() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let folder = try store.seedFolder("Plain")
        try store.seedFile("a.txt", in: folder)
        let inner = try store.seedFolder("Inner", in: folder)
        try store.seedFile("b.txt", in: inner)

        let bundle = try await exporter.prepareForSharing([folder])

        #expect(bundle.urls == [folder.diskURL])
        #expect(store.tempEntries().isEmpty)
    }

    @Test("An empty selection throws nothingToExport")
    func emptySelectionThrows() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }

        await #expect(throws: ExportError.nothingToExport) { try await exporter.prepareForSharing([]) }
        #expect(store.tempEntries().isEmpty)
    }

    @Test("A failure part-way removes every copy made and rethrows the error")
    func failurePartWayCleansUpAndRethrows() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let plain = try store.seedFile("plain.txt")
        let first = try store.seedFile("first.txt", encrypted: true)
        let folder = try store.seedFolder("Tree", encrypted: true)
        try store.seedFile("inside.txt", encrypted: true, in: folder)
        let broken = try store.seedFile("broken.txt", encrypted: true)
        store.failOpening("broken.txt")

        var thrown: (any Error)?
        do {
            _ = try await exporter.prepareForSharing([plain, first, folder, broken])
        } catch {
            thrown = error
        }

        #expect(thrown as? VaultStoreError == .io("boom"))
        #expect(store.tempEntries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: plain.diskURL.path))
    }

    @Test("A failure inside a folder removes every copy made and rethrows")
    func failureInsideFolderCleansUp() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let folder = try store.seedFolder("Tree", encrypted: true)
        try store.seedFile("good.txt", encrypted: true, in: folder)
        try store.seedFile("bad.txt", encrypted: true, in: folder)
        store.failOpening("bad.txt")

        var thrown: (any Error)?
        do {
            _ = try await exporter.prepareForSharing([folder])
        } catch {
            thrown = error
        }

        #expect(thrown as? VaultStoreError == .io("boom"))
        #expect(store.tempEntries().isEmpty)
    }

    @Test("cleanUp removes the temp folder and all decrypted copies")
    func cleanUpRemovesTempFolder() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let secret = try store.seedFile("secret.txt", encrypted: true)
        let folder = try store.seedFolder("Tree", encrypted: true)
        try store.seedFile("inside.txt", encrypted: true, in: folder)

        let bundle = try await exporter.prepareForSharing([secret, folder])
        #expect(!store.tempEntries().isEmpty)
        bundle.cleanUp()

        #expect(store.tempEntries().isEmpty)
        #expect(bundle.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("cleanUp is safe to call twice")
    func cleanUpTwice() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let secret = try store.seedFile("secret.txt", encrypted: true)

        let bundle = try await exporter.prepareForSharing([secret])
        bundle.cleanUp()
        bundle.cleanUp()

        #expect(store.tempEntries().isEmpty)
    }

    @Test("cleanUp never removes plaintext originals in the vault")
    func cleanUpKeepsPlaintextOriginals() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let plain = try store.seedFile("plain.txt", content: "keep me")
        let folder = try store.seedFolder("Plain")
        try store.seedFile("inner.txt", in: folder)

        let bundle = try await exporter.prepareForSharing([plain, folder])
        bundle.cleanUp()
        bundle.cleanUp()

        #expect(store.filesUnder(plain.diskURL) == ["plain.txt": "keep me"])
        #expect(FileManager.default.fileExists(atPath: folder.diskURL.appendingPathComponent("inner.txt").path))
    }

    // MARK: Duplicate names

    @Test("Two encrypted items with the same name get a numbered second copy with the right content")
    func duplicateNamesGetNumbered() async throws {
        let fixture = try makeExporter()
        let store = fixture.store
        defer { store.cleanup() }
        let folder = try store.seedFolder("Other")
        let first = try store.seedFile("a.txt", content: "from root", encrypted: true)
        let second = try store.seedFile("a.txt", content: "from other", encrypted: true, in: folder)

        let bundle = try await fixture.exporter.prepareForSharing([first, second])

        #expect(bundle.urls.map(\.lastPathComponent) == ["a.txt", "a 1.txt"])
        #expect(store.filesUnder(bundle.urls[0]) == ["a.txt": "from root"])
        #expect(store.filesUnder(bundle.urls[1]) == ["a 1.txt": "from other"])
        #expect(Set(bundle.urls.map(parentPath)).count == 1)
    }

    @Test("Three encrypted items with the same name get no suffix, 1 and 2")
    func threeDuplicatesGetOneAndTwo() async throws {
        let fixture = try makeExporter()
        let store = fixture.store
        defer { store.cleanup() }
        let folderOne = try store.seedFolder("One")
        let folderTwo = try store.seedFolder("Two")
        let first = try store.seedFile("a.txt", content: "zero", encrypted: true)
        let second = try store.seedFile("a.txt", content: "one", encrypted: true, in: folderOne)
        let third = try store.seedFile("a.txt", content: "two", encrypted: true, in: folderTwo)

        let bundle = try await fixture.exporter.prepareForSharing([first, second, third])

        #expect(bundle.urls.map(\.lastPathComponent) == ["a.txt", "a 1.txt", "a 2.txt"])
        #expect(store.filesUnder(bundle.urls[0]).values.first == "zero")
        #expect(store.filesUnder(bundle.urls[1]).values.first == "one")
        #expect(store.filesUnder(bundle.urls[2]).values.first == "two")
    }

    @Test("Duplicate names without an extension are numbered at the end")
    func duplicateNamesWithoutExtension() async throws {
        let fixture = try makeExporter()
        let store = fixture.store
        defer { store.cleanup() }
        let folder = try store.seedFolder("Other")
        let first = try store.seedFile("README", content: "first", encrypted: true)
        let second = try store.seedFile("README", content: "second", encrypted: true, in: folder)

        let bundle = try await fixture.exporter.prepareForSharing([first, second])

        #expect(bundle.urls.map(\.lastPathComponent) == ["README", "README 1"])
        #expect(store.filesUnder(bundle.urls[0]) == ["README": "first"])
        #expect(store.filesUnder(bundle.urls[1]) == ["README 1": "second"])
    }

    @Test("A plaintext item and an encrypted item with the same name give the disk URL and a copy")
    func plaintextAndEncryptedSameName() async throws {
        let fixture = try makeExporter()
        let store = fixture.store
        defer { store.cleanup() }
        let folder = try store.seedFolder("Other")
        let plain = try store.seedFile("a.txt", content: "plain")
        let secret = try store.seedFile("a.txt", content: "secret", encrypted: true, in: folder)

        let bundle = try await fixture.exporter.prepareForSharing([plain, secret])

        #expect(bundle.urls.count == 2)
        #expect(bundle.urls[0] == plain.diskURL)
        #expect(isInside(bundle.urls[1], store.tempArea))
        #expect(store.filesUnder(bundle.urls[1]).values.first == "secret")
        bundle.cleanUp()
        #expect(store.filesUnder(plain.diskURL) == ["a.txt": "plain"])
    }

    // MARK: saveToPhotos

    @Test("saveToPhotos without add-only access throws photoAccessDenied")
    func saveToPhotosDenied() async throws {
        let fixture = try makeExporter(accessGranted: false)
        let exporter = fixture.exporter
        let store = fixture.store
        let library = fixture.library
        defer { store.cleanup() }
        let photo = try store.seedFile("photo.jpg")

        await #expect(throws: ExportError.photoAccessDenied) { try await exporter.saveToPhotos([photo]) }
        #expect(library.saved.isEmpty)
    }

    @Test("saveToPhotos saves images and videos from decrypted copies and counts skipped items")
    func saveToPhotosSavesMedia() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        let library = fixture.library
        defer { store.cleanup() }
        let photo = try store.seedFile("photo.jpg", content: "pixels", encrypted: true)
        let movie = try store.seedFile("movie.mov", content: "frames")
        let document = try store.seedFile("doc.pdf")

        let result = try await exporter.saveToPhotos([photo, movie, document])

        #expect(result == PhotoSaveResult(saved: 2, failed: 0, skipped: 1))
        #expect(Set(library.saved.map(\.fileName)) == ["photo.jpg", "movie.mov"])
        #expect(store.tempEntries().isEmpty)
    }

    @Test("saveToPhotos counts a failed save and still saves the rest")
    func saveToPhotosCountsFailures() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        let library = fixture.library
        defer { store.cleanup() }
        let broken = try store.seedFile("broken.png", encrypted: true)
        let fine = try store.seedFile("fine.png", encrypted: true)
        library.failSaving("broken.png")

        let result = try await exporter.saveToPhotos([broken, fine])

        #expect(result == PhotoSaveResult(saved: 1, failed: 1, skipped: 0))
        #expect(store.tempEntries().isEmpty)
    }

    // MARK: canSaveToPhotos

    @Test("canSaveToPhotos is true when any item is an image or a video")
    func canSaveWithMedia() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let document = try store.seedFile("doc.pdf")
        let image = try store.seedFile("picture.png")
        let video = try store.seedFile("clip.mp4")

        #expect(exporter.canSaveToPhotos([document, image]))
        #expect(exporter.canSaveToPhotos([video]))
        #expect(exporter.canSaveToPhotos([image, video, document]))
    }

    @Test("canSaveToPhotos is false without images or videos")
    func cannotSaveWithoutMedia() async throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }
        let document = try store.seedFile("doc.pdf")
        let audio = try store.seedFile("song.mp3")
        let folder = try store.seedFolder("Pictures.png")

        #expect(!exporter.canSaveToPhotos([document, audio]))
        #expect(!exporter.canSaveToPhotos([folder]))
    }

    @Test("canSaveToPhotos is false for an empty list")
    func cannotSaveEmptyList() throws {
        let fixture = try makeExporter()
        let exporter = fixture.exporter
        let store = fixture.store
        defer { store.cleanup() }

        #expect(!exporter.canSaveToPhotos([]))
    }
}
