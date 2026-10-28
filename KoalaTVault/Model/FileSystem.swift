//
//  FileSystem.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/17/26.
//

import Foundation
import CryptoKit
import CommonCrypto
import os
@preconcurrency import PhotosUI

// MARK: - LegacyVaultDirectory
nonisolated struct LegacyVaultDirectory: Sendable {
    var name: String
    internal var diskURL: URL
    internal var rootURL: URL

    static var root: LegacyVaultDirectory {
        let url = LegacyStorage.current.vaultRootURL
        return LegacyVaultDirectory(name: "KoalaTVault", diskURL: url, rootURL: url)
    }
}

// MARK: - LegacyVaultItem
nonisolated struct LegacyVaultItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var isDirectory: Bool
    var dateModified: Date
    var fileSize: Int?
    var deletedAt: Date?
    internal var diskURL: URL
    internal var rootURL: URL
    internal var isEncrypted: Bool

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: LegacyVaultItem, rhs: LegacyVaultItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - VaultMapping
struct VaultMapping: Codable {
    let originalName: String
}

// MARK: - FileSystemError
enum FileSystemError: Error, LocalizedError {
    case mappingUnreadable
    case fileLimitReached
    case invalidName
    case moveIntoItself
    case trashEntryInvalid

    var errorDescription: String? {
        switch self {
        case .mappingUnreadable:
            return "Couldn't read the vault's file index. It may still be locked, or a file may have become corrupted."
        case .fileLimitReached:
            return "You've reached the 100-file limit. Unlock more storage to continue importing."
        case .invalidName:
            return "Names can't contain /"
        case .moveIntoItself:
            return "A folder can't be moved into itself"
        case .trashEntryInvalid:
            return "This item can't be restored: its original location is outside the vault."
        }
    }
}

