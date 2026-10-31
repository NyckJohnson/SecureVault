import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// What the user chose in the import sheet.
enum ImportSourceChoice: CaseIterable, Sendable {
    case files, folder, photos

    fileprivate var sheetTitle: String {
        switch self {
        case .files: return "Choose Files"
        case .folder: return "Choose Folder"
        case .photos: return "Choose Photos"
        }
    }
}

/// The picker an import flow shows.
enum ImportPickerKind: Sendable {
    case files, folder, photos
}

/// What an import flow asks of its screen.
@MainActor
protocol ImportFlowViewing: AnyObject {
    /// Opens a picker.
    func presentPicker(_ kind: ImportPickerKind)
    /// Closes the open picker, if any, and returns once it has fully gone.
    func dismissPicker() async
    /// Shows the overlay, or updates it if it is up; a nil `progress` leaves its progress as it is.
    func showOverlay(title: String, progress: Double?)
    /// Removes the overlay.
    func hideOverlay()
    /// Shows a message and returns once the user has acknowledged it.
    func showMessage(_ text: String) async
    /// Shows an error.
    func showError(_ text: String)
}

/// Asks the user for photo library access.
protocol ImportPhotoAccessRequesting: Sendable {
    /// Asks for read-write access and returns when answered. A refusal is fine: the picker works without
    /// access, its picks just have no asset IDs.
    func requestReadWriteAccess() async
}

/// One photo or video picked in the photo picker.
struct ImportPickedPhoto: Sendable {
    /// The photo library asset identifier; nil without library access.
    let assetID: String?
    /// The name to store the file under.
    let suggestedName: String
    /// Writes the photo's file to the given URL, which must not exist yet.
    let writeFile: @Sendable (URL) async throws -> Void
}

/// The import flow's logic: which picker opens, what a pick imports, and the order things happen in.
@MainActor
final class ImportFlowModel {
    /// The import sheet's buttons, in order; the last one cancels.
    static let sheetTitles = ImportSourceChoice.allCases.map(\.sheetTitle) + [cancelTitle]

    fileprivate static let cancelTitle = "Cancel"

    private let importer: any VaultImporting
    private let cameraRoll: any CameraRollDeleting
    private let photoAccess: any ImportPhotoAccessRequesting
    private let store: any VaultStoring
    private weak var view: (any ImportFlowViewing)?
    private let onLimitReached: @MainActor () -> Void
    private let onFinished: @MainActor () -> Void

    /// - Parameters:
    ///   - view: held weakly; whoever owns the screen keeps it alive.
    ///   - onLimitReached: runs after the picker has closed when the import would pass the free limit.
    ///   - onFinished: runs when an import has ended, however it ended, so the grid can reload. Part of a
    ///     failed import may have been kept. It does not run after a cancel.
    init(
        importer: any VaultImporting,
        cameraRoll: any CameraRollDeleting,
        photoAccess: any ImportPhotoAccessRequesting,
        store: any VaultStoring,
        view: any ImportFlowViewing,
        onLimitReached: @escaping @MainActor () -> Void,
        onFinished: @escaping @MainActor () -> Void = {}
    ) {
        self.importer = importer
        self.cameraRoll = cameraRoll
        self.photoAccess = photoAccess
        self.store = store
        self.view = view
        self.onLimitReached = onLimitReached
        self.onFinished = onFinished
    }

    /// Opens the picker for a choice in the sheet; photos ask for library access first.
    func choose(_ choice: ImportSourceChoice) async {
        switch choice {
        case .files:
            view?.presentPicker(.files)
        case .folder:
            view?.presentPicker(.folder)
        case .photos:
            await photoAccess.requestReadWriteAccess()
            view?.presentPicker(.photos)
        }
    }

    /// Closes the picker and imports nothing.
    func cancelPicker() async {
        await view?.dismissPicker()
    }

