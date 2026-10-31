import UIKit

/// A button in the export sheet.
enum ExportSheetChoice: Equatable, Sendable {
    case saveToFiles, saveToCameraRoll, cancel

    var title: String {
        switch self {
        case .saveToFiles: return "Save to Files"
        case .saveToCameraRoll: return "Save to Camera Roll"
        case .cancel: return "Cancel"
        }
    }
}

/// What an export flow asks of its screen.
@MainActor
protocol ExportFlowViewing: AnyObject {
    /// Shows the overlay.
    func showOverlay(title: String)
    /// Removes the overlay.
    func hideOverlay()
    /// Opens the document picker for saving copies of `urls`. If it can't open, the view must call
    /// `documentPickerCancelled()` before returning, so the decrypted copies are removed.
    func presentDocumentPicker(urls: [URL])
    /// Shows a message.
    func showMessage(_ text: String)
    /// Shows an error.
    func showError(_ text: String)
}

/// The export flow's logic: what the sheet offers, what a choice does, and when decrypted copies are removed.
@MainActor
final class ExportFlowModel {
    private let exporter: any VaultExporting
    private weak var view: (any ExportFlowViewing)?
    /// Removes the decrypted copies the open document picker is saving from; nil when no picker is open.
    private var pendingCleanUp: (@Sendable () -> Void)?

    /// - Parameter view: held weakly; whoever owns the screen keeps it alive.
    init(exporter: any VaultExporting, view: any ExportFlowViewing) {
        self.exporter = exporter
        self.view = view
    }

    /// The sheet's buttons for a selection, in order.
    func sheetChoices(for items: [VaultItem]) -> [ExportSheetChoice] {
        exporter.canSaveToPhotos(items) ? [.saveToFiles, .saveToCameraRoll, .cancel] : [.saveToFiles, .cancel]
    }

    /// Carries out a choice in the sheet. Returns once the document picker is open or the export has ended.
    func choose(_ choice: ExportSheetChoice, for items: [VaultItem]) async {
        switch choice {
        case .saveToFiles:
            await saveToFiles(items)
        case .saveToCameraRoll:
            await saveToCameraRoll(items)
        case .cancel:
            break
        }
    }

    /// The document picker returned: its copies were saved.
    func documentPicked() {
        cleanUpPending()
    }

    /// The document picker was dismissed without saving, or could not open.
    func documentPickerCancelled() {
        cleanUpPending()
    }

    private func saveToFiles(_ items: [VaultItem]) async {
        view?.showOverlay(title: "Exporting...")
        do {
            let bundle = try await exporter.prepareForSharing(items)
            cleanUpPending()
            guard let view else {
                // The screen went away during preparing, so no picker will ever close to remove the copies.
                bundle.cleanUp()
                return
            }
            pendingCleanUp = bundle.cleanUp
            view.hideOverlay()
            view.presentDocumentPicker(urls: bundle.urls)
        } catch {
            view?.hideOverlay()
            report(error)
        }
    }

    private func saveToCameraRoll(_ items: [VaultItem]) async {
        view?.showOverlay(title: "Saving to Camera Roll...")
        do {
            let result = try await exporter.saveToPhotos(items)
            view?.hideOverlay()
            view?.showMessage(Self.message(for: result))
        } catch {
            view?.hideOverlay()
            report(error)
        }
    }

    private func cleanUpPending() {
        let cleanUp = pendingCleanUp
        pendingCleanUp = nil
        cleanUp?()
    }

    /// Shows a failed export's error. A cancelled export shows nothing.
    private func report(_ error: any Error) {
        switch error {
        case is CancellationError:
            break
        case ExportError.nothingToExport:
            view?.showError("Nothing to export.")
        case ExportError.photoAccessDenied:
            view?.showError("Allow KoalaTVault to add photos in Settings.")
        default:
            view?.showError(error.localizedDescription)
        }
    }

    private static func message(for result: PhotoSaveResult) -> String {
        guard result.failed == 0 else { return "\(result.saved) saved, \(result.failed) failed" }
        return "\(result.saved) item\(result.saved == 1 ? "" : "s") saved to Camera Roll"
    }
}

/// Where the export sheet points on iPad, where it is a popover.
enum ExportSheetAnchor {
    case barButton(UIBarButtonItem)
    case sourceView(UIView)

    @MainActor
    fileprivate func apply(to popover: UIPopoverPresentationController?) {
        switch self {
        case .barButton(let item):
            popover?.barButtonItem = item
        case .sourceView(let view):
            popover?.sourceView = view
            popover?.sourceRect = view.bounds
        }
    }
}