// MARK: - FileSystemAPI
nonisolated final class FileSystem: Sendable {
    static let shared = FileSystem()
    private init() {}

    // The master key store and cipher built once by the composition root (`AppDependencies`),
    // and the migration's checks of encrypted copies.
    private var keyStore: any MasterKeyStoring { LegacyStorage.current.masterKeyStore }
    private var cipher: any FileCipher { LegacyStorage.current.fileCipher }
    private var copyChecker: EncryptedCopyChecker { EncryptedCopyChecker(keyStore: keyStore, cipher: cipher) }

    private let mappingFileName = ".vault_map"
    private let tempDir = FileManager.default.temporaryDirectory

#if DEBUG
    nonisolated(unsafe) static var testForcedMigrationFailureFileName: String?
#endif

    // MARK: - Encryption state
    private var isEncryptionEnabled: Bool {
        keyStore.isKeyLoaded
    }

    // MARK: - Browse
    func contents(of directory: LegacyVaultDirectory) throws -> [LegacyVaultItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory.diskURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        )
        let mapping = try loadMapping(from: directory.diskURL)
        return urls.compactMap { url -> LegacyVaultItem? in
            let fileName = url.lastPathComponent
            guard fileName != mappingFileName else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            let isDirectory = values?.isDirectory ?? false
            let dateModified = values?.contentModificationDate ?? Date()
            let fileSize = values?.fileSize

            if let mapped = mapping[fileName] {
                // encrypted file
                return LegacyVaultItem(
                    id: UUID(),
                    name: mapped.originalName,
                    isDirectory: isDirectory,
                    dateModified: dateModified,
                    fileSize: fileSize,
                    diskURL: url,
                    rootURL: directory.rootURL,
                    isEncrypted: true
                )
            } else {
                // unencrypted file or directory
                return LegacyVaultItem(
                    id: UUID(),
                    name: fileName,
                    isDirectory: isDirectory,
                    dateModified: dateModified,
                    fileSize: fileSize,
                    diskURL: url,
                    rootURL: directory.rootURL,
                    isEncrypted: false
                )
            }
        }.sorted(by: sortComparator)
    }

    // MARK: - Import
    func importItems(from urls: [URL], to directory: LegacyVaultDirectory, progress: ((Double) -> Void)? = nil) throws {
        let total = Double(urls.reduce(0) { count, url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return count + (url.hasDirectoryPath ? countFiles(in: url) : 1)
        })

        if !LegacyStorage.current.proUnlock.isUnlockedNow {
            let existingCount = countFiles(in: directory.rootURL)
            guard existingCount + Int(total) <= ProUnlock.freeFileLimit else {
                throw FileSystemError.fileLimitReached
            }
        }

        var completed = 0.0
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if url.hasDirectoryPath {
                try importFolder(from: url, to: directory) {
                    completed += 1
                    if total > 0 { progress?(completed / total) }
                }
            } else {
                try autoreleasepool {
                    try importSingleFile(from: url, to: directory)
                }
                completed += 1
                if total > 0 { progress?(completed / total) }
            }
        }
    }

    private func countFiles(in url: URL) -> Int {
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

    private func importSingleFile(from url: URL, to directory: LegacyVaultDirectory) throws {
        let originalName = url.lastPathComponent
        guard !isDuplicate(sourceURL: url, originalName: originalName, in: directory.diskURL) else { return }
        
        if isEncryptionEnabled {
            // resolve conflicts against existing mapped names
            let existingNames = try loadMapping(from: directory.diskURL).values.map { $0.originalName }
            let name = resolvedNameInMapping(for: originalName, existingNames: existingNames)
            let uuid = UUID().uuidString
            let destination = directory.diskURL.appendingPathComponent(uuid)
            try cipher.encryptFile(at: url, to: destination)
            var mapping = try loadMapping(from: directory.diskURL)
            mapping[uuid] = VaultMapping(originalName: name)
            try saveMapping(mapping, to: directory.diskURL)
        } else {
            let name = resolvedName(for: originalName, in: directory.diskURL)
            let destination = directory.diskURL.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: destination)
        }
    }

    private func importFolder(from url: URL, to directory: LegacyVaultDirectory, onFileImported: (() -> Void)? = nil) throws {
        let existingURL = directory.diskURL.appendingPathComponent(url.lastPathComponent)
        var isDir: ObjCBool = false
        let folderExists = FileManager.default.fileExists(atPath: existingURL.path, isDirectory: &isDir) && isDir.boolValue
        let folderName = folderExists ? url.lastPathComponent : resolvedName(for: url.lastPathComponent, in: directory.diskURL)
        let destination = directory.diskURL.appendingPathComponent(folderName)
        if !folderExists {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let subDirectory = LegacyVaultDirectory(name: folderName, diskURL: destination, rootURL: directory.rootURL)

        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )
        for item in contents {
            try autoreleasepool {
                let accessing = item.startAccessingSecurityScopedResource()
                defer { if accessing { item.stopAccessingSecurityScopedResource() } }
                if item.hasDirectoryPath {
                    try importFolder(from: item, to: subDirectory, onFileImported: onFileImported)
                } else {
                    try importSingleFile(from: item, to: subDirectory)
                    onFileImported?()
                }
            }
        }
    }

    /// Call before starting a camera-roll import; throws `.fileLimitReached` if the
    /// import would exceed the free tier for this vault.
    func checkImportAllowed(additionalCount: Int, in directory: LegacyVaultDirectory) throws {
        guard !LegacyStorage.current.proUnlock.isUnlockedNow else { return }
        let existingCount = countFiles(in: directory.rootURL)
        guard existingCount + additionalCount <= ProUnlock.freeFileLimit else {
            throw FileSystemError.fileLimitReached
        }
    }

    func importFromCameraRoll(
        results: [PHPickerResult],
        to directory: LegacyVaultDirectory,
        completion: @escaping @MainActor @Sendable (_ succeededIdentifiers: [String], _ failed: Int) -> Void
    ) {
        let group = DispatchGroup()
        let state = OSAllocatedUnfairLock(initialState: (succeeded: [String](), failed: 0))
        // Serial queue so concurrent loadFileRepresentation callbacks don't race on the mapping file.
        let importQueue = DispatchQueue(label: "com.KoalaTVault.cameraRollImport", qos: .userInitiated)

        for result in results {
            let provider = result.itemProvider
            let assetID = result.assetIdentifier
            guard let typeID = provider.registeredTypeIdentifiers.first else {
                state.withLock { $0.failed += 1 }
                continue
            }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, _ in
                guard let self, let url else {
                    state.withLock { $0.failed += 1 }
                    group.leave()
                    return
                }
                // The url provided by loadFileRepresentation is only valid for the duration of
                // this callback. Copy it to a stable temp location before dispatching.
                let ext = url.pathExtension
                let stableURL = self.tempDir.appendingPathComponent(
                    UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
                )
                guard (try? FileManager.default.copyItem(at: url, to: stableURL)) != nil else {
                    state.withLock { $0.failed += 1 }
                    group.leave()
                    return
                }
                importQueue.async {
                    defer {
                        try? FileManager.default.removeItem(at: stableURL)
                        group.leave()
                    }
                    do {
                        try self.importSingleFile(from: stableURL, to: directory)
                        if let assetID { state.withLock { $0.succeeded.append(assetID) } }
                    } catch {
                        state.withLock { $0.failed += 1 }
                    }
                }
            }
        }
        group.notify(queue: .main) {
            let final = state.withLock { $0 }
            MainActor.assumeIsolated {
                completion(final.succeeded, final.failed)
            }
        }
    }

    private func isDuplicate(sourceURL: URL, originalName: String, in directory: URL) -> Bool {
        guard let sourceHash = sha256Hex(ofFileAt: sourceURL) else { return false }

        if isEncryptionEnabled {
            let mapping = (try? loadMapping(from: directory)) ?? [:]
            guard let existingUUID = mapping.first(where: { $0.value.originalName == originalName })?.key else {
                return false
            }
            // decryptFile writes to a temp location so we can stream-hash it too
            let tempURL = tempDir.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            guard (try? cipher.decryptFile(at: directory.appendingPathComponent(existingUUID), to: tempURL)) != nil,
                  let existingHash = sha256Hex(ofFileAt: tempURL) else {
                return false
            }
            return sourceHash == existingHash
        } else {
            let existingURL = directory.appendingPathComponent(originalName)
            guard FileManager.default.fileExists(atPath: existingURL.path),
                  let existingHash = sha256Hex(ofFileAt: existingURL) else {
                return false
            }
            return sourceHash == existingHash
        }
    }

    private func sha256Hex(ofFileAt url: URL) -> String? {
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

    // MARK: - Open
    func open(_ item: LegacyVaultItem) throws -> URL {
        guard item.isEncrypted else { return item.diskURL }
        let tempSubDir = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempSubDir, withIntermediateDirectories: true)
        let tempURL = tempSubDir.appendingPathComponent(item.name)
        try cipher.decryptFile(at: item.diskURL, to: tempURL)
        return tempURL
    }

    // MARK: - Write
    func write(data: Data, to item: LegacyVaultItem) throws {
        if item.isEncrypted {
            let tempPlain = tempDir.appendingPathComponent(UUID().uuidString)
            try data.write(to: tempPlain)
            defer { try? FileManager.default.removeItem(at: tempPlain) }

            let tempEncrypted = tempDir.appendingPathComponent(UUID().uuidString)
            try cipher.encryptFile(at: tempPlain, to: tempEncrypted)
            defer { try? FileManager.default.removeItem(at: tempEncrypted) }

            _ = try FileManager.default.replaceItemAt(item.diskURL, withItemAt: tempEncrypted)
        } else {
            try data.write(to: item.diskURL)
        }
    }

    // MARK: - Export
    func prepareForExport(_ items: [LegacyVaultItem], progress: ((Double) -> Void)? = nil) throws -> [URL] {
        let total = Double(items.count)
        return try items.enumerated().map { index, item in
            defer { progress?(Double(index + 1) / total) }
            if item.isEncrypted {
                let tempSubDir = tempDir.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempSubDir, withIntermediateDirectories: true)
                let tempURL = tempSubDir.appendingPathComponent(item.name)
                try cipher.decryptFile(at: item.diskURL, to: tempURL)
                return tempURL
            }
            if needsDecryptedCopy(item) {
                // A folder in an encrypted vault holds UUID-named SVC5 files and a `.vault_map`;
                // export a decrypted copy of the tree under the visible names instead.
                let tempSubDir = tempDir.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempSubDir, withIntermediateDirectories: true)
                let tempURL = tempSubDir.appendingPathComponent(item.name)
                do {
                    let folder = LegacyVaultDirectory(name: item.name, diskURL: item.diskURL, rootURL: item.rootURL)
                    try copyDecrypted(folder, to: tempURL)
                } catch {
                    try? FileManager.default.removeItem(at: tempSubDir)
                    throw error
                }
                return tempURL
            }
            return item.diskURL
        }
    }

    /// True when exporting or sharing `item` must go through a decrypted copy: an encrypted file,
    /// or a folder with a `.vault_map` anywhere inside it. Plaintext files and folders (no lock)
    /// can be handed out as they are.
    func needsDecryptedCopy(_ item: LegacyVaultItem) -> Bool {
        if item.isEncrypted { return true }
        guard item.isDirectory else { return false }
        if FileManager.default.fileExists(atPath: item.diskURL.appendingPathComponent(mappingFileName).path) { return true }
        guard let enumerator = FileManager.default.enumerator(at: item.diskURL, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in enumerator where url.lastPathComponent == mappingFileName {
            return true
        }
        return false
    }

    /// Writes `directory`'s files, decrypted, under their visible names into a new folder at
    /// `destination`, recursing into subfolders. No `.vault_map` or UUID names are copied.
    private func copyDecrypted(_ directory: LegacyVaultDirectory, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try contents(of: directory) {
            let target = destination.appendingPathComponent(resolvedName(for: child.name, in: destination))
            if child.isDirectory {
                let sub = LegacyVaultDirectory(name: child.name, diskURL: child.diskURL, rootURL: child.rootURL)
                try copyDecrypted(sub, to: target)
            } else if child.isEncrypted {
                try cipher.decryptFile(at: child.diskURL, to: target)
            } else {
                try FileManager.default.copyItem(at: child.diskURL, to: target)
            }
        }
    }

    @concurrent
    func exportToCameraRoll(_ items: [LegacyVaultItem]) async -> (succeeded: Int, failed: Int) {
        let mediaItems = items.filter {
            let kind = LegacyFileKind(extension: ($0.name as NSString).pathExtension.lowercased())
            return kind == .image || kind == .video
        }
        guard !mediaItems.isEmpty else { return (0, 0) }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else { return (0, mediaItems.count) }

        var succeeded = 0
        for item in mediaItems {
            let isVideo = LegacyFileKind(extension: (item.name as NSString).pathExtension.lowercased()) == .video
            do {
                let url = try open(item)
                defer { if item.isEncrypted { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
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

    // MARK: - Manage
    func createFolder(named name: String, in directory: LegacyVaultDirectory) throws -> LegacyVaultDirectory {
        guard !name.contains("/") else { throw FileSystemError.invalidName }
        let folderName = resolvedName(for: name, in: directory.diskURL)
        let url = directory.diskURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return LegacyVaultDirectory(name: folderName, diskURL: url, rootURL: directory.rootURL)
    }

    /// Creates an empty rich-text document `<name>.rtf` in `directory` and returns it.
    /// A taken name gets the " N" suffix; an existing document is never overwritten.
    /// With a lock on, the file is an empty SVC5 file under a UUID with a `.vault_map` entry.
    func createDocument(named name: String, in directory: LegacyVaultDirectory) throws -> LegacyVaultItem {
        guard !name.contains("/") else { throw FileSystemError.invalidName }
        let fileName = name.hasSuffix(".rtf") ? name : "\(name).rtf"
        if isEncryptionEnabled {
            var mapping = try loadMapping(from: directory.diskURL)
            let resolved = resolvedNameInMapping(for: fileName, existingNames: mapping.values.map { $0.originalName })
            let uuid = UUID().uuidString
            let destination = directory.diskURL.appendingPathComponent(uuid)
            let tempPlain = tempDir.appendingPathComponent(UUID().uuidString)
            try Data().write(to: tempPlain)
            defer { try? FileManager.default.removeItem(at: tempPlain) }
            try cipher.encryptFile(at: tempPlain, to: destination)  // file first
            mapping[uuid] = VaultMapping(originalName: resolved)
            do {
                try saveMapping(mapping, to: directory.diskURL)                    // then the index
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return LegacyVaultItem(id: UUID(), name: resolved, isDirectory: false, dateModified: Date(), fileSize: 0,
                             diskURL: destination, rootURL: directory.rootURL, isEncrypted: true)
        } else {
            let resolved = resolvedName(for: fileName, in: directory.diskURL)
            let destination = directory.diskURL.appendingPathComponent(resolved)
            try Data().write(to: destination, options: .withoutOverwriting)
            return LegacyVaultItem(id: UUID(), name: resolved, isDirectory: false, dateModified: Date(), fileSize: 0,
                             diskURL: destination, rootURL: directory.rootURL, isEncrypted: false)
        }
    }

    func move(_ item: LegacyVaultItem, to directory: LegacyVaultDirectory) throws {
        // Moving into the folder the item is already in changes nothing.
        let sourceDir = item.diskURL.deletingLastPathComponent()
        if sourceDir.standardizedFileURL.resolvingSymlinksInPath().path
            == directory.diskURL.standardizedFileURL.resolvingSymlinksInPath().path {
            return
        }
        // A folder can't be moved into itself or one of its own subfolders.
        if item.isDirectory {
            let itemPath = item.diskURL.standardizedFileURL.resolvingSymlinksInPath().path
            let destPath = directory.diskURL.standardizedFileURL.resolvingSymlinksInPath().path
            if destPath == itemPath || destPath.hasPrefix(itemPath + "/") {
                throw FileSystemError.moveIntoItself
            }
        }
        let name = resolvedName(for: item.diskURL.lastPathComponent, in: directory.diskURL)
        let destination = directory.diskURL.appendingPathComponent(name)
        if item.isEncrypted {
            var sourceMapping = try loadMapping(from: sourceDir)
            var destMapping = try loadMapping(from: directory.diskURL)
            let uuid = item.diskURL.lastPathComponent
            // Without a source entry (index changed since listing) keep the listed name,
            // so the moved file is never left unmapped for the orphan sweep.
            let originalName = sourceMapping[uuid]?.originalName ?? item.name
            let existingNames = destMapping.values.map { $0.originalName }
            let resolvedOriginalName = resolvedNameInMapping(for: originalName, existingNames: existingNames)
            destMapping[uuid] = VaultMapping(originalName: resolvedOriginalName)
            try saveMapping(destMapping, to: directory.diskURL)              // dest mapping first
            try FileManager.default.moveItem(at: item.diskURL, to: destination) // then move
            sourceMapping.removeValue(forKey: uuid)
            try saveMapping(sourceMapping, to: sourceDir)                    // source mapping last
        } else {
            try FileManager.default.moveItem(at: item.diskURL, to: destination)
        }
    }

    func copy(_ item: LegacyVaultItem, to directory: LegacyVaultDirectory) throws {
        if item.isEncrypted {
            let newUUID = UUID().uuidString
            let destination = directory.diskURL.appendingPathComponent(newUUID)
            try FileManager.default.copyItem(at: item.diskURL, to: destination)
            var mapping = try loadMapping(from: directory.diskURL)
            let existingNames = mapping.values.map { $0.originalName }
            let resolvedName = resolvedNameInMapping(for: item.name, existingNames: existingNames)
            mapping[newUUID] = VaultMapping(originalName: resolvedName)
            try saveMapping(mapping, to: directory.diskURL)
        } else {
            let name = resolvedName(for: item.name, in: directory.diskURL)
            let destination = directory.diskURL.appendingPathComponent(name)
            try FileManager.default.copyItem(at: item.diskURL, to: destination)
        }
    }

    func rename(_ item: LegacyVaultItem, to name: String) throws {
        guard !name.contains("/") else { throw FileSystemError.invalidName }
        if item.isEncrypted {
            let uuid = item.diskURL.lastPathComponent
            let dir = item.diskURL.deletingLastPathComponent()
            var mapping = try loadMapping(from: dir)
            let existingNames = mapping.filter { $0.key != uuid }.values.map { $0.originalName }
            let resolvedName = resolvedNameInMapping(for: name, existingNames: existingNames)
            mapping[uuid] = VaultMapping(originalName: resolvedName)
            try saveMapping(mapping, to: dir)
        } else {
            let destination = item.diskURL.deletingLastPathComponent().appendingPathComponent(name)
            try FileManager.default.moveItem(at: item.diskURL, to: destination)
        }
    }

    func delete(_ item: LegacyVaultItem) throws {
        try moveToTrash(item)
    }
    
    private func resolvedNameInMapping(for name: String, existingNames: [String]) -> String {
        resolvedName(for: name) { existingNames.contains($0) }
    }
    
    // MARK: - Trash
    private let trashFolderName = ".trash"
    private let trashMapName = ".trash_map"

    struct TrashEntry: Codable {
        let originalDiskName: String
        let originalDirectoryURL: String
        let deletedAt: Date
        let isEncrypted: Bool
        let originalName: String
        let rootURL: String
    }

    func trashDirectory(for rootURL: URL) -> LegacyVaultDirectory {
        let url = rootURL.appendingPathComponent(trashFolderName)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return LegacyVaultDirectory(name: "Recently Deleted", diskURL: url, rootURL: rootURL)
    }

    func moveToTrash(_ item: LegacyVaultItem) throws {
        let trashURL = trashDirectory(for: item.rootURL).diskURL
        let uuid = UUID().uuidString
        let destination = trashURL.appendingPathComponent(uuid)

        // Entry first, then move: a file in .trash is never unmapped (emptyTrash would sweep it).
        // If the map can't be read or saved, nothing has moved and the error propagates.
        var trashMap = try loadTrashMap(for: item.rootURL)
        trashMap[uuid] = TrashEntry(
            originalDiskName: item.diskURL.lastPathComponent,
            originalDirectoryURL: item.diskURL.deletingLastPathComponent().path,
            deletedAt: Date(),
            isEncrypted: item.isEncrypted,
            originalName: item.name,
            rootURL: item.rootURL.path
        )
        try saveTrashMap(trashMap, for: item.rootURL)

        do {
            try FileManager.default.moveItem(at: item.diskURL, to: destination)
        } catch {
            // Drop the entry again. Best-effort is safe here: an entry whose file is missing
            // is never listed (contentsOfTrash skips it) and the item is still in place.
            trashMap.removeValue(forKey: uuid)
            try? saveTrashMap(trashMap, for: item.rootURL)
            throw error
        }

        if item.isEncrypted {                                                            // source mapping last
            let sourceDir = item.diskURL.deletingLastPathComponent()
            var sourceMapping = try loadMapping(from: sourceDir)
            sourceMapping.removeValue(forKey: item.diskURL.lastPathComponent)
            try saveMapping(sourceMapping, to: sourceDir)
        }
    }

    func restoreFromTrash(_ item: LegacyVaultItem) throws {
        var trashMap    = try loadTrashMap(for: item.rootURL)
        let uuid        = item.diskURL.lastPathComponent
        guard let entry = trashMap[uuid] else { return }

        let originalDir = URL(fileURLWithPath: entry.originalDirectoryURL)
        try validateRestoreTarget(entry, directory: originalDir, rootURL: item.rootURL)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)

        // An item with the same name may have appeared since deletion: restore as "name 1" etc.
        let diskName    = resolvedName(for: entry.originalDiskName, in: originalDir)
        let destination = originalDir.appendingPathComponent(diskName)
        try FileManager.default.moveItem(at: item.diskURL, to: destination)

        if entry.isEncrypted {
            var mapping = try loadMapping(from: originalDir)
            let existingNames = mapping.values.map { $0.originalName }
            let name = resolvedNameInMapping(for: entry.originalName, existingNames: existingNames)
            mapping[diskName] = VaultMapping(originalName: name)
            try saveMapping(mapping, to: originalDir)
        }

        trashMap.removeValue(forKey: uuid)
        try saveTrashMap(trashMap, for: item.rootURL)
    }

    /// A trash map can come from disk unauthenticated (legacy plaintext), so its paths are
    /// untrusted: the disk name must be a single component and the folder must resolve
    /// (standardized, symlinks resolved) to the vault root or somewhere inside it.
    private func validateRestoreTarget(_ entry: TrashEntry, directory: URL, rootURL: URL) throws {
        let name = entry.originalDiskName
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw FileSystemError.trashEntryInvalid
        }
        let rootParts = rootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let dirParts  = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard dirParts.count >= rootParts.count,
              Array(dirParts.prefix(rootParts.count)) == rootParts,
              !dirParts.dropFirst(rootParts.count).contains("..") else {
            throw FileSystemError.trashEntryInvalid
        }
    }

    func contentsOfTrash(for root: LegacyVaultDirectory) throws -> [LegacyVaultItem] {
        let trashMap = try loadTrashMap(for: root.rootURL)
        let trashURL = trashDirectory(for: root.rootURL).diskURL
        return trashMap.compactMap { uuid, entry in
            let diskURL = trashURL.appendingPathComponent(uuid)
            guard FileManager.default.fileExists(atPath: diskURL.path) else { return nil }
            return LegacyVaultItem(
                id: UUID(),
                name: entry.originalName,
                isDirectory: false,
                dateModified: entry.deletedAt,
                fileSize: nil,
                deletedAt: entry.deletedAt,
                diskURL: diskURL,
                rootURL: root.rootURL,
                isEncrypted: entry.isEncrypted
            )
        }.sorted { $0.dateModified > $1.dateModified }
    }

    func permanentlyDelete(_ item: LegacyVaultItem) throws {
        var trashMap          = try loadTrashMap(for: item.rootURL)
        let uuid              = item.diskURL.lastPathComponent
        guard trashMap[uuid] != nil else { return }

        try FileManager.default.removeItem(at: item.diskURL)
        trashMap.removeValue(forKey: uuid)

        try saveTrashMap(trashMap, for: item.rootURL)
    }

    func emptyTrash(for root: LegacyVaultDirectory) throws {
        // Deliberately best-effort: emptying the trash must always succeed at wiping
        // everything, even if the existing map can't be decrypted (stale/mismatched key,
        // corruption, etc.) — otherwise one unreadable map permanently wedges the trash
        // folder, since nothing can ever successfully read-then-clear it again.
        let items = (try? contentsOfTrash(for: root)) ?? []
        for item in items {
            try? FileManager.default.removeItem(at: item.diskURL)
        }
        let trashURL = trashDirectory(for: root.rootURL).diskURL
        // Also sweep any files a corrupted/unreadable map couldn't tell us about, so
        // nothing is ever left permanently orphaned in the trash folder.
        if let remaining = try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil) {
            for url in remaining where url.lastPathComponent != trashMapName {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let mapURL = trashURL.appendingPathComponent(trashMapName)
        try? FileManager.default.removeItem(at: mapURL)
    }

    func cleanupExpiredTrashItems(for root: LegacyVaultDirectory) {
        // An unreadable map is logged and we return before saveTrashMap — so a failed
        // read here can never overwrite good data with an empty one.
        var trashMap: [String: TrashEntry]
        do {
            trashMap = try loadTrashMap(for: root.rootURL)
        } catch {
            print("Trash purge skipped: trash map unreadable (\(error))")
            return
        }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60) // 30 days
        var changed = false
        let trashURL = trashDirectory(for: root.rootURL).diskURL
        for (uuid, entry) in trashMap where entry.deletedAt < cutoff {
            let diskURL = trashURL.appendingPathComponent(uuid)
            try? FileManager.default.removeItem(at: diskURL)
            trashMap.removeValue(forKey: uuid)
            changed = true
        }
        guard changed else { return }
        do {
            try saveTrashMap(trashMap, for: root.rootURL)
        } catch {
            print("Trash purge: saving the trash map failed (\(error))")
        }
    }

    private func loadTrashMap(for rootURL: URL) throws -> [String: TrashEntry] {
        let trashMapURL = trashDirectory(for: rootURL).diskURL.appendingPathComponent(trashMapName)
        do {
            return try loadEncryptedJSON([String: TrashEntry].self, from: trashMapURL) ?? [:]
        } catch FileSystemError.mappingUnreadable where keyStore.isKeyLoaded {
            // Every decrypt attempt failed. A map written before a lock was added is plaintext
            // JSON; accept it only if it parses as the trash map. The next save encrypts it.
            guard let data = try? Data(contentsOf: trashMapURL),
                  let plaintext = try? JSONDecoder().decode([String: TrashEntry].self, from: data) else {
                throw FileSystemError.mappingUnreadable
            }
            return plaintext
        }
    }

    private func saveTrashMap(_ map: [String: TrashEntry], for rootURL: URL) throws {
        try saveEncryptedJSON(map, to: trashDirectory(for: rootURL).diskURL.appendingPathComponent(trashMapName))
    }

    // MARK: - Migration
    func filesToMigrate(toEncrypted: Bool, in directory: LegacyVaultDirectory) throws -> [(item: LegacyVaultItem, directory: LegacyVaultDirectory)] {
        let items = try contents(of: directory)
        let files = items.filter { !$0.isDirectory && $0.isEncrypted != toEncrypted }
        var result = files.map { (item: $0, directory: directory) }

        let subdirs = items.filter { $0.isDirectory }
        for subdir in subdirs {
            let subVaultDir = LegacyVaultDirectory(name: subdir.name, diskURL: subdir.diskURL, rootURL: directory.rootURL)
            result += try filesToMigrate(toEncrypted: toEncrypted, in: subVaultDir)
        }
        return result
    }
    
    /// Encrypts one plaintext file; safe to interrupt at any instant (the plaintext, or a verified
    /// copy plus its index entry, always exists). Copy written and verified → entry saved encrypted
    /// (never plaintext) and read back → copy re-verified → plaintext removed. A rerun drops entries
    /// without files, removes a plaintext whose same-name copy matches byte for byte, and otherwise
    /// keeps both (free name). Throws `VaultCryptoError.noKeyLoaded` without the key, or the I/O error.
    func migrateFileToEncrypted(_ item: LegacyVaultItem, in directory: LegacyVaultDirectory) throws {
        try throwIfFailureInjected(for: item.name)
        guard keyStore.isKeyLoaded else { throw VaultCryptoError.noKeyLoaded }
        let fileManager = FileManager.default
        // Removed only by an earlier run, after its copy and entry were verified.
        guard fileManager.fileExists(atPath: item.diskURL.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: item.diskURL.path)
        guard let sourceSize = attributes[.size] as? Int else { throw CocoaError(.fileReadUnknown) }
        var mapping = try loadMapping(from: directory.diskURL)
        var nameTaken = false
        for (uuid, entry) in mapping where entry.originalName == item.name {
            let copyURL = directory.diskURL.appendingPathComponent(uuid)
            // An entry without its file points at nothing.
            guard fileManager.fileExists(atPath: copyURL.path) else { mapping.removeValue(forKey: uuid); continue }
            // An exact match means an earlier run stopped just before removing the plaintext.
            if copyChecker.isCompleteEncryptedCopy(at: copyURL, plaintextSize: sourceSize),
               try copyChecker.encryptedFile(at: copyURL, hasSameContentAs: item.diskURL) {
                try fileManager.removeItem(at: item.diskURL)
                return
            }
            nameTaken = true
        }
        let name = nameTaken
            ? resolvedNameInMapping(for: item.name, existingNames: mapping.values.map { $0.originalName })
            : item.name
        let uuid = UUID().uuidString
        let destination = directory.diskURL.appendingPathComponent(uuid)
        try cipher.encryptFile(at: item.diskURL, to: destination)
        do {
            guard copyChecker.isCompleteEncryptedCopy(at: destination, plaintextSize: sourceSize) else {
                throw keyStore.isKeyLoaded ? VaultCryptoError.encryptionFailed : VaultCryptoError.noKeyLoaded
            }
            mapping[uuid] = VaultMapping(originalName: name)
            try saveMappingRequiringKey(mapping, to: directory.diskURL)
        } catch {
            // Source untouched; drop the unindexed copy (else the orphan sweep removes it).
            try? fileManager.removeItem(at: destination)
            throw error
        }
        // The entry must be on disk before the plaintext goes (if this throws, the source stays).
        var saved = try loadMapping(from: directory.diskURL)
        guard saved[uuid]?.originalName == name else { throw FileSystemError.mappingUnreadable }
        // Re-check the copy right before deleting the plaintext: it must still exist, complete.
        guard copyChecker.isCompleteEncryptedCopy(at: destination, plaintextSize: sourceSize) else {
            guard keyStore.isKeyLoaded else { throw VaultCryptoError.noKeyLoaded }
            // Keep the plaintext; drop the bad entry (best effort: a rerun drops or re-checks it).
            saved.removeValue(forKey: uuid)
            try? saveMappingRequiringKey(saved, to: directory.diskURL)
            throw VaultCryptoError.encryptionFailed
        }
        try fileManager.removeItem(at: item.diskURL)
    }

    /// Decrypts every encrypted file left in `directory` and its subfolders, then deletes each
    /// folder's `.vault_map`, so the vault lists with no key afterwards. Run with the key loaded
    /// as the last step of a decrypt migration, before the key is removed.
    /// A file that fails to decrypt throws and leaves its folder's index (and the indexes of the
    /// folders not yet visited) in place, so nothing is left unreadable while the key is kept.
    /// The hidden `.trash` folder is not visited.
    func migrateVaultToDecrypted(in directory: LegacyVaultDirectory, progress: @escaping (Double) -> Void) throws {
        let items   = try contents(of: directory).filter { !$0.isDirectory && $0.isEncrypted }
        let total   = Double(items.count)

        for (index, item) in items.enumerated() {
            try migrateFileToDecrypted(item, in: directory)
            if total > 0 { progress(Double(index + 1) / total) }
        }

        // Every mapped file is now plaintext; any entries left point at missing files.
        let mapURL = directory.diskURL.appendingPathComponent(mappingFileName)
        do {
            try FileManager.default.removeItem(at: mapURL)
        } catch CocoaError.fileNoSuchFile {
            // Already gone (no index here, or removed by an earlier run): nothing to do.
        }

        // Throws rather than skipping: an unvisited subfolder would keep an index the key
        // removal then makes unreadable.
        let subdirs = try FileManager.default.contentsOfDirectory(
            at: directory.diskURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for subdir in subdirs {
            let subVaultDir = LegacyVaultDirectory(name: subdir.lastPathComponent, diskURL: subdir, rootURL: directory.rootURL)
            try migrateVaultToDecrypted(in: subVaultDir, progress: progress)
        }
    }
    
    func migrateFileToDecrypted(_ item: LegacyVaultItem, in directory: LegacyVaultDirectory) throws {
        try throwIfFailureInjected(for: item.name)
        let encryptedURL = item.diskURL
        // Removed only after its decrypted copy was committed by an earlier run.
        guard FileManager.default.fileExists(atPath: encryptedURL.path) else { return }
        // Rerun after the decrypted copy was written: a byte-identical plaintext means done.
        let sameNameURL = directory.diskURL.appendingPathComponent(item.name)
        if FileManager.default.fileExists(atPath: sameNameURL.path),
           let plainSize = try FileManager.default.attributesOfItem(atPath: sameNameURL.path)[.size] as? Int,
           copyChecker.isCompleteEncryptedCopy(at: encryptedURL, plaintextSize: plainSize),
           try copyChecker.encryptedFile(at: encryptedURL, hasSameContentAs: sameNameURL) {
            try removeDecryptedSource(encryptedURL, in: directory)
            return
        }
        let name = resolvedName(for: item.name, in: directory.diskURL)
        let decryptedURL = directory.diskURL.appendingPathComponent(name)
        try cipher.decryptFile(at: encryptedURL, to: decryptedURL)
        try removeDecryptedSource(encryptedURL, in: directory)
    }

    /// Test hooks: `UITEST_FAIL_MIGRATION_FILE` (-uiTesting) and, in DEBUG, the unit-test name.
    private func throwIfFailureInjected(for name: String) throws {
        var injected = LegacyStorage.current.uiTestSettings?.failMigrationFileName == name
#if DEBUG
        injected = injected || FileSystem.testForcedMigrationFailureFileName == name
#endif
        if injected { throw VaultCryptoError.encryptionFailed }
    }

    /// Removes an encrypted file whose plaintext is in place, then its index entry.
    private func removeDecryptedSource(_ encryptedURL: URL, in directory: LegacyVaultDirectory) throws {
        try FileManager.default.removeItem(at: encryptedURL)
        var mapping = try loadMapping(from: directory.diskURL)
        mapping.removeValue(forKey: encryptedURL.lastPathComponent)   // a stale entry lists nothing
        try saveMappingRequiringKey(mapping, to: directory.diskURL)
    }

    // MARK: - Cleanup
    func cleanupTempFiles() {
        let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        files?.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Removes UUID-named encrypted files that have no mapping entry — orphans left by a
    /// process kill between `encryptFile` and `saveMapping`. Best-effort; runs after unlock.
    /// Only runs with the key loaded, and only deletes in folders that have a readable
    /// `.vault_map`: a folder with no index holds plaintext files, which are never orphans.
    func sweepOrphanedEncryptedFiles(in directory: LegacyVaultDirectory) {
        guard isEncryptionEnabled else { return }
        // A migration in progress has copies not indexed yet; sweep after it finishes instead.
        guard LegacyStorage.current.preferences.pendingMigration == nil else { return }
        guard let diskFiles = try? FileManager.default.contentsOfDirectory(
            at: directory.diskURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles) else { return }
        // No index in this folder: nothing here is an encrypted orphan, but subfolders may
        // have their own index, so still recurse. If the index exists but can't be read
        // (corrupted), bail without deleting anything — we can't tell orphans from live files.
        let hasMapping = FileManager.default.fileExists(
            atPath: directory.diskURL.appendingPathComponent(mappingFileName).path)
        let mapping: [String: VaultMapping]?
        if hasMapping {
            guard let loaded = try? loadMapping(from: directory.diskURL) else { return }
            mapping = loaded
        } else {
            mapping = nil
        }
        let uuidPattern = #"^[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}$"#
        for url in diskFiles {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let sub = LegacyVaultDirectory(name: name, diskURL: url, rootURL: directory.rootURL)
                sweepOrphanedEncryptedFiles(in: sub)
            } else if let mapping,
                      name.range(of: uuidPattern, options: [.regularExpression, .caseInsensitive]) != nil,
                      mapping[name] == nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    
    #if DEBUG
    func diagnoseDiskState() {
        let root = LegacyVaultDirectory.root.diskURL
        let mapping: [String: VaultMapping]
        do {
            mapping = try loadMapping(from: root)
        } catch {
            print("Mapping unreadable: \(error.localizedDescription)")
            return
        }
        let diskFiles = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        
        print("Mapping entries: \(mapping.count)")
        print("Disk files: \(diskFiles.count)")
        
        // find orphaned files (on disk but not in mapping)
        let mappedUUIDs = Set(mapping.keys)
        let orphaned = diskFiles.filter { url in
            let name = url.lastPathComponent
            let isUUID = name.count == 36 && name.contains("-")
            return isUUID && !mappedUUIDs.contains(name)
        }
        print("Orphaned files: \(orphaned.count)")
        
        // find orphaned mapping entries (in mapping but not on disk)
        let diskFileNames = Set(diskFiles.map { $0.lastPathComponent })
        let orphanedMappings = mapping.filter { !diskFileNames.contains($0.key) }
        print("Orphaned mapping entries: \(orphanedMappings.count)")
        
        // total size of orphaned files
        let orphanedSize = orphaned.compactMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }.reduce(0, +)
        print("Orphaned file size: \(orphanedSize / 1024 / 1024)MB")
    }
    #endif

    // MARK: - Helpers
    private func resolvedName(for name: String, exists: (String) -> Bool) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension

        // strip existing " N" suffix from base name
        let strippedBase: String
        if let range = base.range(of: #" \d+$"#, options: .regularExpression) {
            strippedBase = String(base[base.startIndex..<range.lowerBound])
        } else {
            strippedBase = base
        }

        var candidate = name
        var counter = 1
        while exists(candidate) {
            candidate = ext.isEmpty ? "\(strippedBase) \(counter)" : "\(strippedBase) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }
    
    private func resolvedName(for name: String, in directory: URL) -> String {
        resolvedName(for: name) { candidate in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
    }
    
    /// Returns the path relative to the documents directory (e.g. `subfolder/.vault_map`).
    /// Using the relative path as the AES-GCM AAD means a map copied from one folder to
    /// another will fail authentication — each folder's map is bound to its own location.
    private func authDomain(for url: URL) -> String {
        let root = LegacyStorage.current.vaultRootURL
        let rootPath = root.standardized.path
        let urlPath = url.standardized.path
        guard urlPath.hasPrefix(rootPath) else { return url.lastPathComponent }
        let relative = String(urlPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    /// `nil` means "no mapping file exists yet" (a legitimately empty directory).
    /// A thrown error means a mapping file exists but couldn't be read — e.g. corrupted by a
    /// torn write, or genuinely encrypted ciphertext being read before the key is loaded.
    /// Callers must NOT treat a thrown error as "empty" — doing so risks a subsequent save
    /// overwriting real data with nothing. See FileSystemError.mappingUnreadable.
    private func loadEncryptedJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { throw FileSystemError.mappingUnreadable }

        if keyStore.isKeyLoaded {
            // Primary: filename-only domain (.vault_map) — what saveEncryptedJSON always writes.
            let lastName = url.lastPathComponent
            if let decrypted = try? cipher.decrypt(data, contexts: [lastName]),
               let decoded = try? JSONDecoder().decode(T.self, from: decrypted) {
                return decoded
            }
            // Fallback 1: relative-path domain — for maps written during the brief period when
            // saveEncryptedJSON used authDomain(for:) instead of lastPathComponent.
            let relDomain = authDomain(for: url)
            if relDomain != lastName,
               let decrypted = try? cipher.decrypt(data, contexts: [relDomain]),
               let decoded = try? JSONDecoder().decode(T.self, from: decrypted) {
                return decoded
            }
            // Fallback 2: empty AAD — for maps written by the original encrypt(data:) API before
            // the authenticating: parameter existed.
            if let decrypted = try? cipher.decrypt(data, contexts: [""]),
               let decoded = try? JSONDecoder().decode(T.self, from: decrypted) {
                return decoded
            }
            throw FileSystemError.mappingUnreadable
        }
        // No key loaded — may still be a legacy plaintext mapping; try that before giving up.
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw FileSystemError.mappingUnreadable
        }
        return decoded
    }

    private func saveEncryptedJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        if keyStore.isKeyLoaded {
            let encrypted = try cipher.encrypt(data, context: url.lastPathComponent)
            try encrypted.write(to: url, options: .atomic)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func loadMapping(from directory: URL) throws -> [String: VaultMapping] {
        let mapURL = directory.appendingPathComponent(mappingFileName)
        do {
            return try loadEncryptedJSON([String: VaultMapping].self, from: mapURL) ?? [:]
        } catch FileSystemError.mappingUnreadable where keyStore.isKeyLoaded {
            // Older builds wrote plaintext indexes when the key was wiped mid-migration; accept
            // one only if it parses. The next save encrypts it (see encryptPlaintextIndexes).
            guard let data = try? Data(contentsOf: mapURL),
                  let plaintext = try? JSONDecoder().decode([String: VaultMapping].self, from: data) else {
                throw FileSystemError.mappingUnreadable
            }
            return plaintext
        }
    }

    private var sortComparator: (LegacyVaultItem, LegacyVaultItem) -> Bool {
        let option    = LegacyStorage.current.preferences.sortOption
        let ascending = LegacyStorage.current.preferences.sortDirection == .ascending

        return { lhs, rhs in
            // folders always first
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }

            let result: Bool
            switch option {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .type:
                let extLhs = (lhs.name as NSString).pathExtension.lowercased()
                let extRhs = (rhs.name as NSString).pathExtension.lowercased()
                if extLhs != extRhs {
                    result = extLhs.localizedStandardCompare(extRhs) == .orderedAscending
                } else {
                    result = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            case .dateModified:
                result = lhs.dateModified < rhs.dateModified
            }
            return ascending ? result : !result
        }
    }
    
    // MARK: - Testing Only
#if DEBUG
    func testTrashMap(for root: LegacyVaultDirectory) throws -> [String: TrashEntry] { try loadTrashMap(for: root.rootURL) }
    func saveTestTrashMap(_ map: [String: TrashEntry], for root: LegacyVaultDirectory) throws { try saveTrashMap(map, for: root.rootURL) }
    func testMapping(in directory: LegacyVaultDirectory) throws -> [String: VaultMapping] { try loadMapping(from: directory.diskURL) }
    typealias TrashEntryForTesting = TrashEntry
#endif
}

// MARK: - Migration index safety
extension FileSystem {
    /// Re-saves encrypted every plaintext folder index under `directory` (older builds wrote them
    /// when the key was wiped mid-migration). Throws `VaultCryptoError.noKeyLoaded` without the key.
    /// Damaged indexes are left alone; the hidden `.trash` folder is not visited.
    func encryptPlaintextIndexes(in directory: LegacyVaultDirectory) throws {
        guard keyStore.isKeyLoaded else { throw VaultCryptoError.noKeyLoaded }
        let mapURL = directory.diskURL.appendingPathComponent(mappingFileName)
        if FileManager.default.fileExists(atPath: mapURL.path) {
            let data = try Data(contentsOf: mapURL)
            let opensWithKey = (try? cipher.decrypt(data, contexts: [mappingFileName])) != nil
            if !opensWithKey, let plaintext = try? JSONDecoder().decode([String: VaultMapping].self, from: data) {
                try saveMappingRequiringKey(plaintext, to: directory.diskURL)
            }
        }
        let subdirs = try FileManager.default.contentsOfDirectory(
            at: directory.diskURL, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for subdir in subdirs {
            try encryptPlaintextIndexes(in: LegacyVaultDirectory(name: subdir.lastPathComponent, diskURL: subdir,
                                                           rootURL: directory.rootURL))
        }
    }

    /// Saves an index encrypted; throws `VaultCryptoError.noKeyLoaded` rather than writing plaintext.
    fileprivate func saveMappingRequiringKey(_ mapping: [String: VaultMapping], to directory: URL) throws {
        let data = try JSONEncoder().encode(mapping)
        let encrypted = try cipher.encrypt(data, context: mappingFileName)
        try encrypted.write(to: directory.appendingPathComponent(mappingFileName), options: .atomic)
    }

    private func saveMapping(_ mapping: [String: VaultMapping], to directory: URL) throws {
        try saveEncryptedJSON(mapping, to: directory.appendingPathComponent(mappingFileName))
    }
}

extension Notification.Name {
    static let fileRestored = Notification.Name("FileRestored")
}