    /// Imports what was picked in a document picker.
    func pickedItems(_ urls: [URL], into directory: VaultDirectory) async {
        let importer = importer
        let result = await runImport(title: "Importing...") { reporter in
            try await importer.importItems(urls, into: directory) { reporter.yield($0) }
        }
        guard let result else { return }
        await reportFailures(imported: result.imported, failed: result.failed)
    }

    /// Imports what was picked in the photo picker, then asks to delete the imported originals.
    func pickedPhotos(_ photos: [ImportPickedPhoto], into directory: VaultDirectory) async {
        let importer = importer
        let result = await runImport(title: "Importing Photos...") { reporter in
            // `importPhotos` loads one photo at a time, so each load's position is its progress. It reports
            // a failed load as well, or the bar would stop short of the photos after it.
            let sources = photos.enumerated().map { index, photo in
                let fraction = Double(index + 1) / Double(photos.count)
                return Self.reportingLoads(of: self.photoSource(for: photo), as: fraction, to: reporter)
            }
            let result = try await importer.importPhotos(sources, into: directory)
            reporter.yield(1)
            return result
        }
        guard let result else { return }
        await reportFailures(imported: result.importedAssetIDs.count, failed: result.failed)
        if !result.importedAssetIDs.isEmpty {
            await cameraRoll.deleteAssets(withIdentifiers: result.importedAssetIDs)
        }
    }

    /// The import source for a picked photo: loading it writes the file alone in a new store temp folder,
    /// which `importPhotos` removes afterwards. A write that fails removes the folder here.
    func photoSource(for photo: ImportPickedPhoto) -> PhotoImportSource {
        let store = store
        return PhotoImportSource(assetID: photo.assetID, suggestedName: photo.suggestedName) {
            let folder = try store.makeTempDirectory()
            let file = folder.appendingPathComponent(photo.suggestedName)
            do {
                try await photo.writeFile(file)
            } catch {
                store.removeTemporary(folder)
                throw error
            }
            return file
        }
    }

    private static func reportingLoads(
        of source: PhotoImportSource,
        as fraction: Double,
        to reporter: AsyncStream<Double>.Continuation
    ) -> PhotoImportSource {
        PhotoImportSource(assetID: source.assetID, suggestedName: source.suggestedName) {
            defer { reporter.yield(fraction) }
            return try await source.loadFile()
        }
    }

    /// Closes the picker, runs `work` under the overlay, and handles an error once the overlay is gone.
    /// - Returns: what `work` returned, or nil if it threw.
    private func runImport<Output>(
        title: String,
        work: (AsyncStream<Double>.Continuation) async throws -> Output
    ) async -> Output? {
        await view?.dismissPicker()
        view?.showOverlay(title: title, progress: nil)

        // Importers report from any thread: the stream keeps the values in order, and draining it before the
        // overlay goes means none arrive afterwards.
        let (values, reporter) = AsyncStream.makeStream(of: Double.self)
        let overlayUpdates = Task {
            for await value in values { view?.showOverlay(title: title, progress: value) }
        }
        let outcome: Result<Output, any Error>
        do {
            outcome = .success(try await work(reporter))
        } catch {
            outcome = .failure(error)
        }
        reporter.finish()
        await overlayUpdates.value

        view?.hideOverlay()
        onFinished()

        switch outcome {
        case .success(let output):
            return output
        case .failure(ImportError.fileLimitReached):
            onLimitReached()
        case .failure(let error):
            view?.showError(error.localizedDescription)
        }
        return nil
    }

    private func reportFailures(imported: Int, failed: Int) async {
        guard failed > 0 else { return }
        await view?.showMessage("\(imported) imported, \(failed) failed")
    }
}

/// Where the import sheet points on iPad, where it is a popover.
enum ImportSheetAnchor {
    case barButton(UIBarButtonItem)
    case sourceView(UIView)
}

/// Presents the import sheet, pickers and overlays over the calling screen.
///
/// Create one and keep it for the app's lifetime: it holds the last picker until the next one replaces it
/// (see `lastPicker`), which a presenter created per import could not do.
@MainActor
final class ImportPresenter: NSObject {
    /// One sheet-to-import run.
    private struct Flow {
        let model: ImportFlowModel
        let directory: VaultDirectory
    }

