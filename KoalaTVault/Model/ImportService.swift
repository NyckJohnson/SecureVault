//
//  ImportService.swift
//  KoalaTVault
//

import UIKit
import PhotosUI
import Photos
import UniformTypeIdentifiers

@MainActor
final class ImportService: NSObject {
    static let shared = ImportService()

    var cameraRollDeleter: CameraRollDeleting = PhotoLibraryCameraRollDeleter()

    private weak var presentingViewController: UIViewController?
    private var targetDirectory: VaultDirectory?
    private var completion: (() -> Void)?
    /// The most recently presented picker. UIKit only holds a presented picker until it is dismissed, but on
    /// iOS 18 the document picker's remote service can still send XPC messages to it right after
    /// Cancel; if it has been deallocated, DocumentManager's `DOCWeakProxy` asserts and the app aborts.
    /// We hold it until the next picker replaces it.
    private var activePicker: UIViewController?

    override init() {}

    func promptImport(
        into directory: VaultDirectory,
        from viewController: UIViewController,
        barButtonItem: UIBarButtonItem? = nil,
        completion: (() -> Void)? = nil
    ) {
        presentingViewController = viewController
        targetDirectory = directory
        self.completion = completion

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Choose Files", style: .default) { [weak self] _ in
            self?.presentFilePicker()
        })
        sheet.addAction(UIAlertAction(title: "Choose Folder", style: .default) { [weak self] _ in
            self?.presentFolderPicker()
        })
        sheet.addAction(UIAlertAction(title: "Choose Photos", style: .default) { [weak self] _ in
            self?.presentPhotoPicker()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = barButtonItem
        }
        viewController.present(sheet, animated: true)
    }

    // MARK: - Pickers
    private func presentFilePicker() {
        guard let viewController = presentingViewController else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = self
        picker.allowsMultipleSelection = true
        activePicker = picker
        viewController.present(picker, animated: true)
    }

    private func presentFolderPicker() {
        guard let viewController = presentingViewController else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = true
        activePicker = picker
        viewController.present(picker, animated: true)
    }

    private func presentPhotoPicker() {
        guard let viewController = presentingViewController else { return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    // proceed with picker anyway, but deletion won't be offered later
                    self?.presentPickerUI(from: viewController)
                    return
                }
                self?.presentPickerUI(from: viewController)
            }
        }
    }

    private func presentPickerUI(from viewController: UIViewController) {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        activePicker = picker
        viewController.present(picker, animated: true)
    }

    // MARK: - Import execution
    private func performImport(from urls: [URL]) {
        guard let viewController = presentingViewController, let directory = targetDirectory else { return }
        let overlay = ProgressOverlay.show(in: viewController, title: "Importing...")
        DispatchQueue.global(qos: .userInitiated).async {
            var importError: Error?
            do {
                var lastUpdate = Date()
                try FileSystem.shared.importItems(from: urls, to: directory) { progress in
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) > 0.1 || progress == 1.0 {
                        lastUpdate = now
                        DispatchQueue.main.async {
                            overlay.update(progress: Float(progress), status: "\(min(100, Int(progress * 100)))% complete")
                        }
                    }
                }
            } catch {
                importError = error
            }
            DispatchQueue.main.async {
                overlay.dismiss()
                self.completion?()
                if let error = importError {
                    if case FileSystemError.fileLimitReached = error {
                        let paywall = PaywallViewController()
                        paywall.modalPresentationStyle = .formSheet
                        viewController.present(paywall, animated: true)
                    } else {
                        (viewController as? ErrorPresenting)?.showError(error)
                    }
                }
            }
        }
    }
}

// MARK: - UIDocumentPickerDelegate
extension ImportService: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        performImport(from: urls)
    }
}

// MARK: - PHPickerViewControllerDelegate
extension ImportService: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard !results.isEmpty,
              let viewController = presentingViewController,
              let directory = targetDirectory else {
            picker.dismiss(animated: true)
            return
        }

        do {
            try FileSystem.shared.checkImportAllowed(additionalCount: results.count, in: directory)
        } catch FileSystemError.fileLimitReached {
            picker.dismiss(animated: true) {
                let paywall = PaywallViewController()
                paywall.modalPresentationStyle = .formSheet
                viewController.present(paywall, animated: true)
            }
            return
        } catch {
            picker.dismiss(animated: true) {
                (viewController as? ErrorPresenting)?.showError(error)
            }
            return
        }

        presentingViewController?.dismiss(animated: true)
        let overlay = ProgressOverlay.show(in: viewController, title: "Importing Photos...")
        FileSystem.shared.importFromCameraRoll(results: results, to: directory) { [weak self] succeededIdentifiers, failed in
            overlay.dismiss()
            self?.completion?()
            if failed > 0 {
                let alert = UIAlertController(
                    title: nil,
                    message: "\(succeededIdentifiers.count) imported, \(failed) failed",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                    self?.confirmDeleteFromCameraRoll(identifiers: succeededIdentifiers)
                })
                viewController.present(alert, animated: true)
            } else {
                self?.confirmDeleteFromCameraRoll(identifiers: succeededIdentifiers)
            }
        }
    }

    func confirmDeleteFromCameraRoll(identifiers: [String]) {
        cameraRollDeleter.deleteAssets(withIdentifiers: identifiers)
    }
}

protocol CameraRollDeleting {
    func deleteAssets(withIdentifiers identifiers: [String])
}

struct PhotoLibraryCameraRollDeleter: CameraRollDeleting {
    func deleteAssets(withIdentifiers identifiers: [String]) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.firstObject != nil else { return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        })
    }
}
