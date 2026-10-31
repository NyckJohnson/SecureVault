//
//  FileSystem.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/17/26.
//
//  Legacy export, kept until the Export module replaces it. Import is the Import module's
//  `VaultImporting`; everything else the old `FileSystem` did (indexes, browsing, file operations,
//  trash, migration steps, orphan sweep, temp files) is the VaultStore module's `VaultStoring`; this
//  code reaches the vault only through that contract.
//

import Foundation
@preconcurrency import Photos

// MARK: - FileSystem (legacy export)
nonisolated final class FileSystem: Sendable {
    private let store: any VaultStoring

    /// - Parameter store: the app's one vault store (from the composition root).
    init(store: any VaultStoring) {
        self.store = store
    }

    // MARK: - Export

    /// The URLs to hand to the document picker for `items`, and the store temp folders made for them
    /// (remove each with `VaultStoring.removeTemporary` when the picker is done).
    struct ExportFiles: Sendable {
        let urls: [URL]
        let temporaryFolders: [URL]
    }

    /// Plaintext items → their disk URLs; encrypted files → decrypted copies with their original names;
    /// a folder holding encrypted items → a decrypted copy of its tree. Throws the first error.
    @concurrent
    func prepareForExport(_ items: [VaultItem], progress: (@Sendable (Double) -> Void)? = nil) async throws -> ExportFiles {
        let total = Double(items.count)
        var urls: [URL] = []
        var temporaryFolders: [URL] = []
        for (index, item) in items.enumerated() {
            defer { progress?(Double(index + 1) / total) }
            if item.isEncrypted {
                let url = try await store.open(item)
                urls.append(url)
                temporaryFolders.append(url.deletingLastPathComponent())
            } else if needsDecryptedCopy(item), let folder = item.asDirectory {
                // A folder in an encrypted vault holds UUID-named encrypted files and an index;
                // export a decrypted copy of the tree under the visible names instead.
                let tempFolder = try store.makeTempDirectory()
                let target = tempFolder.appendingPathComponent(item.name)
                do {
                    try await copyDecrypted(folder, to: target)
                } catch {
                    store.removeTemporary(tempFolder)
                    throw error
                }
                urls.append(target)
                temporaryFolders.append(tempFolder)
            } else {
                urls.append(item.diskURL)
            }
        }
        return ExportFiles(urls: urls, temporaryFolders: temporaryFolders)
    }

    /// True when exporting or sharing `item` must go through a decrypted copy: an encrypted file,
    /// or a folder with a folder index anywhere inside it. Plaintext files and folders (no lock)
    /// can be handed out as they are. Synchronous (the drag delegate asks it), so it looks for the
    /// on-disk index file directly, as the legacy app did; the Export module replaces it.
    func needsDecryptedCopy(_ item: VaultItem) -> Bool {
        if item.isEncrypted { return true }
        guard item.isDirectory else { return false }
        let indexName = ".vault_map"
        if FileManager.default.fileExists(atPath: item.diskURL.appendingPathComponent(indexName).path) { return true }
        guard let enumerator = FileManager.default.enumerator(at: item.diskURL, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let url as URL in enumerator where url.lastPathComponent == indexName {
            return true
        }
        return false
    }

    /// Writes `directory`'s files, decrypted, under their visible names into a new folder at
    /// `destination`, recursing into subfolders. No index or UUID names are copied.
    private func copyDecrypted(_ directory: VaultDirectory, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try await store.contents(of: directory, sortedBy: .name, .ascending) {
            let target = destination.appendingPathComponent(Self.freeName(for: child.name, in: destination))
            if let sub = child.asDirectory {
                try await copyDecrypted(sub, to: target)
            } else if child.isEncrypted {
                let opened = try await store.open(child)
                defer { store.removeTemporary(opened.deletingLastPathComponent()) }
                try FileManager.default.moveItem(at: opened, to: target)
            } else {
                try FileManager.default.copyItem(at: child.diskURL, to: target)
            }
        }
    }

    /// `name`, or `name` with " 1", " 2"… before the extension if `folder` already has it.
    private static func freeName(for name: String, in folder: URL) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = name
        var counter = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// Saves the images and videos among `items` to the photo library (add-only access).
    @concurrent
    func exportToCameraRoll(_ items: [VaultItem]) async -> (succeeded: Int, failed: Int) {
        let mediaItems = items.filter { $0.kind == .image || $0.kind == .video }
        guard !mediaItems.isEmpty else { return (0, 0) }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else { return (0, mediaItems.count) }

        var succeeded = 0
        for item in mediaItems {
            let isVideo = item.kind == .video
            do {
                let url = try await store.open(item)
                defer { if item.isEncrypted { store.removeTemporary(url.deletingLastPathComponent()) } }
                try await PHPhotoLibrary.shared().performChanges {
                    if isVideo {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    }
                }
                succeeded += 1
            } catch {
                continue
            }
        }
        return (succeeded, mediaItems.count - succeeded)
    }
}

extension Notification.Name {
    static let fileRestored = Notification.Name("FileRestored")
}