    private let importer: any VaultImporting
    private let cameraRoll: any CameraRollDeleting
    private let photoAccess: any ImportPhotoAccessRequesting
    private let store: any VaultStoring

    private weak var presenting: (UIViewController & AlertPresenting)?
    private var flow: Flow?
    private var overlay: ProgressOverlayView?
    /// The most recently presented picker. UIKit only holds a presented picker until it is dismissed, but on
    /// iOS 18 the document picker's remote service can still send XPC messages to it right after Cancel; if
    /// it has been deallocated, DocumentManager's `DOCWeakProxy` asserts and the app aborts. So it is never
    /// cleared, only replaced by the next picker.
    private var lastPicker: UIViewController?

    init(
        importer: any VaultImporting,
        cameraRoll: any CameraRollDeleting,
        store: any VaultStoring,
        photoAccess: any ImportPhotoAccessRequesting = LiveImportPhotoAccess()
    ) {
        self.importer = importer
        self.cameraRoll = cameraRoll
        self.store = store
        self.photoAccess = photoAccess
    }

    /// Shows the import sheet over `viewController`.
    /// - Parameters:
    ///   - directory: the vault folder to import into.
    ///   - viewController: the calling screen; held weakly. Pickers, overlays and alerts appear over it.
    ///   - anchor: what the sheet points at on iPad: the Import button.
    ///   - onLimitReached: opens the paywall; runs after the picker has closed.
    ///   - completion: reloads the grid; runs when an import has ended, however it ended, and not after a cancel.
    func presentImportSheet(
        into directory: VaultDirectory,
        from viewController: UIViewController & AlertPresenting,
        anchor: ImportSheetAnchor,
        onLimitReached: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        presenting = viewController
        let model = ImportFlowModel(
            importer: importer, cameraRoll: cameraRoll, photoAccess: photoAccess, store: store, view: self,
            onLimitReached: onLimitReached, onFinished: completion)
        flow = Flow(model: model, directory: directory)

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for choice in ImportSourceChoice.allCases {
            let action = UIAlertAction(title: choice.sheetTitle, style: .default) { [weak self] _ in
                self?.run { flow in await flow.model.choose(choice) }
            }
            sheet.addAction(action)
        }
        let cancel = UIAlertAction(title: ImportFlowModel.cancelTitle, style: .cancel) { [weak self] _ in
            self?.endFlow(of: model)
        }
        sheet.addAction(cancel)
        switch anchor {
        case .barButton(let item):
            sheet.popoverPresentationController?.barButtonItem = item
        case .sourceView(let view):
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = view.bounds
        }
        viewController.present(sheet, animated: true)
    }

    /// Runs a step of the current flow; a late picker callback, with no flow left, is ignored.
    private func run(_ step: @escaping @MainActor (Flow) async -> Void) {
        guard let flow else { return }
        Task {
            await step(flow)
        }
    }

    /// Runs the step that closes the flow, then lets go of its callbacks.
    private func runToEnd(_ step: @escaping @MainActor (Flow) async -> Void) {
        guard let flow else { return }
        Task {
            await step(flow)
            endFlow(of: flow.model)
        }
    }

    private func endFlow(of model: ImportFlowModel) {
        if flow?.model === model { flow = nil }
    }
}

// MARK: - ImportFlowViewing

extension ImportPresenter: ImportFlowViewing {
    func presentPicker(_ kind: ImportPickerKind) {
        let picker: UIViewController
        switch kind {
        case .files:
            picker = makeDocumentPicker(for: .item)
        case .folder:
            picker = makeDocumentPicker(for: .folder)
        case .photos:
            var configuration = PHPickerConfiguration(photoLibrary: .shared())
            configuration.selectionLimit = 0
            configuration.filter = .any(of: [.images, .videos])
            let photoPicker = PHPickerViewController(configuration: configuration)
            photoPicker.delegate = self
            picker = photoPicker
        }
        lastPicker = picker
        presenting?.present(picker, animated: true)
    }

