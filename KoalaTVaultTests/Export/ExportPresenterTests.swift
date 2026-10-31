import Foundation

import Testing

@testable import KoalaTVault

// Assumed seam (all in Views/ExportPresenter.swift, none in Contracts/):
//   enum ExportSheetChoice: Equatable, Sendable { case saveToFiles, saveToCameraRoll, cancel; var title: String }
//   @MainActor protocol ExportFlowViewing: AnyObject {
//       func showOverlay(title: String); func hideOverlay()
//       func presentDocumentPicker(urls: [URL])
//       func showMessage(_ text: String); func showError(_ text: String)
//   }
//   @MainActor final class ExportFlowModel {
//       init(exporter: any VaultExporting, view: any ExportFlowViewing)
//       func sheetChoices(for items: [VaultItem]) -> [ExportSheetChoice]
//       func choose(_ choice: ExportSheetChoice, for items: [VaultItem]) async
//       func documentPicked()            // the picker returned (copies were saved)
//       func documentPickerCancelled()   // the picker was dismissed
//   }

private enum ExportEvent: Equatable, Sendable {
    case overlay(String)
    case overlayHidden
    case picker([URL])
    case message(String)
    case error(String)
    case prepared
    case savedToPhotos
}

private final class ExportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ExportEvent] = []

    var events: [ExportEvent] { lock.withLock { storage } }
    func add(_ event: ExportEvent) { lock.withLock { storage.append(event) } }
    func index(of event: ExportEvent) -> Int? { events.firstIndex(of: event) }

    var errors: [String] {
        events.compactMap { event in
            if case .error(let text) = event { return text }
            return nil
        }
    }

    var messages: [String] {
        events.compactMap { event in
            if case .message(let text) = event { return text }
            return nil
        }
    }

    var overlays: [String] {
        events.compactMap { event in
            if case .overlay(let title) = event { return title }
            return nil
        }
    }

    var pickers: [[URL]] {
        events.compactMap { event in
            if case .picker(let urls) = event { return urls }
            return nil
        }
    }
}

@MainActor
private final class RecordingExportView: ExportFlowViewing {
    let log: ExportLog
    init(log: ExportLog) { self.log = log }

    func showOverlay(title: String) { log.add(.overlay(title)) }
    func hideOverlay() { log.add(.overlayHidden) }
    func presentDocumentPicker(urls: [URL]) { log.add(.picker(urls)) }
    func showMessage(_ text: String) { log.add(.message(text)) }
    func showError(_ text: String) { log.add(.error(text)) }
}

private struct DescribedFailure: LocalizedError, Equatable {
    let text: String
    var errorDescription: String? { text }
}

/// An exporter whose outcomes are scripted and whose bundle clean-ups are counted.
private final class ScriptedExporter: VaultExporting, @unchecked Sendable {
    private let log: ExportLog
    private let lock = NSLock()
    private var prepareError: (any Error)?
    private var photoError: (any Error)?
    private var photoResult = PhotoSaveResult(saved: 0, failed: 0, skipped: 0)
    private var mediaAllowed = true
    private var cleanUps = 0

    init(log: ExportLog) { self.log = log }

    var cleanUpCount: Int { lock.withLock { cleanUps } }

    func failPreparing(with error: any Error) { lock.withLock { prepareError = error } }
    func failSaving(with error: any Error) { lock.withLock { photoError = error } }
    func setPhotoResult(_ result: PhotoSaveResult) { lock.withLock { photoResult = result } }
    func setMediaAllowed(_ allowed: Bool) { lock.withLock { mediaAllowed = allowed } }

    func prepareForSharing(_ items: [VaultItem]) async throws -> ExportBundle {
        log.add(.prepared)
        if let error = lock.withLock({ prepareError }) { throw error }
        return ExportBundle(urls: items.map(\.diskURL)) { [self] in
            lock.withLock { cleanUps += 1 }
        }
    }

    func saveToPhotos(_ items: [VaultItem]) async throws -> PhotoSaveResult {
        log.add(.savedToPhotos)
        if let error = lock.withLock({ photoError }) { throw error }
        return lock.withLock { photoResult }
    }

    func canSaveToPhotos(_ items: [VaultItem]) -> Bool { lock.withLock { mediaAllowed } }
}

