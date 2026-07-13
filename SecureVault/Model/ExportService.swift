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
    
    func export(_ item: FileItem, from viewController: UIViewController,
                sourceView: UIView? = nil, barButtonItem: UIBarButtonItem? = nil) {
        let ext = item.url.pathExtension.lowercased()
        let isMedia = ["jpg","jpeg","png","heic","gif","webp","mp4","mov","m4v"].contains(ext)
        
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        
        sheet.addAction(UIAlertAction(title: "Save to Files", style: .default) { _ in
            self.exportToFiles(item: item, from: viewController)
        })
        
        if isMedia {
            sheet.addAction(UIAlertAction(title: "Save to Camera Roll", style: .default) { _ in
                self.exportToCameraRoll(item: item, from: viewController)
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
    
    private func exportToFiles(item: FileItem, from viewController: UIViewController) {
        let picker = UIDocumentPickerViewController(forExporting: [item.url], asCopy: true)
        viewController.present(picker, animated: true)
    }
    
    private func exportToCameraRoll(item: FileItem, from viewController: UIViewController) {
        let ext = item.url.pathExtension.lowercased()
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges({
                if ["mp4","mov","m4v"].contains(ext) {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: item.url)
                } else {
                    guard let image = UIImage(contentsOfFile: item.url.path) else { return }
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }) { success, error in
                DispatchQueue.main.async {
                    let message = success ? "Saved to Camera Roll" : "Failed to save: \(error?.localizedDescription ?? "Unknown error")"
                    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    viewController.present(alert, animated: true)
                }
            }
        }
    }
    
    func exportMultiple(_ items: [FileItem], from viewController: UIViewController, barButtonItem: UIBarButtonItem? = nil) {
        let hasMedia = items.contains { ["jpg","jpeg","png","heic","gif","webp","mp4","mov","m4v"].contains($0.url.pathExtension.lowercased()) }
        let hasNonMedia = items.contains { !["jpg","jpeg","png","heic","gif","webp","mp4","mov","m4v"].contains($0.url.pathExtension.lowercased()) }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        // always offer Files export
        sheet.addAction(UIAlertAction(title: "Save to Files", style: .default) { _ in
            let urls = items.map { $0.url }
            let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
            picker.popoverPresentationController?.barButtonItem = barButtonItem
            viewController.present(picker, animated: true)
        })

        // only offer camera roll if there are media files
        if hasMedia {
            sheet.addAction(UIAlertAction(title: "Save to Camera Roll", style: .default) { _ in
                let mediaItems = items.filter { ["jpg","jpeg","png","heic","gif","webp","mp4","mov","m4v"].contains($0.url.pathExtension.lowercased()) }
                let total = mediaItems.count
                var succeeded = 0
                var failed = 0

                let checkCompletion = {
                    if succeeded + failed == total {
                        let message = failed == 0
                            ? "\(succeeded) item\(succeeded == 1 ? "" : "s") saved to Camera Roll"
                            : "\(succeeded) saved, \(failed) failed"
                        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        viewController.present(alert, animated: true)
                    }
                }

                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized else { return }
                    for item in mediaItems {
                        let ext = item.url.pathExtension.lowercased()
                        PHPhotoLibrary.shared().performChanges({
                            if ["mp4","mov","m4v"].contains(ext) {
                                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: item.url)
                            } else {
                                guard let image = UIImage(contentsOfFile: item.url.path) else { return }
                                PHAssetChangeRequest.creationRequestForAsset(from: image)
                            }
                        }) { success, _ in
                            DispatchQueue.main.async {
                                if success { succeeded += 1 } else { failed += 1 }
                                checkCompletion()
                            }
                        }
                    }
                }
            })
        }

        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = barButtonItem
        }
        viewController.present(sheet, animated: true)
    }
}
