import Foundation

import Testing

@testable import KoalaTVault

// Assumed seam (all in Views/ImportPresenter.swift): see the test-writer report for the full list.

/// One thing that happened during an import flow, in order.
private enum FlowEvent: Equatable, Sendable {
    case requestedPhotoAccess
    case presentedPicker(ImportPickerKind)
    case dismissedPicker
    case overlay(title: String, progress: Double?)
    case overlayHidden
    case message(String)
    case error(String)
    case limitReached
    case importedItems([URL])
    case importedPhotos(Int)
    case deletedAssets([String])
}

private final class FlowLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FlowEvent] = []

    var events: [FlowEvent] { lock.withLock { storage } }
    func add(_ event: FlowEvent) { lock.withLock { storage.append(event) } }

    func index(of event: FlowEvent) -> Int? { events.firstIndex(of: event) }

    var overlays: [(title: String, progress: Double?)] {
        events.compactMap { event in
            if case .overlay(let title, let progress) = event { return (title, progress) }
            return nil
        }
    }

    var messages: [String] {
        events.compactMap { event in
            if case .message(let text) = event { return text }
            return nil
        }
    }

    var errors: [String] {
        events.compactMap { event in
            if case .error(let text) = event { return text }
            return nil
        }
    }

    var deletes: [[String]] {
        events.compactMap { event in
            if case .deletedAssets(let ids) = event { return ids }
            return nil
        }
    }
}

@MainActor
private final class RecordingFlowView: ImportFlowViewing {
    let log: FlowLog
    private(set) var openPicker: ImportPickerKind?

    init(log: FlowLog) { self.log = log }

    func presentPicker(_ kind: ImportPickerKind) {
        openPicker = kind
        log.add(.presentedPicker(kind))
    }

    func dismissPicker() async {
        openPicker = nil
        log.add(.dismissedPicker)
    }

    func showOverlay(title: String, progress: Double?) { log.add(.overlay(title: title, progress: progress)) }
    func hideOverlay() { log.add(.overlayHidden) }
    func showMessage(_ text: String) { log.add(.message(text)) }
    func showError(_ text: String) { log.add(.error(text)) }
}

private final class ScriptedImporter: VaultImporting, @unchecked Sendable {
    private let log: FlowLog
    private let lock = NSLock()
    private var _progressValues: [Double] = []
    private var _fileResult = ImportResult(imported: 0, skippedDuplicates: 0, failed: 0)
    private var _photoResult = PhotoImportResult(importedAssetIDs: [], failed: 0)
    private var _error: (any Error)?
    private var _loadsPhotoFiles = false

    init(log: FlowLog) { self.log = log }

    func script(
        progress: [Double] = [], files: ImportResult? = nil, photos: PhotoImportResult? = nil,
        error: (any Error)? = nil, loadsPhotoFiles: Bool = false
    ) {
        lock.withLock {
            _progressValues = progress
            if let files { _fileResult = files }
            if let photos { _photoResult = photos }
            _error = error
            _loadsPhotoFiles = loadsPhotoFiles
        }
    }

    func checkAllowed(adding count: Int) async throws {}

    func importItems(
        _ urls: [URL], into directory: VaultDirectory, progress: @Sendable (Double) -> Void
    ) async throws -> ImportResult {
        log.add(.importedItems(urls))
        let values = lock.withLock { _progressValues }
        for value in values { progress(value) }
        if let error = lock.withLock({ _error }) { throw error }
        return lock.withLock { _fileResult }
    }

    func importPhotos(_ assets: [PhotoImportSource], into directory: VaultDirectory) async throws -> PhotoImportResult {
        log.add(.importedPhotos(assets.count))
        if lock.withLock({ _loadsPhotoFiles }) {
            for asset in assets { _ = try await asset.loadFile() }
        }
        if let error = lock.withLock({ _error }) { throw error }
        return lock.withLock { _photoResult }
    }
}

