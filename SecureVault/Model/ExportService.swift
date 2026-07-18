//
//  ExportService.swift
//  SecureVault
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
            ["jpg","jpeg","png","heic","gif","webp","mp4","mov","m4v"].contains(($0.name as NSString).pathExtension.lowercased())
        }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "Save to Files", style: .default) { _ in
            do {
                let urls = try FileSystem.shared.prepareForExport(items)
                let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
                if let barButtonItem {
                    picker.popoverPresentationController?.barButtonItem = barButtonItem
                } else if let sourceView {
                    picker.popoverPresentationController?.sourceView = sourceView
                    picker.popoverPresentationController?.sourceRect = sourceView.bounds
                }
                viewController.present(picker, animated: true)
            } catch {
                viewController.present(Self.errorAlert(error.localizedDescription), animated: true)
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

        if let popover = sheet.popoverPresentationController {
            if let barButtonItem {
                popover.barButtonItem = barButtonItem
            } else if let sourceView {
                popover.sourceView = sourceView
                popover.sourceRect = sourceView.bounds
            }
        }
        viewController.present(sheet, animated: true)
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
