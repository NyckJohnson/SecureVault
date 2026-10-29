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
    private let temporaryFolders: [URL]
    private let vaultStore: any VaultStoring
    private static var associationKey: UInt8 = 0

    private init(temporaryFolders: [URL], vaultStore: any VaultStoring) {
        self.temporaryFolders = temporaryFolders
        self.vaultStore = vaultStore
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanup()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanup()
    }

    private func cleanup() {
        for url in temporaryFolders {
            vaultStore.removeTemporary(url)
        }
    }

    static func attach(to picker: UIDocumentPickerViewController, temporaryFolders: [URL], vaultStore: any VaultStoring) {
        guard !temporaryFolders.isEmpty else { return }
        let delegate = ExportCleanupDelegate(temporaryFolders: temporaryFolders, vaultStore: vaultStore)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &associationKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

@MainActor
final class ExportService {
    private let fileSystem: FileSystem
    private let vaultStore: any VaultStoring

    /// - Parameters:
    ///   - fileSystem: legacy export over the vault store (decrypted copies, camera roll).
    ///   - vaultStore: the app's vault store, which removes the decrypted copies afterwards.
    init(fileSystem: FileSystem, vaultStore: any VaultStoring) {
        self.fileSystem = fileSystem
        self.vaultStore = vaultStore
    }

    /// True when handing `item` to another app must go through a decrypted copy (an encrypted file, or a
    /// folder holding encrypted files), so a drag of it must stay inside the app.
    func needsDecryptedCopy(_ item: VaultItem) -> Bool {
        fileSystem.needsDecryptedCopy(item)
    }

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
        let hasMedia = items.contains { $0.kind == .image || $0.kind == .video }
        let fileSystem = fileSystem
        let vaultStore = vaultStore

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "Save to Files", style: .default) { _ in
            let overlay = ProgressOverlayView.show(in: viewController, title: "Exporting...")
            Task { @MainActor in
                do {
                    let files = try await fileSystem.prepareForExport(items) { progress in
                        DispatchQueue.main.async {
                            overlay.update(progress: Float(progress), status: "\(Int(progress * 100))% complete")
                        }
                    }
                    overlay.dismiss()
                    let picker = UIDocumentPickerViewController(forExporting: files.urls, asCopy: true)
                    Self.configurePopover(picker.popoverPresentationController, sourceView: sourceView, barButtonItem: barButtonItem)
                    ExportCleanupDelegate.attach(to: picker, temporaryFolders: files.temporaryFolders, vaultStore: vaultStore)
                    viewController.present(picker, animated: true)
                } catch {
                    overlay.dismiss()
                    viewController.present(Self.errorAlert(error.localizedDescription), animated: true)
                }
            }
        })

        if hasMedia {
            sheet.addAction(UIAlertAction(title: "Save to Camera Roll", style: .default) { _ in
                Task {
                    let (succeeded, failed) = await fileSystem.exportToCameraRoll(items)
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