private func makeItem(_ name: String) -> VaultItem {
    let root = URL(fileURLWithPath: "/tmp/ExportPresenterTests/vault", isDirectory: true)
    return VaultItem(
        id: name, name: name, isDirectory: false, dateModified: Date(), fileSize: 1, deletedAt: nil,
        diskURL: root.appendingPathComponent(name), rootURL: root, isEncrypted: false)
}

@MainActor
private struct Fixture {
    let log = ExportLog()
    let view: RecordingExportView
    let exporter: ScriptedExporter
    let model: ExportFlowModel
    let items = [makeItem("a.jpg"), makeItem("b.txt")]

    init() {
        view = RecordingExportView(log: log)
        exporter = ScriptedExporter(log: log)
        model = ExportFlowModel(exporter: exporter, view: view)
    }
}

@MainActor
@Suite struct ExportPresenterTests {
    // MARK: Sheet

    @Test("The sheet offers Save to Files, Save to Camera Roll and Cancel when photos can be saved")
    func sheetWithPhotos() {
        let fixture = Fixture()
        let choices = fixture.model.sheetChoices(for: fixture.items)
        #expect(choices == [.saveToFiles, .saveToCameraRoll, .cancel])
        #expect(choices.map(\.title) == ["Save to Files", "Save to Camera Roll", "Cancel"])
    }

    @Test("The sheet leaves out Save to Camera Roll when photos cannot be saved")
    func sheetWithoutPhotos() {
        let fixture = Fixture()
        fixture.exporter.setMediaAllowed(false)
        let choices = fixture.model.sheetChoices(for: fixture.items)
        #expect(choices == [.saveToFiles, .cancel])
        #expect(choices.map(\.title) == ["Save to Files", "Cancel"])
    }

    @Test("Choosing Cancel does nothing")
    func cancelDoesNothing() async {
        let fixture = Fixture()
        await fixture.model.choose(.cancel, for: fixture.items)
        #expect(fixture.log.events.isEmpty)
        #expect(fixture.exporter.cleanUpCount == 0)
    }

    // MARK: Save to Files

    @Test("Save to Files shows the Exporting... overlay while preparing")
    func filesShowsOverlay() async throws {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        #expect(fixture.log.overlays == ["Exporting..."])
        let overlay = try #require(fixture.log.index(of: .overlay("Exporting...")))
        let prepared = try #require(fixture.log.index(of: .prepared))
        #expect(overlay < prepared)
    }

