import Foundation
import Testing

@testable import KoalaTVault

// Assumed initialiser (see report):
//   LiveVaultExporter(store: any VaultStoring, photoSaver: PhotoLibrarySaver)

@Suite struct LiveVaultExporterTests {
    private func makeExporter(
        accessGranted: Bool = true
    ) throws -> (exporter: LiveVaultExporter, store: ExportTestStore, library: FakePhotoLibrary) {
        let store = try ExportTestStore()
        let library = FakePhotoLibrary(accessGranted: accessGranted)
        let saver = PhotoLibrarySaver(store: store, library: library)
        return (LiveVaultExporter(store: store, photoSaver: saver), store, library)
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
        let (exporter, store, _) = try makeExporter()
        defer { store.cleanup() }
        let first = try store.seedFile("first.txt")
        let second = try store.seedFile("second.pdf")

        let bundle = try await exporter.prepareForSharing([first, second])

        #expect(bundle.urls == [first.diskURL, second.diskURL])
        #expect(store.tempEntries().isEmpty)
    }

    @Test("Encrypted items give decrypted copies with their original names")
    func encryptedItemsGiveDecryptedCopies() async throws {
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
        defer { store.cleanup() }

        await #expect(throws: ExportError.nothingToExport) { try await exporter.prepareForSharing([]) }
        #expect(store.tempEntries().isEmpty)
    }

    @Test("A failure part-way removes every copy made and rethrows the error")
    func failurePartWayCleansUpAndRethrows() async throws {
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
        defer { store.cleanup() }
        let secret = try store.seedFile("secret.txt", encrypted: true)

        let bundle = try await exporter.prepareForSharing([secret])
        bundle.cleanUp()
        bundle.cleanUp()

        #expect(store.tempEntries().isEmpty)
    }

    @Test("cleanUp never removes plaintext originals in the vault")
    func cleanUpKeepsPlaintextOriginals() async throws {
        let (exporter, store, _) = try makeExporter()
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

    // MARK: saveToPhotos

    @Test("saveToPhotos without add-only access throws photoAccessDenied")
    func saveToPhotosDenied() async throws {
        let (exporter, store, library) = try makeExporter(accessGranted: false)
        defer { store.cleanup() }
        let photo = try store.seedFile("photo.jpg")

        await #expect(throws: ExportError.photoAccessDenied) { try await exporter.saveToPhotos([photo]) }
        #expect(library.saved.isEmpty)
    }

    @Test("saveToPhotos saves images and videos from decrypted copies and counts skipped items")
    func saveToPhotosSavesMedia() async throws {
        let (exporter, store, library) = try makeExporter()
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
        let (exporter, store, library) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
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
        let (exporter, store, _) = try makeExporter()
        defer { store.cleanup() }
        let document = try store.seedFile("doc.pdf")
        let audio = try store.seedFile("song.mp3")
        let folder = try store.seedFolder("Pictures.png")

        #expect(!exporter.canSaveToPhotos([document, audio]))
        #expect(!exporter.canSaveToPhotos([folder]))
    }

    @Test("canSaveToPhotos is false for an empty list")
    func cannotSaveEmptyList() throws {
        let (exporter, store, _) = try makeExporter()
        defer { store.cleanup() }

        #expect(!exporter.canSaveToPhotos([]))
    }
}
