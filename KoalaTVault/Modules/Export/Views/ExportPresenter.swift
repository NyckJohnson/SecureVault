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
    /// Shows the overlay, without progress, with `status` under `title`.
    func showOverlay(title: String, status: String)
    /// Removes the overlay.
    func hideOverlay()
    /// Opens the document picker for saving copies of `urls`. If it can't open, the view must call
    /// `pickerRefused()`, so the decrypted copies are removed.
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
    private var pickerIsOpen = false
    /// Cleared when it runs, which makes it run only once.
    private var onEnded: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - view: held weakly; whoever owns the screen keeps it alive.
    ///   - onEnded: runs once when the export has ended, however it ended, Cancel included.
    init(exporter: any VaultExporting, view: any ExportFlowViewing, onEnded: @escaping @MainActor () -> Void = {}) {
        self.exporter = exporter
        self.view = view
        self.onEnded = onEnded
    }

    /// The sheet's buttons for a selection, in order.
    func sheetChoices(for items: [VaultItem]) -> [ExportSheetChoice] {
        exporter.canSaveToPhotos(items) ? [.saveToFiles, .saveToCameraRoll, .cancel] : [.saveToFiles, .cancel]
    }

    /// Carries out a choice in the sheet. Returns once the document picker is open or the export has ended;
    /// the export ends here unless a picker is open.
    func choose(_ choice: ExportSheetChoice, for items: [VaultItem]) async {
        switch choice {
        case .saveToFiles:
            await saveToFiles(items)
        case .saveToCameraRoll:
            await saveToCameraRoll(items)
        case .cancel:
            break
        }
        if !pickerIsOpen { end() }
    }

    /// The document picker returned: its copies were saved.
    func documentPicked() {
        closePicker()
    }

    /// The document picker closed without saving.
    func documentPickerCancelled() {
        closePicker()
    }

    /// The document picker could not open: removes the copies, says so and ends the export.
    func pickerRefused() {
        guard pickerIsOpen else { return }
        cleanUpPending()
        pickerIsOpen = false
        view?.showError("Couldn't open the Files picker.")
        end()
    }

    private func saveToFiles(_ items: [VaultItem]) async {
        view?.showOverlay(title: "Exporting...", status: Self.status("Exporting", count: items.count))
        do {
            let bundle = try await exporter.prepareForSharing(items)
            cleanUpPending()
            guard let view else {
                // The screen went away during preparing, so no picker will ever close to remove the copies.
                bundle.cleanUp()
                pickerIsOpen = false
                return
            }
            pendingCleanUp = bundle.cleanUp
            pickerIsOpen = true
            view.hideOverlay()
            view.presentDocumentPicker(urls: bundle.urls)
        } catch {
            view?.hideOverlay()
            report(error)
        }
    }

    private func saveToCameraRoll(_ items: [VaultItem]) async {
        view?.showOverlay(title: "Saving to Camera Roll...", status: Self.status("Saving", count: items.count))
        do {
            let result = try await exporter.saveToPhotos(items)
            view?.hideOverlay()
            view?.showMessage(Self.message(for: result))
        } catch {
            view?.hideOverlay()
            report(error)
        }
    }

    /// Does nothing unless a picker is open, so a second report of one close changes nothing.
    private func closePicker() {
        guard pickerIsOpen else { return }
        cleanUpPending()
        pickerIsOpen = false
        end()
    }

    private func cleanUpPending() {
        let cleanUp = pendingCleanUp
        pendingCleanUp = nil
        cleanUp?()
    }

    private func end() {
        let ended = onEnded
        onEnded = nil
        ended?()
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

    /// The overlay's status line, e.g. "Exporting 2 items…" or "Saving 1 item…".
    private static func status(_ verb: String, count: Int) -> String {
        "\(verb) \(count) item\(count == 1 ? "" : "s")\u{2026}"
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

/// One export, from the sheet to the end, and the UIKit views it shows. The rule for when it ends is the model's.
@MainActor
private final class ExportFlowController: NSObject {
    /// How often an open sheet or picker is checked for having left the screen.
    private static let closeCheckInterval = Duration.seconds(1)
    /// How long a sheet or picker that has left the screen gets to report why. UIKit documents no order between
    /// a picker closing and its delegate's pick callback, and the copies must outlast the copying, so this errs
    /// long: it only delays clean-up when nothing reports at all, which is the app dismissing the picker.
    private static let closeReportGrace = Duration.seconds(30)

    private let items: [VaultItem]
    private let anchor: ExportSheetAnchor
    private let onPickerCreated: @MainActor (UIViewController) -> Void
    private let onEnded: @MainActor (ExportFlowController) -> Void
    private weak var presenting: (UIViewController & AlertPresenting)?
    private let exporter: any VaultExporting
    private lazy var model = ExportFlowModel(exporter: exporter, view: self) { [weak self] in self?.flowEnded() }
    private var overlay: ProgressOverlayView?
    private var sheetWatch: Task<Void, Never>?
    private var pickerWatch: Task<Void, Never>?

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
        if sheet.presentingViewController == nil {
            run(.cancel)
        } else {
            sheetWatch = watchForClose(of: sheet) { [self] in run(.cancel) }
        }
    }

    private func run(_ choice: ExportSheetChoice) {
        sheetWatch?.cancel()
        Task {
            await model.choose(choice, for: items)
        }
    }

    private func flowEnded() {
        pickerWatch?.cancel()
        onEnded(self)
    }

    /// Runs `closed` some time after `controller` has left the screen, however it left. UIKit tells no delegate
    /// when the app dismisses a controller, and a controller covered by a lock screen gets no appearance callback
    /// when the stack under it goes, so its presenter is what is checked. Cancel the task to stop watching.
    private func watchForClose(
        of controller: UIViewController,
        closed: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                while controller.presentingViewController != nil {
                    try await Task.sleep(for: Self.closeCheckInterval)
                }
                try await Task.sleep(for: Self.closeReportGrace)
                closed()
            } catch {
                // Sleeping only throws on cancellation: the close was reported some other way.
            }
        }
    }
}

// MARK: - ExportFlowViewing

extension ExportFlowController: ExportFlowViewing {
    func showOverlay(title: String, status: String) {
        guard let presenting else { return }
        overlay = ProgressOverlayView.show(in: presenting, title: title, style: .activity, status: status)
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
        if picker.presentingViewController == nil {
            model.pickerRefused()
        } else {
            pickerWatch = watchForClose(of: picker) { [self] in model.documentPickerCancelled() }
        }
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
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        model.documentPickerCancelled()
    }
}

extension ExportFlowController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        model.documentPickerCancelled()
    }
}