private final class LoggingCameraRoll: CameraRollDeleting {
    private let log: FlowLog
    init(log: FlowLog) { self.log = log }
    func deleteAssets(withIdentifiers ids: [String]) async { log.add(.deletedAssets(ids)) }
}

private final class LoggingPhotoAccess: ImportPhotoAccessRequesting {
    private let log: FlowLog
    init(log: FlowLog) { self.log = log }
    func requestReadWriteAccess() async { log.add(.requestedPhotoAccess) }
}

@MainActor
private struct Fixture {
    let log = FlowLog()
    let store: DiskBackedVaultStore
    let view: RecordingFlowView
    let importer: ScriptedImporter
    let model: ImportFlowModel

    init() throws {
        store = try DiskBackedVaultStore()
        view = RecordingFlowView(log: log)
        importer = ScriptedImporter(log: log)
        model = Self.makeModel(importer: importer, store: store, view: view, log: log)
    }

    /// A fixture whose importer is the shared `MockVaultImporting`.
    init(mock: MockVaultImporting) throws {
        store = try DiskBackedVaultStore()
        view = RecordingFlowView(log: log)
        importer = ScriptedImporter(log: log)
        model = Self.makeModel(importer: mock, store: store, view: view, log: log)
    }

    private static func makeModel(
        importer: any VaultImporting, store: DiskBackedVaultStore, view: RecordingFlowView, log: FlowLog
    ) -> ImportFlowModel {
        ImportFlowModel(
            importer: importer, cameraRoll: LoggingCameraRoll(log: log), photoAccess: LoggingPhotoAccess(log: log),
            store: store, view: view, onLimitReached: { log.add(.limitReached) })
    }

    var directory: VaultDirectory { store.root }
}

private func pick(_ assetID: String?, name: String = "photo.jpg") -> ImportPickedPhoto {
    ImportPickedPhoto(
        assetID: assetID, suggestedName: name,
        writeFile: { destination in try Data("photo-bytes".utf8).write(to: destination) })
}

private func sampleURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(name)
}

private struct PresenterTestError: LocalizedError {
    var errorDescription: String? { "Something odd happened." }
}

@MainActor
@Suite struct ImportPresenterTests {

    // MARK: Sheet and pickers

    @Test("The import sheet offers Choose Files, Choose Folder, Choose Photos and Cancel in that order")
    func sheetTitles() {
        #expect(ImportFlowModel.sheetTitles == ["Choose Files", "Choose Folder", "Choose Photos", "Cancel"])
    }

