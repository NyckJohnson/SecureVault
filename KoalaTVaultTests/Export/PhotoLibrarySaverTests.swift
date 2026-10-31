import Foundation
import Testing

@testable import KoalaTVault

// Assumed seam and initialiser (see report):
//   protocol PhotoLibraryAdding: Sendable {
//       func requestAddOnlyAccess() async -> Bool
//       func saveMedia(at url: URL, isVideo: Bool) async throws
//   }
//   PhotoLibrarySaver(store: any VaultStoring, library: any PhotoLibraryAdding)
//   func save(_ items: [VaultItem]) async throws -> PhotoSaveResult

@Suite struct PhotoLibrarySaverTests {
    private func makeSaver(
        accessGranted: Bool = true
    ) throws -> (saver: PhotoLibrarySaver, store: ExportTestStore, library: FakePhotoLibrary) {
        let store = try ExportTestStore()
        let library = FakePhotoLibrary(accessGranted: accessGranted)
        return (PhotoLibrarySaver(store: store, library: library), store, library)
    }

    @Test("Without add-only access saving throws photoAccessDenied and saves nothing")
    func deniedAccessThrows() async throws {
        let (saver, store, library) = try makeSaver(accessGranted: false)
        defer { store.cleanup() }
        let photo = try store.seedFile("photo.jpg", encrypted: true)

        await #expect(throws: ExportError.photoAccessDenied) { try await saver.save([photo]) }

        #expect(library.saved.isEmpty)
        #expect(store.tempEntries().isEmpty)
    }

    @Test("Access is requested from the photo library")
    func requestsAccess() async throws {
        let (saver, store, library) = try makeSaver()
        defer { store.cleanup() }
        let photo = try store.seedFile("photo.jpg")

        _ = try await saver.save([photo])

        #expect(library.accessRequests >= 1)
    }

    @Test("Images and videos are saved with their kind and others are counted as skipped")
    func savesMediaAndSkipsOthers() async throws {
        let (saver, store, library) = try makeSaver()
        defer { store.cleanup() }
        let photo = try store.seedFile("photo.jpg", content: "pixels")
        let movie = try store.seedFile("movie.mp4", content: "frames")
        let document = try store.seedFile("report.pdf")
        let folder = try store.seedFolder("album.png")

        let result = try await saver.save([photo, document, movie, folder])

        #expect(result == PhotoSaveResult(saved: 2, failed: 0, skipped: 2))
        let savedByName = Dictionary(uniqueKeysWithValues: library.saved.map { ($0.fileName, $0) })
        #expect(savedByName.count == 2)
        #expect(savedByName["photo.jpg"]?.isVideo == false)
        #expect(savedByName["movie.mp4"]?.isVideo == true)
    }

    @Test("An encrypted image is saved from a decrypted copy under its original name")
    func savesDecryptedCopy() async throws {
        let (saver, store, library) = try makeSaver()
        defer { store.cleanup() }
        let photo = try store.seedFile("holiday.heic", content: "secret pixels", encrypted: true)

        let result = try await saver.save([photo])

        #expect(result == PhotoSaveResult(saved: 1, failed: 0, skipped: 0))
        let expected = FakePhotoLibrary.SavedMedia(fileName: "holiday.heic", isVideo: false, content: "secret pixels")
        #expect(library.saved == [expected])
    }

    @Test("Temporary copies are removed after saving")
    func removesTempAfterSave() async throws {
        let (saver, store, _) = try makeSaver()
        defer { store.cleanup() }
        let photo = try store.seedFile("a.jpg", encrypted: true)
        let movie = try store.seedFile("b.mov", encrypted: true)

        _ = try await saver.save([photo, movie])

        #expect(store.tempEntries().isEmpty)
    }

    @Test("A plaintext item's original file is never removed")
    func keepsPlaintextOriginal() async throws {
        let (saver, store, _) = try makeSaver()
        defer { store.cleanup() }
        let photo = try store.seedFile("plain.png", content: "pixels")

        _ = try await saver.save([photo])

        #expect(FileManager.default.fileExists(atPath: photo.diskURL.path))
    }

    @Test("A failed save counts as failed, removes its temp copy, and the rest are still saved")
    func failedSaveIsCountedAndCleaned() async throws {
        let (saver, store, library) = try makeSaver()
        defer { store.cleanup() }
        let first = try store.seedFile("first.jpg", encrypted: true)
        let broken = try store.seedFile("broken.jpg", encrypted: true)
        let last = try store.seedFile("last.mp4", encrypted: true)
        library.failSaving("broken.jpg")

        let result = try await saver.save([first, broken, last])

        #expect(result == PhotoSaveResult(saved: 2, failed: 1, skipped: 0))
        #expect(library.saved.map(\.fileName).sorted() == ["broken.jpg", "first.jpg", "last.mp4"])
        #expect(store.tempEntries().isEmpty)
    }

    @Test("An item that cannot be decrypted counts as failed and the rest are still saved")
    func failedDecryptIsCounted() async throws {
        let (saver, store, library) = try makeSaver()
        defer { store.cleanup() }
        let broken = try store.seedFile("broken.jpg", encrypted: true)
        let fine = try store.seedFile("fine.jpg", encrypted: true)
        store.failOpening("broken.jpg")

        let result = try await saver.save([broken, fine])

        #expect(result == PhotoSaveResult(saved: 1, failed: 1, skipped: 0))
        #expect(library.saved.map(\.fileName) == ["fine.jpg"])
        #expect(store.tempEntries().isEmpty)
    }

    @Test("Saving only non-media items skips them all")
    func onlyNonMediaIsSkipped() async throws {
        let (saver, store, library) = try makeSaver()
        defer { store.cleanup() }
        let document = try store.seedFile("notes.txt")
        let archive = try store.seedFile("bundle.zip")

        let result = try await saver.save([document, archive])

        #expect(result == PhotoSaveResult(saved: 0, failed: 0, skipped: 2))
        #expect(library.saved.isEmpty)
    }

    @Test("Saving an empty list returns an all-zero result")
    func emptyListSavesNothing() async throws {
        let (saver, store, library) = try makeSaver()
        defer { store.cleanup() }

        let result = try await saver.save([])

        #expect(result == PhotoSaveResult(saved: 0, failed: 0, skipped: 0))
        #expect(library.saved.isEmpty)
    }
}