    @Test("Save to Files presents the document picker with the bundle's URLs")
    func filesPresentsPicker() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        #expect(fixture.log.pickers == [fixture.items.map(\.diskURL)])
    }

    @Test("The overlay is hidden before the document picker appears")
    func overlayHiddenBeforePicker() async throws {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        let hidden = try #require(fixture.log.index(of: .overlayHidden))
        let picker = try #require(fixture.log.index(of: .picker(fixture.items.map(\.diskURL))))
        #expect(hidden < picker)
    }

    @Test("Clean-up does not run while the picker is open")
    func noCleanUpWhilePickerOpen() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        #expect(fixture.exporter.cleanUpCount == 0)
    }

    @Test("Picking a destination cleans up exactly once")
    func pickCleansUpOnce() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.documentPicked()
        #expect(fixture.exporter.cleanUpCount == 1)
    }

    @Test("Cancelling the picker cleans up exactly once")
    func pickerCancelCleansUpOnce() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.documentPickerCancelled()
        #expect(fixture.exporter.cleanUpCount == 1)
    }

    @Test("Closing the picker twice still cleans up once")
    func closingTwiceCleansUpOnce() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.documentPicked()
        fixture.model.documentPickerCancelled()
        #expect(fixture.exporter.cleanUpCount == 1)
    }

    @Test("Closing a picker that never opened cleans up nothing")
    func closeWithoutExportDoesNothing() {
        let fixture = Fixture()
        fixture.model.documentPicked()
        fixture.model.documentPickerCancelled()
        #expect(fixture.exporter.cleanUpCount == 0)
        #expect(fixture.log.events.isEmpty)
    }

    @Test("A prepare failure hides the overlay and shows the error's text with no picker")
    func prepareFailureShowsError() async {
        let fixture = Fixture()
        fixture.exporter.failPreparing(with: DescribedFailure(text: "Disk is full"))
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        #expect(fixture.log.errors == ["Disk is full"])
        #expect(fixture.log.index(of: .overlayHidden) != nil)
        #expect(fixture.log.pickers.isEmpty)
    }

    @Test("A prepare failure leaves nothing to clean up when the picker is closed later")
    func prepareFailureLeavesNothing() async {
        let fixture = Fixture()
        fixture.exporter.failPreparing(with: DescribedFailure(text: "Disk is full"))
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.documentPickerCancelled()
        #expect(fixture.exporter.cleanUpCount == 0)
    }

    @Test("A cancelled export hides the overlay and shows no error and no picker")
    func cancelledPrepareShowsNoError() async {
        let fixture = Fixture()
        fixture.exporter.failPreparing(with: CancellationError())
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        #expect(fixture.log.errors.isEmpty)
        #expect(fixture.log.pickers.isEmpty)
        #expect(fixture.log.index(of: .overlayHidden) != nil)
    }

    @Test("Nothing to export hides the overlay and shows some error text with no picker")
    func nothingToExportShowsError() async {
        let fixture = Fixture()
        fixture.exporter.failPreparing(with: ExportError.nothingToExport)
        await fixture.model.choose(.saveToFiles, for: [])
        #expect(fixture.log.errors.count == 1)
        #expect(fixture.log.errors.first?.isEmpty == false)
        #expect(fixture.log.pickers.isEmpty)
        #expect(fixture.log.index(of: .overlayHidden) != nil)
    }

    // MARK: Save to Camera Roll

    @Test("Save to Camera Roll shows an overlay and then the saved and failed counts")
    func cameraRollShowsCounts() async throws {
        let fixture = Fixture()
        fixture.exporter.setPhotoResult(PhotoSaveResult(saved: 3, failed: 2, skipped: 0))
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.log.overlays.count == 1)
        #expect(fixture.log.messages == ["3 saved, 2 failed"])
        let overlay = try #require(fixture.log.index(of: .overlay(fixture.log.overlays[0])))
        let saved = try #require(fixture.log.index(of: .savedToPhotos))
        let hidden = try #require(fixture.log.index(of: .overlayHidden))
        let message = try #require(fixture.log.index(of: .message("3 saved, 2 failed")))
        #expect(overlay < saved)
        #expect(saved < hidden)
        #expect(hidden < message)
    }

    @Test("Save to Camera Roll reports zero failures as 0 failed")
    func cameraRollNothingFailed() async {
        let fixture = Fixture()
        fixture.exporter.setPhotoResult(PhotoSaveResult(saved: 4, failed: 0, skipped: 0))
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.log.messages == ["4 saved, 0 failed"])
        #expect(fixture.log.errors.isEmpty)
    }

    @Test("Skipped items are not counted as saved or failed in the message")
    func cameraRollSkippedNotMentioned() async {
        let fixture = Fixture()
        fixture.exporter.setPhotoResult(PhotoSaveResult(saved: 1, failed: 0, skipped: 5))
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.log.messages == ["1 saved, 0 failed"])
    }

    @Test("Save to Camera Roll presents no document picker and leaves nothing to clean up")
    func cameraRollNoPicker() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        fixture.model.documentPickerCancelled()
        #expect(fixture.log.pickers.isEmpty)
        #expect(fixture.exporter.cleanUpCount == 0)
    }

    @Test("Photo access denied shows the Settings message and hides the overlay")
    func accessDeniedMessage() async {
        let fixture = Fixture()
        fixture.exporter.failSaving(with: ExportError.photoAccessDenied)
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.log.errors == ["Allow KoalaTVault to add photos in Settings."])
        #expect(fixture.log.index(of: .overlayHidden) != nil)
        #expect(fixture.log.messages.isEmpty)
    }

    @Test("Other save errors are shown with their own text")
    func otherSaveErrorShown() async {
        let fixture = Fixture()
        fixture.exporter.failSaving(with: DescribedFailure(text: "Library unavailable"))
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.log.errors == ["Library unavailable"])
        #expect(fixture.log.index(of: .overlayHidden) != nil)
        #expect(fixture.log.messages.isEmpty)
    }

    @Test("A cancelled camera roll save hides the overlay and shows nothing")
    func cancelledSaveShowsNothing() async {
        let fixture = Fixture()
        fixture.exporter.failSaving(with: CancellationError())
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.log.errors.isEmpty)
        #expect(fixture.log.messages.isEmpty)
        #expect(fixture.log.index(of: .overlayHidden) != nil)
    }
}