    /// Document pickers close themselves around their delegate callback, the photo picker doesn't. A
    /// dismissal asked for while one is running never calls its completion, so this watches the picker's
    /// state instead of relying on one.
    func dismissPicker() async {
        guard let picker = lastPicker, picker.presentingViewController != nil else { return }
        if picker is PHPickerViewController, !picker.isBeingDismissed {
            picker.dismiss(animated: true)
        }
        for _ in 0..<40 where picker.presentingViewController != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if picker.presentingViewController != nil, !picker.isBeingDismissed {
            picker.dismiss(animated: false)
        }
    }

    func showOverlay(title: String, progress: Double?) {
        guard let presenting else { return }
        let overlay = overlay ?? ProgressOverlayView.show(in: presenting, title: title)
        self.overlay = overlay
        if let progress {
            overlay.update(progress: Float(progress), status: "\(min(100, Int(progress * 100)))% complete")
        }
    }

    func hideOverlay() {
        overlay?.dismiss()
        overlay = nil
    }

    func showMessage(_ text: String) async {
        guard let presenting else { return }
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume() })
            presenting.topmostPresentedController.present(alert, animated: true)
        }
    }

    func showError(_ text: String) {
        presenting?.showError(text)
    }

    private func makeDocumentPicker(for type: UTType) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [type])
        picker.delegate = self
        picker.allowsMultipleSelection = true
        return picker
    }
}

// MARK: - Picker delegates

extension ImportPresenter: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        runToEnd { flow in await flow.model.pickedItems(urls, into: flow.directory) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        runToEnd { flow in await flow.model.cancelPicker() }
    }
}

extension ImportPresenter: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        // Cancel in the photo picker arrives as an empty result.
        if results.isEmpty {
            runToEnd { flow in await flow.model.cancelPicker() }
        } else {
            let photos = results.map(ImportPickedPhoto.init(result:))
            runToEnd { flow in await flow.model.pickedPhotos(photos, into: flow.directory) }
        }
    }
}

// MARK: - The live photo library

/// Asks the photo library for access.
struct LiveImportPhotoAccess: ImportPhotoAccessRequesting {
    func requestReadWriteAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
}

/// A picked item's provider. `NSItemProvider` is not `Sendable`, so it stays on the main actor and only the
/// start of a load runs there; the file is copied on the provider's own queue.
@MainActor
private final class PickedItemFile {
    private let provider: NSItemProvider

    init(provider: NSItemProvider) {
        self.provider = provider
    }

    func write(typeID: String, name: String, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeID) { file, error in
                // The file is deleted when this callback returns, so it is copied here.
                guard let file else {
                    continuation.resume(throwing: error ?? ImportError.unreadableSource(name))
                    return
                }
                do {
                    try FileManager.default.copyItem(at: file, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension ImportPickedPhoto {
    /// A pick from the photo picker. Its file is the item's image or video representation.
    @MainActor
    fileprivate init(result: PHPickerResult) {
        let provider = result.itemProvider
        let typeID = provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }
        let name = Self.fileName(baseName: provider.suggestedName, typeID: typeID)
        let file = PickedItemFile(provider: provider)
        self.init(assetID: result.assetIdentifier, suggestedName: name) { destination in
            guard let typeID else { throw ImportError.unreadableSource(name) }
            try await file.write(typeID: typeID, name: name, to: destination)
        }
    }

    /// The provider's name usually has no extension; the file's type supplies it.
    private static func fileName(baseName: String?, typeID: String?) -> String {
        let name = baseName ?? "photo"
        guard (name as NSString).pathExtension.isEmpty,
            let typeID,
            let fileExtension = UTType(typeID)?.preferredFilenameExtension
        else { return name }
        return (name as NSString).appendingPathExtension(fileExtension) ?? name
    }
}