    @Test("Choosing files opens the files picker, choosing a folder opens the folder picker")
    func choosingOpensMatchingPicker() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }

        await fixture.model.choose(.files)
        #expect(fixture.view.openPicker == .files)
        await fixture.model.choose(.folder)
        #expect(fixture.view.openPicker == .folder)
        #expect(fixture.log.index(of: .requestedPhotoAccess) == nil)
    }

    @Test("Choosing photos requests read-write photo access before the photo picker opens")
    func photoAccessBeforePicker() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }

        await fixture.model.choose(.photos)

        let request = try #require(fixture.log.index(of: .requestedPhotoAccess))
        let opened = try #require(fixture.log.index(of: .presentedPicker(.photos)))
        #expect(request < opened)
    }

    @Test("Cancel in any picker closes it and imports nothing", arguments: [ImportPickerKind.files, .folder, .photos])
    func cancelClosesPickerAndImportsNothing(kind: ImportPickerKind) async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        let choice: ImportSourceChoice = kind == .files ? .files : (kind == .folder ? .folder : .photos)
        await fixture.model.choose(choice)
        #expect(fixture.view.openPicker == kind)

        await fixture.model.cancelPicker()

        #expect(fixture.view.openPicker == nil)
        let events = fixture.log.events
        #expect(!events.contains { if case .importedItems = $0 { return true } else { return false } })
        #expect(!events.contains { if case .importedPhotos = $0 { return true } else { return false } })
        #expect(fixture.log.deletes.isEmpty)
        #expect(fixture.log.errors.isEmpty)
        #expect(!events.contains(.limitReached))
    }

    // MARK: Files and folders

    @Test("Picked files are imported into the directory and the picker is closed")
    func pickedFilesImported() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        let urls = [sampleURL("one.txt"), sampleURL("two.txt")]
        fixture.importer.script(files: ImportResult(imported: 2, skippedDuplicates: 0, failed: 0))
        await fixture.model.choose(.files)

        await fixture.model.pickedItems(urls, into: fixture.directory)

        #expect(fixture.log.events.contains(.importedItems(urls)))
        #expect(fixture.view.openPicker == nil)
    }

    @Test("A picked folder is imported as one item")
    func pickedFolderImported() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        let folder = sampleURL("Album")
        await fixture.model.choose(.folder)

        await fixture.model.pickedItems([folder], into: fixture.directory)

        #expect(fixture.log.events.contains(.importedItems([folder])))
    }

    @Test("The Importing... overlay shows the importer's progress and goes away afterwards")
    func filesOverlayShowsProgress() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(progress: [0, 0.5, 1], files: ImportResult(imported: 1, skippedDuplicates: 0, failed: 0))

        await fixture.model.pickedItems([sampleURL("one.txt")], into: fixture.directory)

        let overlays = fixture.log.overlays
        #expect(!overlays.isEmpty)
        #expect(overlays.allSatisfy { $0.title == "Importing..." })
        let values = overlays.compactMap(\.progress)
        #expect(values.contains(0.5))
        #expect(values.last == 1)
        #expect(values == values.sorted())
        let hidden = try #require(fixture.log.index(of: .overlayHidden))
        let imported = try #require(fixture.log.index(of: .importedItems([sampleURL("one.txt")])))
        #expect(hidden > imported)
    }

    @Test("No message is shown when every file imported")
    func noMessageWithoutFailures() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(files: ImportResult(imported: 3, skippedDuplicates: 1, failed: 0))

        await fixture.model.pickedItems([sampleURL("a.txt")], into: fixture.directory)

        #expect(fixture.log.messages.isEmpty)
        #expect(fixture.log.errors.isEmpty)
    }

    @Test("A file import with failures shows N imported, M failed")
    func filesFailureMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(files: ImportResult(imported: 2, skippedDuplicates: 0, failed: 1))

        await fixture.model.pickedItems([sampleURL("a.txt")], into: fixture.directory)

        #expect(fixture.log.messages == ["2 imported, 1 failed"])
    }

    @Test("Hitting the free limit closes the picker first, then runs onLimitReached, with no error alert")
    func fileLimitClosesPickerThenPaywall() async throws {
        let fixture = try Fixture(mock: MockVaultImporting(fileCount: 100, isPro: false))
        defer { fixture.store.cleanup() }
        await fixture.model.choose(.files)

        await fixture.model.pickedItems([sampleURL("one.txt")], into: fixture.directory)

        let closed = try #require(fixture.log.index(of: .dismissedPicker))
        let limit = try #require(fixture.log.index(of: .limitReached))
        #expect(closed < limit)
        #expect(fixture.log.events.filter { $0 == .limitReached }.count == 1)
        #expect(fixture.log.errors.isEmpty)
        #expect(fixture.view.openPicker == nil)
        #expect(fixture.log.messages.isEmpty)
    }

    @Test("Another error is shown with its own text, only after the picker has closed")
    func otherErrorShownAfterPickerCloses() async throws {
        let mock = MockVaultImporting(fileCount: 12)
        mock.errorToThrow = .unreadableSource("notes.txt")
        let fixture = try Fixture(mock: mock)
        defer { fixture.store.cleanup() }
        await fixture.model.choose(.files)

        await fixture.model.pickedItems([sampleURL("notes.txt")], into: fixture.directory)

        let expected = "Couldn't read \"notes.txt\"."
        #expect(fixture.log.errors == [expected])
        let closed = try #require(fixture.log.index(of: .dismissedPicker))
        let shown = try #require(fixture.log.index(of: .error(expected)))
        #expect(closed < shown)
        #expect(!fixture.log.events.contains(.limitReached))
    }

    @Test("A non-import error is shown using its localized description")
    func genericErrorText() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(error: PresenterTestError())
        await fixture.model.choose(.folder)

        await fixture.model.pickedItems([sampleURL("Album")], into: fixture.directory)

        #expect(fixture.log.errors == ["Something odd happened."])
        let closed = try #require(fixture.log.index(of: .dismissedPicker))
        let shown = try #require(fixture.log.index(of: .error("Something odd happened.")))
        #expect(closed < shown)
    }

    @Test("The overlay is hidden after a failed import")
    func overlayHiddenAfterError() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(error: PresenterTestError())

        await fixture.model.pickedItems([sampleURL("a.txt")], into: fixture.directory)

        #expect(fixture.log.index(of: .overlayHidden) != nil)
        #expect(fixture.log.errors == ["Something odd happened."])
    }

    // MARK: Photos

    @Test("Picked photos are imported with the Importing Photos... overlay")
    func photosOverlayTitle() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(photos: PhotoImportResult(importedAssetIDs: ["x"], failed: 0))

        await fixture.model.pickedPhotos([pick("x")], into: fixture.directory)

        #expect(fixture.log.events.contains(.importedPhotos(1)))
        #expect(!fixture.log.overlays.isEmpty)
        #expect(fixture.log.overlays.allSatisfy { $0.title == "Importing Photos..." })
        #expect(fixture.log.index(of: .overlayHidden) != nil)
    }

    @Test("The photo overlay progress rises as each photo is loaded and ends at 1")
    func photoOverlayUpdates() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        let ids = ["a1", "b2", "c3"]
        fixture.importer.script(photos: PhotoImportResult(importedAssetIDs: ids, failed: 0), loadsPhotoFiles: true)

        await fixture.model.pickedPhotos(
            [pick("a1", name: "1.jpg"), pick("b2", name: "2.jpg"), pick("c3", name: "3.jpg")], into: fixture.directory)

        let values = fixture.log.overlays.compactMap(\.progress)
        #expect(values == values.sorted())
        #expect(values.last == 1)
        #expect(values.contains { $0 > 0 && $0 < 1 })
    }

    @Test("A photo import with failures shows N imported, M failed")
    func photosFailureMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(photos: PhotoImportResult(importedAssetIDs: ["a1", "b2"], failed: 1))

        await fixture.model.pickedPhotos([pick("a1"), pick("b2"), pick("c3")], into: fixture.directory)

        #expect(fixture.log.messages == ["2 imported, 1 failed"])
    }

    @Test("No message is shown when every photo imported")
    func photosNoMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(photos: PhotoImportResult(importedAssetIDs: ["a1"], failed: 0))

        await fixture.model.pickedPhotos([pick("a1")], into: fixture.directory)

        #expect(fixture.log.messages.isEmpty)
    }

    @Test("The camera-roll delete is asked for exactly the imported asset IDs, after the import")
    func cameraRollDeleteAfterImport() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(photos: PhotoImportResult(importedAssetIDs: ["a1", "c3"], failed: 1))

        await fixture.model.pickedPhotos([pick("a1"), pick("b2"), pick("c3")], into: fixture.directory)

        #expect(fixture.log.deletes == [["a1", "c3"]])
        let imported = try #require(fixture.log.index(of: .importedPhotos(3)))
        let deleted = try #require(fixture.log.index(of: .deletedAssets(["a1", "c3"])))
        #expect(imported < deleted)
    }

    @Test("The failure message is shown before the camera-roll delete is asked for")
    func messageBeforeDelete() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(photos: PhotoImportResult(importedAssetIDs: ["a1"], failed: 1))

        await fixture.model.pickedPhotos([pick("a1"), pick("b2")], into: fixture.directory)

        let message = try #require(fixture.log.index(of: .message("1 imported, 1 failed")))
        let deleted = try #require(fixture.log.index(of: .deletedAssets(["a1"])))
        #expect(message < deleted)
    }

    @Test("The camera-roll delete is not asked for when no photo was imported")
    func noDeleteWithoutImportedAssets() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        fixture.importer.script(photos: PhotoImportResult(importedAssetIDs: [], failed: 2))

        await fixture.model.pickedPhotos([pick(nil), pick(nil)], into: fixture.directory)

        #expect(fixture.log.deletes.isEmpty)
        #expect(fixture.log.messages == ["0 imported, 2 failed"])
    }

    @Test("The photo limit closes the picker first, then runs onLimitReached, and deletes nothing")
    func photoLimitClosesPickerThenPaywall() async throws {
        let fixture = try Fixture(mock: MockVaultImporting(fileCount: 100, isPro: false))
        defer { fixture.store.cleanup() }
        await fixture.model.choose(.photos)

        await fixture.model.pickedPhotos([pick("a1")], into: fixture.directory)

        let closed = try #require(fixture.log.index(of: .dismissedPicker))
        let limit = try #require(fixture.log.index(of: .limitReached))
        #expect(closed < limit)
        #expect(fixture.log.errors.isEmpty)
        #expect(fixture.log.deletes.isEmpty)
        #expect(fixture.view.openPicker == nil)
    }

    @Test("A photo import error is shown with its own text after the photo picker closes")
    func photoErrorAfterPickerCloses() async throws {
        let mock = MockVaultImporting(fileCount: 12)
        mock.errorToThrow = .unreadableSource("beach.jpg")
        let fixture = try Fixture(mock: mock)
        defer { fixture.store.cleanup() }
        await fixture.model.choose(.photos)

        await fixture.model.pickedPhotos([pick("a1", name: "beach.jpg")], into: fixture.directory)

        let expected = "Couldn't read \"beach.jpg\"."
        let closed = try #require(fixture.log.index(of: .dismissedPicker))
        let shown = try #require(fixture.log.index(of: .error(expected)))
        #expect(closed < shown)
        #expect(fixture.log.deletes.isEmpty)
    }

    // MARK: Photo loaders

    @Test("Each photo source's loader puts its file alone in its own store temp folder")
    func loaderUsesOwnTempFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        let first = fixture.model.photoSource(for: pick("a1", name: "first.jpg"))
        let second = fixture.model.photoSource(for: pick("b2", name: "second.jpg"))

        let firstURL = try await first.loadFile()
        let secondURL = try await second.loadFile()

        let areaPath = fixture.store.tempArea.standardizedFileURL.path
        for url in [firstURL, secondURL] {
            let folder = url.deletingLastPathComponent()
            #expect(folder.standardizedFileURL.path.hasPrefix(areaPath + "/"))
            let siblings = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(siblings == [url.lastPathComponent])
            #expect(try Data(contentsOf: url) == Data("photo-bytes".utf8))
        }
        #expect(firstURL.deletingLastPathComponent() != secondURL.deletingLastPathComponent())
        #expect(fixture.store.tempDirectoriesCreated == 2)
    }

    @Test("A photo source keeps the pick's asset ID and suggested name, and its file is named after it")
    func sourceKeepsIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }

        let source = fixture.model.photoSource(for: pick("a1", name: "beach.jpg"))
        let nameless = fixture.model.photoSource(for: pick(nil, name: "clip.mov"))

        #expect(source.assetID == "a1")
        #expect(source.suggestedName == "beach.jpg")
        #expect(nameless.assetID == nil)
        #expect(try await source.loadFile().lastPathComponent == "beach.jpg")
    }

    @Test("A loader whose photo cannot be written throws")
    func loaderThrowsWhenWriteFails() async throws {
        let fixture = try Fixture()
        defer { fixture.store.cleanup() }
        let broken = ImportPickedPhoto(
            assetID: "z9", suggestedName: "bad.jpg", writeFile: { _ in throw PresenterTestError() })

        let source = fixture.model.photoSource(for: broken)

        await #expect(throws: (any Error).self) { _ = try await source.loadFile() }
    }
}
