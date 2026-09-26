//
//  ExportService.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/1/26.
//

import UIKit
import Photos

final class ExportService {
    static let shared = ExportService()
    private init() {}

    func export(_ item: VaultItem, from viewController: UIViewController, sourceView: UIView? = nil, barButtonItem: UIBarButtonItem? = nil) {
        exportMultiple([item], from: viewController, sourceView: sourceView, barButtonItem: barButtonItem)
    }

    func exportMultiple(_ items: [VaultItem], from viewController: UIViewController, sourceView: UIView? = nil, barButtonItem: UIBarButtonItem? = nil) {
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
                        overlay.update(progress: Float(progress), status: "\(Int(progress * 100))% complete")
                    }
                    DispatchQueue.main.async {
                        overlay.dismiss()
                        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
                        Self.configurePopover(picker.popoverPresentationController, sourceView: sourceView, barButtonItem: barButtonItem)
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
                FileSystem.shared.exportToCameraRoll(items) { succeeded, failed in
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

    private static func configurePopover(_ popover: UIPopoverPresentationController?, sourceView: UIView?, barButtonItem: UIBarButtonItem?) {
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
