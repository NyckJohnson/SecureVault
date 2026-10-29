//
//  FileSystem.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/17/26.
//
//  Legacy import and export, kept until the Import and Export modules replace them. Everything
//  else the old `FileSystem` did (indexes, browsing, file operations, trash, migration steps,
//  orphan sweep, temp files) is the VaultStore module's `VaultStoring`; this code reaches the
//  vault only through that contract.
//

import Foundation
import CryptoKit
import os
@preconcurrency import PhotosUI

// MARK: - FileSystem (legacy import and export)
nonisolated final class FileSystem: Sendable {
    private let store: any VaultStoring
    private let proUnlock: any ProUnlocking

    /// - Parameters:
    ///   - store: the app's one vault store (from the composition root).
    ///   - proUnlock: the "Unlock Pro" entitlement that lifts the free file limit.
    init(store: any VaultStoring, proUnlock: any ProUnlocking) {
        self.store = store
        self.proUnlock = proUnlock
    }

    // MARK: - Import

    /// Imports files and folders into `directory`, after checking the free file limit for all of them
    /// (all or nothing). Same name and same content as an existing item → skipped. Throws
    /// `ImportError.fileLimitReached`, or the first `VaultStoreError` (earlier files stay imported).
    @concurrent
    func importItems(
        from urls: [URL], to directory: VaultDirectory, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let total = Double(urls.reduce(0) { count, url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return count + (url.hasDirectoryPath ? Self.countFiles(in: url) : 1)
        })

        try await checkImportAllowed(additionalCount: Int(total))

        var completed = 0.0
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if url.hasDirectoryPath {
                try await importFolder(from: url, to: directory) {
                    completed += 1
                    if total > 0 { progress?(completed / total) }
                }
            } else {
                try await importSingleFile(from: url, to: directory)
                completed += 1
                if total > 0 { progress?(completed / total) }
            }
        }
    }

    /// Non-hidden files under the picked folder `url`, subfolders included.
    private static func countFiles(in url: URL) -> Int {
        var count = 0
        var queue = [url]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )) ?? []
            for item in contents {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    queue.append(item)
                } else {
                    count += 1
                }
            }
        }
        return count
    }

    private func importSingleFile(from url: URL, to directory: VaultDirectory) async throws {
        let originalName = url.lastPathComponent
        guard await !isDuplicate(sourceURL: url, originalName: originalName, in: directory) else { return }
        // The store encrypts and indexes in encrypted mode, and resolves name conflicts with " 1".
        _ = try await store.addFile(from: url, named: originalName, to: directory)
    }

    private func importFolder(
        from url: URL, to directory: VaultDirectory, onFileImported: (() -> Void)? = nil
    ) async throws {
        let name = url.lastPathComponent
        // An existing folder of the same name is merged into; anything else gets a free name.
        let subDirectory: VaultDirectory
        if let existing = try await store.findItem(named: name, in: directory), let folder = existing.asDirectory {
            subDirectory = folder
        } else {
            guard let created = try await store.createFolder(named: name, in: directory).asDirectory else {
                // Unreachable: createFolder always returns a folder.
                throw VaultStoreError.notFound
            }
            subDirectory = created
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )
        for item in contents {
            let accessing = item.startAccessingSecurityScopedResource()
            defer { if accessing { item.stopAccessingSecurityScopedResource() } }
            if item.hasDirectoryPath {
                try await importFolder(from: item, to: subDirectory, onFileImported: onFileImported)
            } else {
                try await importSingleFile(from: item, to: subDirectory)
                onFileImported?()
            }
        }
    }

    /// Call before starting an import; throws `ImportError.fileLimitReached` if adding
    /// `additionalCount` files would exceed the free tier for this vault.
    func checkImportAllowed(additionalCount: Int) async throws {
        guard !proUnlock.isUnlockedNow else { return }
        let existingCount = try await store.countFiles()
        guard existingCount + additionalCount <= ProUnlock.freeFileLimit else {
            throw ImportError.fileLimitReached(limit: ProUnlock.freeFileLimit)
        }
    }

    /// Imports picked photos and videos one at a time. `completion` gets the asset identifiers that
    /// were imported and the number that failed.
    func importFromCameraRoll(
        results: [PHPickerResult],
        to directory: VaultDirectory,
        completion: @escaping @MainActor @Sendable (_ succeededIdentifiers: [String], _ failed: Int) -> Void
    ) {
        let group = DispatchGroup()
        let state = OSAllocatedUnfairLock(initialState: (staged: [(url: URL, assetID: String?)](), failed: 0))
        let store = store

        for result in results {
            let provider = result.itemProvider
            let assetID = result.assetIdentifier
            guard let typeID = provider.registeredTypeIdentifiers.first else {
                state.withLock { $0.failed += 1 }
                continue
            }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                defer { group.leave() }
                // The url provided by loadFileRepresentation is only valid for the duration of
                // this callback. Copy it into a store temp folder before importing.
                guard let url, let folder = try? store.makeTempDirectory() else {
                    state.withLock { $0.failed += 1 }
                    return
                }
                let ext = url.pathExtension
                let stableURL = folder.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
                guard (try? FileManager.default.copyItem(at: url, to: stableURL)) != nil else {
                    store.removeTemporary(folder)
                    state.withLock { $0.failed += 1 }
                    return
                }
                state.withLock { $0.staged.append((url: stableURL, assetID: assetID)) }
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { [self] in
            let (staged, loadFailures) = state.withLock { ($0.staged, $0.failed) }
            Task.detached { [self] in
                var succeeded: [String] = []
                var failed = loadFailures
                for (url, assetID) in staged {
                    do {
                        try await importSingleFile(from: url, to: directory)
                        if let assetID { succeeded.append(assetID) }
                    } catch {
                        failed += 1
                    }
                    store.removeTemporary(url.deletingLastPathComponent())
                }
                await completion(succeeded, failed)
            }
        }
    }

    /// True when `directory` already holds an item named `originalName` with the same SHA-256 as the
    /// source. An encrypted item is decrypted to a store temp folder to hash it, removed afterwards.
    private func isDuplicate(sourceURL: URL, originalName: String, in directory: VaultDirectory) async -> Bool {
        guard let sourceHash = Self.sha256Hex(ofFileAt: sourceURL) else { return false }
        // Any lookup failure counts as "not a duplicate"; the add that follows reports the real error.
        guard let existing = try? await store.findItem(named: originalName, in: directory),
              !existing.isDirectory,
              let url = try? await store.open(existing) else {
            return false
        }
        defer { if existing.isEncrypted { store.removeTemporary(url.deletingLastPathComponent()) } }
        guard let existingHash = Self.sha256Hex(ofFileAt: url) else { return false }
        return sourceHash == existingHash
    }

    private static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024) // 1MB at a time
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
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
