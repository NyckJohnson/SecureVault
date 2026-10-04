//
//  ExportService.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/1/26.
//

import UIKit
import Photos

// Deletes decrypted temp copies once the document picker finishes or is cancelled.
// Retained on the picker itself via objc_setAssociatedObject because UIDocumentPickerDelegate is weak.
private final class ExportCleanupDelegate: NSObject, UIDocumentPickerDelegate {
    private let tempURLs: [URL]
    private static var associationKey: UInt8 = 0

    private init(tempURLs: [URL]) {
        self.tempURLs = tempURLs
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanup()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanup()
    }

    private func cleanup() {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func attach(to picker: UIDocumentPickerViewController, tempURLs: [URL]) {
        guard !tempURLs.isEmpty else { return }
        let delegate = ExportCleanupDelegate(tempURLs: tempURLs)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &associationKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

final class ExportService {
    static let shared = ExportService()
    private init() {}

    func export(
        _ item: VaultItem,
        from viewController: UIViewController,
        sourceView: UIView? = nil,
        barButtonItem: UIBarButtonItem? = nil
    ) {
        exportMultiple([item], from: viewController, sourceView: sourceView, barButtonItem: barButtonItem)
    }

    func exportMultiple(
        _ items: [VaultItem],
        from viewController: UIViewController,
        sourceView: UIView? = nil,
        barButtonItem: UIBarButtonItem? = nil
    ) {
        let hasMedia = items.contains {
            let kind = FileKind(extension: ($0.name as NSString).pathExtension.lowercased())
            return kind == .image || kind == .video
        }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "Save to Files", style: .default) { _ in
            let overlay = ProgressOverlay.show(in: viewController, title: "Exporting...")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let urls = try FileSystem.shared.prepareForExport(items) { progress in
                        DispatchQueue.main.async {
                            overlay.update(progress: Float(progress), status: "\(Int(progress * 100))% complete")
                        }
                    }
                    DispatchQueue.main.async {
                        overlay.dismiss()
                        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
                        Self.configurePopover(picker.popoverPresentationController, sourceView: sourceView, barButtonItem: barButtonItem)
                        let tmpDir = FileManager.default.temporaryDirectory.standardizedFileURL
                        let tempURLs = urls.filter { $0.standardizedFileURL.path.hasPrefix(tmpDir.path) }
                        ExportCleanupDelegate.attach(to: picker, tempURLs: tempURLs)
                        viewController.present(picker, animated: true)
                    }
                } catch {
                    DispatchQueue.main.async {
                        overlay.dismiss()
                        viewController.present(Self.errorAlert(error.localizedDescription), animated: true)
                    }
                }
            }
        })

        if hasMedia {
            sheet.addAction(UIAlertAction(title: "Save to Camera Roll", style: .default) { _ in
                Task {
                    let (succeeded, failed) = await FileSystem.shared.exportToCameraRoll(items)
                    let message = failed == 0
                    ? "\(succeeded) item\(succeeded == 1 ? "" : "s") saved to Camera Roll"
                    : "\(succeeded) saved, \(failed) failed"
                    viewController.present(Self.infoAlert(message), animated: true)
                }
            })
        }

        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        Self.configurePopover(sheet.popoverPresentationController, sourceView: sourceView, barButtonItem: barButtonItem)
        viewController.present(sheet, animated: true)
    }

    private static func configurePopover(
        _ popover: UIPopoverPresentationController?,
        sourceView: UIView?,
        barButtonItem: UIBarButtonItem?
    ) {
        if let barButtonItem {
            popover?.barButtonItem = barButtonItem
        } else if let sourceView {
            popover?.sourceView = sourceView
            popover?.sourceRect = sourceView.bounds
        }
    }
    
    private static func errorAlert(_ message: String) -> UIAlertController {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }

    private static func infoAlert(_ message: String) -> UIAlertController {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }
}