/// Presents the export sheet, document picker, overlays and alerts over the calling screen.
///
/// Create one and keep it for the app's lifetime: it holds the last picker until the next one replaces it
/// (see `lastPicker`), which a presenter created per export could not do. One instance can serve every screen,
/// since each export keeps its own state.
@MainActor
final class ExportPresenter {
    private let exporter: any VaultExporting
    /// The exports under way. Each stays here until it ends, because a picker's delegates are weak.
    private var flows: [ExportFlowController] = []
    /// The most recently presented picker. UIKit only holds a presented picker until it is dismissed, but on
    /// iOS 18 the document picker's remote service can still send XPC messages to it right after Cancel; if
    /// it has been deallocated, DocumentManager's `DOCWeakProxy` asserts and the app aborts. So it is never
    /// cleared, only replaced by the next picker.
    private var lastPicker: UIViewController?

    init(exporter: any VaultExporting) {
        self.exporter = exporter
    }

    /// Shows the export sheet over `viewController`.
    /// - Parameters:
    ///   - items: the selection to export.
    ///   - viewController: the calling screen; held weakly. The picker, overlays and alerts appear over it.
    ///   - anchor: what the sheet points at on iPad: the button or view the export started from.
    ///   - completion: runs once when the export has ended, however it ended, Cancel included.
    func presentExportSheet(
        for items: [VaultItem],
        from viewController: UIViewController & AlertPresenting,
        anchor: ExportSheetAnchor,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let flow = ExportFlowController(
            exporter: exporter, items: items, presenting: viewController, anchor: anchor,
            onPickerCreated: { [weak self] picker in self?.lastPicker = picker },
            onEnded: { [weak self] flow in
                self?.flows.removeAll { $0 === flow }
                completion?()
            })
        flows.append(flow)
        flow.presentSheet()
    }
}

/// One export, from the sheet to the end, and the UIKit views it shows.
@MainActor
private final class ExportFlowController: NSObject {
    private let items: [VaultItem]
    private let anchor: ExportSheetAnchor
    private let onPickerCreated: @MainActor (UIViewController) -> Void
    private var onEnded: (@MainActor (ExportFlowController) -> Void)?
    private weak var presenting: (UIViewController & AlertPresenting)?
    private let exporter: any VaultExporting
    private lazy var model = ExportFlowModel(exporter: exporter, view: self)
    private var overlay: ProgressOverlayView?
    private var pickerIsOpen = false

    init(
        exporter: any VaultExporting,
        items: [VaultItem],
        presenting: UIViewController & AlertPresenting,
        anchor: ExportSheetAnchor,
        onPickerCreated: @escaping @MainActor (UIViewController) -> Void,
        onEnded: @escaping @MainActor (ExportFlowController) -> Void
    ) {
        self.exporter = exporter
        self.items = items
        self.presenting = presenting
        self.anchor = anchor
        self.onPickerCreated = onPickerCreated
        self.onEnded = onEnded
    }

    func presentSheet() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for choice in model.sheetChoices(for: items) {
            let style: UIAlertAction.Style = choice == .cancel ? .cancel : .default
            let action = UIAlertAction(title: choice.title, style: style) { [self] _ in
                run(choice)
            }
            sheet.addAction(action)
        }
        anchor.apply(to: sheet.popoverPresentationController)
        presenting?.present(sheet, animated: true)
        if sheet.presentingViewController == nil { end() }
    }

    private func run(_ choice: ExportSheetChoice) {
        Task {
            await model.choose(choice, for: items)
            if !pickerIsOpen { end() }
        }
    }

    /// Runs once: later calls do nothing, since a swipe and a delegate callback can both report one close.
    private func end() {
        let ended = onEnded
        onEnded = nil
        ended?(self)
    }
}

// MARK: - ExportFlowViewing

extension ExportFlowController: ExportFlowViewing {
    func showOverlay(title: String) {
        guard let presenting else { return }
        overlay = ProgressOverlayView.show(in: presenting, title: title)
    }

    func hideOverlay() {
        overlay?.dismiss()
        overlay = nil
    }

    func presentDocumentPicker(urls: [URL]) {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = self
        // The picker's own delegate isn't told about every swipe-to-dismiss; this is.
        picker.presentationController?.delegate = self
        anchor.apply(to: picker.popoverPresentationController)
        onPickerCreated(picker)
        if presenting?.viewIfLoaded?.window != nil {
            presenting?.present(picker, animated: true)
        }
        // UIKit refuses a presentation only with a console warning (the screen has gone, or something else is
        // on it). No picker means no callback will ever come, so the decrypted copies are removed now.
        pickerIsOpen = picker.presentingViewController != nil
        if !pickerIsOpen { model.documentPickerCancelled() }
    }

    func showMessage(_ text: String) {
        presenting?.showSuccess(text)
    }

    func showError(_ text: String) {
        presenting?.showError(text)
    }
}

// MARK: - Picker delegates

extension ExportFlowController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        model.documentPicked()
        end()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        model.documentPickerCancelled()
        end()
    }
}

extension ExportFlowController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        model.documentPickerCancelled()
        end()
    }
}
