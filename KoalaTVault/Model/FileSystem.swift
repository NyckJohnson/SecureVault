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
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
    var deletedAt: Date? = nil
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

    var errorDescription: String? {
        switch self {
        case .mappingUnreadable:
            return "Couldn't read the vault's file index. It may still be locked, or a file may have become corrupted."
        case .fileLimitReached:
            return "You've reached the 100-file limit. Unlock more storage to continue importing."
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

        for result in results {
            let provider = result.itemProvider
            let assetID = result.assetIdentifier
            guard let typeID = provider.registeredTypeIdentifiers.first else {
                state.withLock { $0.failed += 1 }
                continue
            }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, _ in
                defer { group.leave() }
                guard let self, let url else {
                    state.withLock { $0.failed += 1 }
                    return
                }
                do {
                    try self.importSingleFile(from: url, to: directory)
                    if let assetID { state.withLock { $0.succeeded.append(assetID) } }
                } catch {
                    state.withLock { $0.failed += 1 }
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
        let tempURL = tempDir.appendingPathComponent(item.name)
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
                let tempURL = tempDir.appendingPathComponent(item.name)
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
                defer { if item.isEncrypted { try? FileManager.default.removeItem(at: url) } }
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
        let folderName = resolvedName(for: name, in: directory.diskURL)
        let url = directory.diskURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return VaultDirectory(name: folderName, diskURL: url, rootURL: directory.rootURL)
    }

    func move(_ item: VaultItem, to directory: VaultDirectory) throws {
        let name = resolvedName(for: item.diskURL.lastPathComponent, in: directory.diskURL)
        let destination = directory.diskURL.appendingPathComponent(name)
        try FileManager.default.moveItem(at: item.diskURL, to: destination)
        if item.isEncrypted {
            // move mapping entry
            let sourceDir = item.diskURL.deletingLastPathComponent()
            var sourceMapping = try loadMapping(from: sourceDir)
            var destMapping = try loadMapping(from: directory.diskURL)
            let uuid = item.diskURL.lastPathComponent
            if let entry = sourceMapping[uuid] {
                let existingNames = destMapping.values.map { $0.originalName }
                let resolvedOriginalName = resolvedNameInMapping(for: entry.originalName, existingNames: existingNames)
                destMapping[uuid] = VaultMapping(originalName: resolvedOriginalName)
                sourceMapping.removeValue(forKey: uuid)
                try saveMapping(sourceMapping, to: sourceDir)
                try saveMapping(destMapping, to: directory.diskURL)
            }
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
        try FileManager.default.moveItem(at: item.diskURL, to: destination)

        if item.isEncrypted {
            let sourceDir = item.diskURL.deletingLastPathComponent()
            var sourceMapping = try loadMapping(from: sourceDir)
            sourceMapping.removeValue(forKey: item.diskURL.lastPathComponent)
            try saveMapping(sourceMapping, to: sourceDir)
        }

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
    }

    func restoreFromTrash(_ item: VaultItem) throws {
        var trashMap    = try loadTrashMap(for: item.rootURL)
        let uuid        = item.diskURL.lastPathComponent
        guard let entry = trashMap[uuid] else { return }

        let originalDir = URL(fileURLWithPath: entry.originalDirectoryURL)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)

        let destination = originalDir.appendingPathComponent(entry.originalDiskName)
        try FileManager.default.moveItem(at: item.diskURL, to: destination)

        if entry.isEncrypted {
            var mapping = try loadMapping(from: originalDir)
            mapping[entry.originalDiskName] = VaultMapping(originalName: entry.originalName)
            try saveMapping(mapping, to: originalDir)
        }

        trashMap.removeValue(forKey: uuid)
        try saveTrashMap(trashMap, for: item.rootURL)
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
        // Safe to swallow: an unreadable map yields an empty dict, the loop below finds
        // nothing to remove, `changed` stays false, and we never reach saveTrashMap — so a
        // failed read here can never overwrite good data with an empty one.
        var trashMap = (try? loadTrashMap(for: root.rootURL)) ?? [:]
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60) // 30 days
        var changed = false
        let trashURL = trashDirectory(for: root.rootURL).diskURL
        for (uuid, entry) in trashMap {
            if entry.deletedAt < cutoff {
                let diskURL = trashURL.appendingPathComponent(uuid)
                try? FileManager.default.removeItem(at: diskURL)
                trashMap.removeValue(forKey: uuid)
                changed = true
            }
        }
        if changed { try? saveTrashMap(trashMap, for: root.rootURL) }
    }

    private func loadTrashMap(for rootURL: URL) throws -> [String: TrashEntry] {
        try loadEncryptedJSON([String: TrashEntry].self, from: trashDirectory(for: rootURL).diskURL.appendingPathComponent(trashMapName)) ?? [:]
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
#if DEBUG
        if ProcessInfo.processInfo.environment["UITEST_FAIL_MIGRATION_FILE"] == item.name
            || FileSystem.testForcedMigrationFailureFileName == item.name {
            throw CryptoError.encryptionFailed
        }
#endif
        let uuid = UUID().uuidString
        let destination = directory.diskURL.appendingPathComponent(uuid)
        try CryptoService.shared.encryptFile(at: item.diskURL, to: destination)
        var mapping = try loadMapping(from: directory.diskURL)
        mapping[uuid] = VaultMapping(originalName: item.name)
        try saveMapping(mapping, to: directory.diskURL)
        try FileManager.default.removeItem(at: item.diskURL)
    }

    func migrateVaultToDecrypted(in directory: VaultDirectory, progress: @escaping (Double) -> Void) throws {
        let mapping = try loadMapping(from: directory.diskURL)
        let total   = Double(mapping.count)
        let items   = try contents(of: directory).filter { !$0.isDirectory && $0.isEncrypted }
        
        for (index, item) in items.enumerated() {
            try migrateFileToDecrypted(item, in: directory)
            if total > 0 { progress(Double(index + 1) / total) }
        }

        let mapURL = directory.diskURL.appendingPathComponent(mappingFileName)
        try? FileManager.default.removeItem(at: mapURL)

        let subdirs = (try? FileManager.default.contentsOfDirectory(
            at: directory.diskURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []

        for subdir in subdirs {
            let subVaultDir = VaultDirectory(name: subdir.lastPathComponent, diskURL: subdir, rootURL: directory.rootURL)
            try migrateVaultToDecrypted(in: subVaultDir, progress: progress)
        }
    }
    
    func migrateFileToDecrypted(_ item: VaultItem, in directory: VaultDirectory) throws {
#if DEBUG
        if ProcessInfo.processInfo.environment["UITEST_FAIL_MIGRATION_FILE"] == item.name
            || FileSystem.testForcedMigrationFailureFileName == item.name {
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
        let diskFiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        
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
    
    /// `nil` means "no mapping file exists yet" (a legitimately empty directory).
    /// A thrown error means a mapping file exists but couldn't be read — e.g. corrupted by a
    /// torn write, or genuinely encrypted ciphertext being read before the key is loaded.
    /// Callers must NOT treat a thrown error as "empty" — doing so risks a subsequent save
    /// overwriting real data with nothing. See FileSystemError.mappingUnreadable.
    private func loadEncryptedJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { throw FileSystemError.mappingUnreadable }

        if CryptoService.shared.isKeyLoaded {
            guard let decrypted = try? CryptoService.shared.decrypt(data: data, authenticating: url.lastPathComponent),
                  let decoded = try? JSONDecoder().decode(T.self, from: decrypted) else {
                throw FileSystemError.mappingUnreadable
            }
            return decoded
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

        return { a, b in
            // folders always first
            if a.isDirectory != b.isDirectory { return a.isDirectory }

            let result: Bool
            switch option {
            case .name:
                result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .type:
                let extA = (a.name as NSString).pathExtension.lowercased()
                let extB = (b.name as NSString).pathExtension.lowercased()
                if extA != extB {
                    result = extA.localizedStandardCompare(extB) == .orderedAscending
                } else {
                    result = a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            case .dateModified:
                result = a.dateModified < b.dateModified
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
