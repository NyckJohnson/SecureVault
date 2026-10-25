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

// MARK: - VaultDirectory
nonisolated struct VaultDirectory: Sendable {
    var name: String
    internal var diskURL: URL
    internal var rootURL: URL

    static var root: VaultDirectory {
        let url = LegacyStorage.current.vaultRootURL
        return VaultDirectory(name: "KoalaTVault", diskURL: url, rootURL: url)
    }
}

// MARK: - VaultItem
nonisolated struct VaultItem: Identifiable, Hashable, Sendable {
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

    nonisolated static func == (lhs: VaultItem, rhs: VaultItem) -> Bool {
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

    private let mappingFileName = ".vault_map"
    private let tempDir = FileManager.default.temporaryDirectory

#if DEBUG
    nonisolated(unsafe) static var testForcedMigrationFailureFileName: String?
#endif

    // MARK: - Encryption state
    private var isEncryptionEnabled: Bool {
        CryptoService.shared.isKeyLoaded
    }

    // MARK: - Browse
    func contents(of directory: VaultDirectory) throws -> [VaultItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory.diskURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        )
        let mapping = try loadMapping(from: directory.diskURL)
        return urls.compactMap { url -> VaultItem? in
            let fileName = url.lastPathComponent
            guard fileName != mappingFileName else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            let isDirectory = values?.isDirectory ?? false
            let dateModified = values?.contentModificationDate ?? Date()
            let fileSize = values?.fileSize

            if let mapped = mapping[fileName] {
                // encrypted file
                return VaultItem(
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
                return VaultItem(
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
    func importItems(from urls: [URL], to directory: VaultDirectory, progress: ((Double) -> Void)? = nil) throws {
        let total = Double(urls.reduce(0) { count, url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return count + (url.hasDirectoryPath ? countFiles(in: url) : 1)
        })

        if !EntitlementService.isUnlockedSync {
            let existingCount = countFiles(in: directory.rootURL)
            guard existingCount + Int(total) <= EntitlementService.freeFileLimit else {
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

    private func importSingleFile(from url: URL, to directory: VaultDirectory) throws {
        let originalName = url.lastPathComponent
        guard !isDuplicate(sourceURL: url, originalName: originalName, in: directory.diskURL) else { return }
        
        if isEncryptionEnabled {
            // resolve conflicts against existing mapped names
            let existingNames = try loadMapping(from: directory.diskURL).values.map { $0.originalName }
            let name = resolvedNameInMapping(for: originalName, existingNames: existingNames)
            let uuid = UUID().uuidString
            let destination = directory.diskURL.appendingPathComponent(uuid)
            try CryptoService.shared.encryptFile(at: url, to: destination)
            var mapping = try loadMapping(from: directory.diskURL)
            mapping[uuid] = VaultMapping(originalName: name)
            try saveMapping(mapping, to: directory.diskURL)
        } else {
            let name = resolvedName(for: originalName, in: directory.diskURL)
            let destination = directory.diskURL.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: destination)
        }
    }

    private func importFolder(from url: URL, to directory: VaultDirectory, onFileImported: (() -> Void)? = nil) throws {
        let existingURL = directory.diskURL.appendingPathComponent(url.lastPathComponent)
        var isDir: ObjCBool = false
        let folderExists = FileManager.default.fileExists(atPath: existingURL.path, isDirectory: &isDir) && isDir.boolValue
        let folderName = folderExists ? url.lastPathComponent : resolvedName(for: url.lastPathComponent, in: directory.diskURL)
        let destination = directory.diskURL.appendingPathComponent(folderName)
        if !folderExists {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let subDirectory = VaultDirectory(name: folderName, diskURL: destination, rootURL: directory.rootURL)

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
    func checkImportAllowed(additionalCount: Int, in directory: VaultDirectory) throws {
        guard !EntitlementService.isUnlockedSync else { return }
        let existingCount = countFiles(in: directory.rootURL)
        guard existingCount + additionalCount <= EntitlementService.freeFileLimit else {
            throw FileSystemError.fileLimitReached
        }
    }

    func importFromCameraRoll(
        results: [PHPickerResult],
        to directory: VaultDirectory,
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
            guard (try? CryptoService.shared.decryptFile(at: directory.appendingPathComponent(existingUUID), to: tempURL)) != nil,
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
    func open(_ item: VaultItem) throws -> URL {
        guard item.isEncrypted else { return item.diskURL }
        let tempSubDir = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempSubDir, withIntermediateDirectories: true)
        let tempURL = tempSubDir.appendingPathComponent(item.name)
        try CryptoService.shared.decryptFile(at: item.diskURL, to: tempURL)
        return tempURL
    }

    // MARK: - Write
    func write(data: Data, to item: VaultItem) throws {
        if item.isEncrypted {
            let tempPlain = tempDir.appendingPathComponent(UUID().uuidString)
            try data.write(to: tempPlain)
            defer { try? FileManager.default.removeItem(at: tempPlain) }

            let tempEncrypted = tempDir.appendingPathComponent(UUID().uuidString)
            try CryptoService.shared.encryptFile(at: tempPlain, to: tempEncrypted)
            defer { try? FileManager.default.removeItem(at: tempEncrypted) }

            _ = try FileManager.default.replaceItemAt(item.diskURL, withItemAt: tempEncrypted)
        } else {
            try data.write(to: item.diskURL)
        }
    }

    // MARK: - Export
    func prepareForExport(_ items: [VaultItem], progress: ((Double) -> Void)? = nil) throws -> [URL] {
        let total = Double(items.count)
        return try items.enumerated().map { index, item in
            defer { progress?(Double(index + 1) / total) }
            if item.isEncrypted {
                let tempSubDir = tempDir.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempSubDir, withIntermediateDirectories: true)
                let tempURL = tempSubDir.appendingPathComponent(item.name)
                try CryptoService.shared.decryptFile(at: item.diskURL, to: tempURL)
                return tempURL
            }
            return item.diskURL
        }
    }

    @concurrent
    func exportToCameraRoll(_ items: [VaultItem]) async -> (succeeded: Int, failed: Int) {
        let mediaItems = items.filter {
            let kind = FileKind(extension: ($0.name as NSString).pathExtension.lowercased())
            return kind == .image || kind == .video
        }
        guard !mediaItems.isEmpty else { return (0, 0) }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else { return (0, mediaItems.count) }

        var succeeded = 0
        for item in mediaItems {
            let isVideo = FileKind(extension: (item.name as NSString).pathExtension.lowercased()) == .video
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
    func createFolder(named name: String, in directory: VaultDirectory) throws -> VaultDirectory {
        guard !name.contains("/") else { throw FileSystemError.invalidName }
        let folderName = resolvedName(for: name, in: directory.diskURL)
        let url = directory.diskURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return VaultDirectory(name: folderName, diskURL: url, rootURL: directory.rootURL)
    }

    /// Creates an empty rich-text document `<name>.rtf` in `directory` and returns it.
    /// A taken name gets the " N" suffix; an existing document is never overwritten.
    /// With a lock on, the file is an empty SVC5 file under a UUID with a `.vault_map` entry.
    func createDocument(named name: String, in directory: VaultDirectory) throws -> VaultItem {
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
            try CryptoService.shared.encryptFile(at: tempPlain, to: destination)  // file first
            mapping[uuid] = VaultMapping(originalName: resolved)
            do {
                try saveMapping(mapping, to: directory.diskURL)                    // then the index
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return VaultItem(id: UUID(), name: resolved, isDirectory: false, dateModified: Date(), fileSize: 0,
                             diskURL: destination, rootURL: directory.rootURL, isEncrypted: true)
        } else {
            let resolved = resolvedName(for: fileName, in: directory.diskURL)
            let destination = directory.diskURL.appendingPathComponent(resolved)
            try Data().write(to: destination, options: .withoutOverwriting)
            return VaultItem(id: UUID(), name: resolved, isDirectory: false, dateModified: Date(), fileSize: 0,
                             diskURL: destination, rootURL: directory.rootURL, isEncrypted: false)
        }
    }

    func move(_ item: VaultItem, to directory: VaultDirectory) throws {
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

    func copy(_ item: VaultItem, to directory: VaultDirectory) throws {
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

    func rename(_ item: VaultItem, to name: String) throws {
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

    func delete(_ item: VaultItem) throws {
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

    func trashDirectory(for rootURL: URL) -> VaultDirectory {
        let url = rootURL.appendingPathComponent(trashFolderName)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return VaultDirectory(name: "Recently Deleted", diskURL: url, rootURL: rootURL)
    }

    func moveToTrash(_ item: VaultItem) throws {
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

    func restoreFromTrash(_ item: VaultItem) throws {
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

    func contentsOfTrash(for root: VaultDirectory) throws -> [VaultItem] {
        let trashMap = try loadTrashMap(for: root.rootURL)
        let trashURL = trashDirectory(for: root.rootURL).diskURL
        return trashMap.compactMap { uuid, entry in
            let diskURL = trashURL.appendingPathComponent(uuid)
            guard FileManager.default.fileExists(atPath: diskURL.path) else { return nil }
            return VaultItem(
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

    func permanentlyDelete(_ item: VaultItem) throws {
        var trashMap          = try loadTrashMap(for: item.rootURL)
        let uuid              = item.diskURL.lastPathComponent
        guard trashMap[uuid] != nil else { return }

        try FileManager.default.removeItem(at: item.diskURL)
        trashMap.removeValue(forKey: uuid)

        try saveTrashMap(trashMap, for: item.rootURL)
    }

    func emptyTrash(for root: VaultDirectory) throws {
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

    func cleanupExpiredTrashItems(for root: VaultDirectory) {
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
        } catch FileSystemError.mappingUnreadable where CryptoService.shared.isKeyLoaded {
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
    func filesToMigrate(toEncrypted: Bool, in directory: VaultDirectory) throws -> [(item: VaultItem, directory: VaultDirectory)] {
        let items = try contents(of: directory)
        let files = items.filter { !$0.isDirectory && $0.isEncrypted != toEncrypted }
        var result = files.map { (item: $0, directory: directory) }

        let subdirs = items.filter { $0.isDirectory }
        for subdir in subdirs {
            let subVaultDir = VaultDirectory(name: subdir.name, diskURL: subdir.diskURL, rootURL: directory.rootURL)
            result += try filesToMigrate(toEncrypted: toEncrypted, in: subVaultDir)
        }
        return result
    }
    
    func migrateVaultToEncrypted(in directory: VaultDirectory, progress: @escaping (Double) -> Void) throws {
        let items = try contents(of: directory)
        let files = items.filter { !$0.isDirectory && !$0.isEncrypted }
        let total = Double(files.count)
        guard total > 0 else { return }

        for (index, item) in files.enumerated() {
            try migrateFileToEncrypted(item, in: directory)
            progress(Double(index + 1) / total)
        }

        let subdirs = items.filter { $0.isDirectory }
        for subdir in subdirs {
            let subVaultDir = VaultDirectory(name: subdir.name, diskURL: subdir.diskURL, rootURL: directory.rootURL)
            try migrateVaultToEncrypted(in: subVaultDir, progress: progress)
        }
    }

    func migrateFileToEncrypted(_ item: VaultItem, in directory: VaultDirectory) throws {
        if let failName = LegacyStorage.current.uiTestSettings?.failMigrationFileName, failName == item.name {
            throw CryptoError.encryptionFailed
        }
#if DEBUG
        if FileSystem.testForcedMigrationFailureFileName == item.name {
            throw CryptoError.encryptionFailed
        }
#endif
        var mapping = try loadMapping(from: directory.diskURL)
        if mapping.values.contains(where: { $0.originalName == item.name }) {
            // plaintext survived a prior partial migration run — encrypted copy already exists
            try FileManager.default.removeItem(at: item.diskURL)
            return
        }
        let uuid = UUID().uuidString
        let destination = directory.diskURL.appendingPathComponent(uuid)
        try CryptoService.shared.encryptFile(at: item.diskURL, to: destination)
        mapping[uuid] = VaultMapping(originalName: item.name)
        try saveMapping(mapping, to: directory.diskURL)
        try FileManager.default.removeItem(at: item.diskURL)
    }

    /// Decrypts every encrypted file left in `directory` and its subfolders, then deletes each
    /// folder's `.vault_map`, so the vault lists with no key afterwards. Run with the key loaded
    /// as the last step of a decrypt migration, before the key is removed.
    /// A file that fails to decrypt throws and leaves its folder's index (and the indexes of the
    /// folders not yet visited) in place, so nothing is left unreadable while the key is kept.
    /// The hidden `.trash` folder is not visited.
    func migrateVaultToDecrypted(in directory: VaultDirectory, progress: @escaping (Double) -> Void) throws {
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
            let subVaultDir = VaultDirectory(name: subdir.lastPathComponent, diskURL: subdir, rootURL: directory.rootURL)
            try migrateVaultToDecrypted(in: subVaultDir, progress: progress)
        }
    }
    
    func migrateFileToDecrypted(_ item: VaultItem, in directory: VaultDirectory) throws {
        if let failName = LegacyStorage.current.uiTestSettings?.failMigrationFileName, failName == item.name {
            throw CryptoError.encryptionFailed
        }
#if DEBUG
        if FileSystem.testForcedMigrationFailureFileName == item.name {
            throw CryptoError.encryptionFailed
        }
#endif
        let encryptedURL = item.diskURL
        let name = resolvedName(for: item.name, in: directory.diskURL)
        let decryptedURL = directory.diskURL.appendingPathComponent(name)
        try CryptoService.shared.decryptFile(at: encryptedURL, to: decryptedURL)
        try FileManager.default.removeItem(at: encryptedURL)
        var mapping = try loadMapping(from: directory.diskURL)
        mapping.removeValue(forKey: encryptedURL.lastPathComponent)
        try saveMapping(mapping, to: directory.diskURL)
    }

    // MARK: - Cleanup
    func cleanupTempFiles() {
        let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        files?.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Removes UUID-named encrypted files that have no mapping entry — orphans left by a
    /// process kill between `encryptFile` and `saveMapping`. Best-effort; runs at launch.
    /// Only runs with the key loaded, and only deletes in folders that have a readable
    /// `.vault_map`: a folder with no index holds plaintext files, which are never orphans.
    func sweepOrphanedEncryptedFiles(in directory: VaultDirectory) {
        guard isEncryptionEnabled else { return }
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
                let sub = VaultDirectory(name: name, diskURL: url, rootURL: directory.rootURL)
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
        let root = VaultDirectory.root.diskURL
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

        if CryptoService.shared.isKeyLoaded {
            // Primary: filename-only domain (.vault_map) — what saveEncryptedJSON always writes.
            let lastName = url.lastPathComponent
            if let decrypted = try? CryptoService.shared.decrypt(data: data, authenticating: lastName),
               let decoded = try? JSONDecoder().decode(T.self, from: decrypted) {
                return decoded
            }
            // Fallback 1: relative-path domain — for maps written during the brief period when
            // saveEncryptedJSON used authDomain(for:) instead of lastPathComponent.
            let relDomain = authDomain(for: url)
            if relDomain != lastName,
               let decrypted = try? CryptoService.shared.decrypt(data: data, authenticating: relDomain),
               let decoded = try? JSONDecoder().decode(T.self, from: decrypted) {
                return decoded
            }
            // Fallback 2: empty AAD — for maps written by the original encrypt(data:) API before
            // the authenticating: parameter existed.
            if let decrypted = try? CryptoService.shared.decrypt(data: data, authenticating: ""),
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
        if CryptoService.shared.isKeyLoaded {
            let encrypted = try CryptoService.shared.encrypt(data: data, authenticating: url.lastPathComponent)
            try encrypted.write(to: url, options: .atomic)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func loadMapping(from directory: URL) throws -> [String: VaultMapping] {
        try loadEncryptedJSON([String: VaultMapping].self, from: directory.appendingPathComponent(mappingFileName)) ?? [:]
    }

    private func saveMapping(_ mapping: [String: VaultMapping], to directory: URL) throws {
        try saveEncryptedJSON(mapping, to: directory.appendingPathComponent(mappingFileName))
    }
    
    private var sortComparator: (VaultItem, VaultItem) -> Bool {
        let option    = PreferencesService.shared.sortOption
        let ascending = PreferencesService.shared.sortDirection == .ascending

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
    func testTrashMap(for root: VaultDirectory) throws -> [String: TrashEntry] { try loadTrashMap(for: root.rootURL) }
    func saveTestTrashMap(_ map: [String: TrashEntry], for root: VaultDirectory) throws { try saveTrashMap(map, for: root.rootURL) }
    func testMapping(in directory: VaultDirectory) throws -> [String: VaultMapping] { try loadMapping(from: directory.diskURL) }
    typealias TrashEntryForTesting = TrashEntry
#endif
}

extension Notification.Name {
    static let fileRestored = Notification.Name("FileRestored")
}
