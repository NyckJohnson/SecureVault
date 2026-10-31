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
//       init(exporter: any VaultExporting, view: any ExportFlowViewing,
//            onEnded: @escaping @MainActor () -> Void = {})   // runs once however the export ends
//       func sheetChoices(for items: [VaultItem]) -> [ExportSheetChoice]
//       func choose(_ choice: ExportSheetChoice, for items: [VaultItem]) async
//       func documentPicked()            // the picker returned (copies were saved)
//       func documentPickerCancelled()   // the picker was dismissed
//       func pickerRefused()             // the picker could not open
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
    private var duringPrepare: (@Sendable () async -> Void)?

    init(log: ExportLog) { self.log = log }

    var cleanUpCount: Int { lock.withLock { cleanUps } }

    func failPreparing(with error: any Error) { lock.withLock { prepareError = error } }
    func failSaving(with error: any Error) { lock.withLock { photoError = error } }
    func setPhotoResult(_ result: PhotoSaveResult) { lock.withLock { photoResult = result } }
    /// Runs `hook` inside `prepareForSharing`, before it returns.
    func onPrepare(_ hook: @escaping @Sendable () async -> Void) { lock.withLock { duringPrepare = hook } }
    func setMediaAllowed(_ allowed: Bool) { lock.withLock { mediaAllowed = allowed } }

    func prepareForSharing(_ items: [VaultItem]) async throws -> ExportBundle {
        log.add(.prepared)
        if let hook = lock.withLock({ duringPrepare }) { await hook() }
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
private final class EndCounter {
    private(set) var count = 0
    var hasEnded: Bool { count >= 1 }
    func record() { count += 1 }
}

@MainActor
private final class ViewHolder {
    var view: RecordingExportView?
    init(view: RecordingExportView) { self.view = view }
}

/// Builds a model without leaving a strong reference to the holder's view in the caller.
@MainActor
private func makeModel(
    exporter: ScriptedExporter, holder: ViewHolder, ends: EndCounter
) -> ExportFlowModel {
    ExportFlowModel(
        exporter: exporter, view: holder.view ?? RecordingExportView(log: ExportLog()),
        onEnded: { ends.record() })
}

@MainActor
private struct Fixture {
    let log = ExportLog()
    let view: RecordingExportView
    let exporter: ScriptedExporter
    let model: ExportFlowModel
    let ends = EndCounter()
    let items = [makeItem("a.jpg"), makeItem("b.txt")]

    init() {
        view = RecordingExportView(log: log)
        exporter = ScriptedExporter(log: log)
        let counter = ends
        model = ExportFlowModel(exporter: exporter, view: view, onEnded: { counter.record() })
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

    @Test("If the view is gone when preparing ends, the copies are removed once and no picker opens")
    func viewReleasedDuringPrepare() async {
        let log = ExportLog()
        let exporter = ScriptedExporter(log: log)
        let holder = ViewHolder(view: RecordingExportView(log: log))
        let ends = EndCounter()
        let model = makeModel(exporter: exporter, holder: holder, ends: ends)
        exporter.onPrepare { await MainActor.run { holder.view = nil } }
        await model.choose(.saveToFiles, for: [makeItem("a.jpg")])
        model.documentPickerCancelled()
        #expect(exporter.cleanUpCount == 1)
        #expect(log.pickers.isEmpty)
        #expect(ends.count == 1)
    }

    // MARK: Ending

    @Test("Choosing Cancel ends the export once")
    func endsOnCancel() async {
        let fixture = Fixture()
        await fixture.model.choose(.cancel, for: fixture.items)
        #expect(fixture.ends.count == 1)
    }

    @Test("A prepare failure ends the export once")
    func endsOnPrepareFailure() async {
        let fixture = Fixture()
        fixture.exporter.failPreparing(with: DescribedFailure(text: "Disk is full"))
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        #expect(fixture.ends.count == 1)
    }

    @Test("A cancelled prepare ends the export once")
    func endsOnCancelledPrepare() async {
        let fixture = Fixture()
        fixture.exporter.failPreparing(with: CancellationError())
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        #expect(fixture.ends.count == 1)
    }

    @Test("Nothing to export ends the export once")
    func endsOnNothingToExport() async {
        let fixture = Fixture()
        fixture.exporter.failPreparing(with: ExportError.nothingToExport)
        await fixture.model.choose(.saveToFiles, for: [])
        #expect(fixture.ends.count == 1)
    }

    @Test("A camera roll success ends the export once")
    func endsOnCameraRollSuccess() async {
        let fixture = Fixture()
        fixture.exporter.setPhotoResult(PhotoSaveResult(saved: 2, failed: 0, skipped: 0))
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.ends.count == 1)
    }

    @Test("Photo access denied ends the export once")
    func endsOnAccessDenied() async {
        let fixture = Fixture()
        fixture.exporter.failSaving(with: ExportError.photoAccessDenied)
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.ends.count == 1)
    }

    @Test("Another camera roll error ends the export once")
    func endsOnOtherSaveError() async {
        let fixture = Fixture()
        fixture.exporter.failSaving(with: DescribedFailure(text: "Library unavailable"))
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.ends.count == 1)
    }

    @Test("A cancelled camera roll save ends the export once")
    func endsOnCancelledSave() async {
        let fixture = Fixture()
        fixture.exporter.failSaving(with: CancellationError())
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.ends.count == 1)
    }

    @Test("The export has not ended while the document picker is open")
    func notEndedWhilePickerOpen() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        #expect(!fixture.ends.hasEnded)
    }

    @Test("Picking a destination ends the export once")
    func endsOnPick() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.documentPicked()
        #expect(fixture.ends.count == 1)
    }

    @Test("Cancelling the picker ends the export once")
    func endsOnPickerCancel() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.documentPickerCancelled()
        #expect(fixture.ends.count == 1)
    }

    @Test("A closing report after a pick does not end the export again")
    func doubleCloseEndsOnce() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.documentPicked()
        fixture.model.documentPickerCancelled()
        #expect(fixture.ends.count == 1)
    }

    // MARK: Picker refused

    @Test("A picker that cannot open removes the copies once")
    func refusedCleansUpOnce() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.pickerRefused()
        #expect(fixture.exporter.cleanUpCount == 1)
    }

    @Test("A picker that cannot open shows Couldn't open the Files picker.")
    func refusedShowsError() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.pickerRefused()
        #expect(fixture.log.errors == ["Couldn't open the Files picker."])
    }

    @Test("A picker that cannot open ends the export once")
    func refusedEndsOnce() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.pickerRefused()
        #expect(fixture.ends.count == 1)
    }

    @Test("A close report after a refused picker changes nothing")
    func closeAfterRefusedChangesNothing() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        fixture.model.pickerRefused()
        let eventsBefore = fixture.log.events
        fixture.model.documentPickerCancelled()
        #expect(fixture.exporter.cleanUpCount == 1)
        #expect(fixture.ends.count == 1)
        #expect(fixture.log.events == eventsBefore)
    }

    // MARK: Second export

    @Test("Starting a second Save to Files while a picker is open cleans up the first bundle once")
    func secondExportCleansUpFirst() async {
        let fixture = Fixture()
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        await fixture.model.choose(.saveToFiles, for: fixture.items)
        #expect(fixture.exporter.cleanUpCount == 1)
        fixture.model.documentPicked()
        #expect(fixture.exporter.cleanUpCount == 2)
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

    @Test("Nothing to export hides the overlay and shows Nothing to export. with no picker")
    func nothingToExportShowsError() async {
        let fixture = Fixture()
        fixture.exporter.failPreparing(with: ExportError.nothingToExport)
        await fixture.model.choose(.saveToFiles, for: [])
        #expect(fixture.log.errors == ["Nothing to export."])
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

    struct NoFailureCase: Sendable {
        let saved: Int
        let expected: String
    }

    nonisolated static let noneSaved = NoFailureCase(saved: 0, expected: "0 items saved to Camera Roll")
    nonisolated static let oneSaved = NoFailureCase(saved: 1, expected: "1 item saved to Camera Roll")
    nonisolated static let fourSaved = NoFailureCase(saved: 4, expected: "4 items saved to Camera Roll")
    nonisolated static let noFailureCases = [noneSaved, oneSaved, fourSaved]

    @Test("Save to Camera Roll without failures reports N item(s) saved to Camera Roll", arguments: noFailureCases)
    func cameraRollNothingFailed(_ testCase: NoFailureCase) async {
        let fixture = Fixture()
        fixture.exporter.setPhotoResult(PhotoSaveResult(saved: testCase.saved, failed: 0, skipped: 0))
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.log.messages == [testCase.expected])
        #expect(fixture.log.errors.isEmpty)
    }

    @Test("Skipped items are not mentioned in the message")
    func cameraRollSkippedNotMentioned() async {
        let fixture = Fixture()
        fixture.exporter.setPhotoResult(PhotoSaveResult(saved: 1, failed: 0, skipped: 5))
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.log.messages == ["1 item saved to Camera Roll"])
    }

    @Test("Skipped items are not mentioned when some saves failed")
    func cameraRollSkippedWithFailures() async {
        let fixture = Fixture()
        fixture.exporter.setPhotoResult(PhotoSaveResult(saved: 2, failed: 1, skipped: 5))
        await fixture.model.choose(.saveToCameraRoll, for: fixture.items)
        #expect(fixture.log.messages == ["2 saved, 1 failed"])
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
