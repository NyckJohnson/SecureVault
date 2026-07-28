//
//  FileSystem.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/17/26.
//

import Foundation
import PhotosUI
import CryptoKit
import CommonCrypto

// MARK: - VaultDirectory
struct VaultDirectory {
    var name: String
    internal var diskURL: URL

    static var root: VaultDirectory {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return VaultDirectory(name: "SecureVault", diskURL: url)
    }
}

// MARK: - VaultItem
nonisolated struct VaultItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var isDirectory: Bool
    var dateModified: Date
    var fileSize: Int?
    internal var diskURL: URL
    internal var isEncrypted: Bool

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: VaultItem, rhs: VaultItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - VaultMapping
private struct VaultMapping: Codable {
    let originalName: String
}

// MARK: - FileSystemAPI
final class FileSystem {
    static let shared = FileSystem()
    private init() {}

    private let mappingFileName = ".vault_map"
    private let tempDir = FileManager.default.temporaryDirectory

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
        let mapping = loadMapping(from: directory.diskURL)
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
                try importSingleFile(from: url, to: directory)
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
        if isEncryptionEnabled && CryptoService.shared.isKeyLoaded {
            // resolve conflicts against existing mapped names
            let existingNames = loadMapping(from: directory.diskURL).values.map { $0.originalName }
            let name = resolvedNameInMapping(for: originalName, existingNames: existingNames)
            let uuid = UUID().uuidString
            let destination = directory.diskURL.appendingPathComponent(uuid)
            try CryptoService.shared.encryptFile(at: url, to: destination)
            var mapping = loadMapping(from: directory.diskURL)
            mapping[uuid] = VaultMapping(originalName: name)
            try saveMapping(mapping, to: directory.diskURL)
        } else {
            let name = resolvedName(for: originalName, in: directory.diskURL)
            let destination = directory.diskURL.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: destination)
        }
    }

    private func importFolder(from url: URL, to directory: VaultDirectory, onFileImported: (() -> Void)? = nil) throws {
        let folderName = resolvedName(for: url.lastPathComponent, in: directory.diskURL)
        let destination = directory.diskURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let subDirectory = VaultDirectory(name: folderName, diskURL: destination)
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

    func importFromCameraRoll(results: [PHPickerResult], to directory: VaultDirectory, completion: @escaping (Int, Int) -> Void) {
        let group = DispatchGroup()
        var succeeded = 0
        var failed = 0

        for result in results {
            let provider = result.itemProvider
            guard let typeID = provider.registeredTypeIdentifiers.first else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, error in
                defer { group.leave() }
                guard let self, let url else { failed += 1; return }
                do {
                    try self.importSingleFile(from: url, to: directory)
                    succeeded += 1
                } catch {
                    failed += 1
                }
            }
        }
        group.notify(queue: .main) {
            completion(succeeded, failed)
        }
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
            let encrypted = try CryptoService.shared.encrypt(data: data)
            try encrypted.write(to: item.diskURL)
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

    func exportToCameraRoll(_ items: [VaultItem], completion: @escaping (Int, Int) -> Void) {
        let mediaItems = items.filter {
            ["jpg","jpeg","png","heic","gif","webp","mp4","mov","m4v"].contains(
                ($0.name as NSString).pathExtension.lowercased()
            )
        }
        let total = mediaItems.count
        var succeeded = 0
        var failed = 0

        let checkCompletion = {
            if succeeded + failed == total {
                completion(succeeded, failed)
            }
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                completion(0, total)
                return
            }
            for item in mediaItems {
                let ext = (item.name as NSString).pathExtension.lowercased()
                do {
                    let url = try self.open(item)
                    PHPhotoLibrary.shared().performChanges({
                        if ["mp4","mov","m4v"].contains(ext) {
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                        } else {
                            guard let image = UIImage(contentsOfFile: url.path) else { return }
                            PHAssetChangeRequest.creationRequestForAsset(from: image)
                        }
                    }) { success, _ in
                        DispatchQueue.main.async {
                            if success { succeeded += 1 } else { failed += 1 }
                            checkCompletion()
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        failed += 1
                        checkCompletion()
                    }
                }
            }
        }
    }

    // MARK: - Manage
    func createFolder(named name: String, in directory: VaultDirectory) throws -> VaultDirectory {
        let folderName = resolvedName(for: name, in: directory.diskURL)
        let url = directory.diskURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return VaultDirectory(name: folderName, diskURL: url)
    }

    func move(_ item: VaultItem, to directory: VaultDirectory) throws {
        let name = resolvedName(for: item.diskURL.lastPathComponent, in: directory.diskURL)
        let destination = directory.diskURL.appendingPathComponent(name)
        try FileManager.default.moveItem(at: item.diskURL, to: destination)
        if item.isEncrypted {
            // move mapping entry
            let sourceDir = item.diskURL.deletingLastPathComponent()
            var sourceMapping = loadMapping(from: sourceDir)
            var destMapping = loadMapping(from: directory.diskURL)
            let uuid = item.diskURL.lastPathComponent
            if let entry = sourceMapping[uuid] {
                destMapping[uuid] = entry
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
            var mapping = loadMapping(from: directory.diskURL)
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
            var mapping = loadMapping(from: dir)
            mapping[uuid] = VaultMapping(originalName: name)
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
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension

        let strippedBase: String
        if let range = base.range(of: #" \d+$"#, options: .regularExpression) {
            strippedBase = String(base[base.startIndex..<range.lowerBound])
        } else {
            strippedBase = base
        }

        var candidate = name
        var counter = 1
        while existingNames.contains(candidate) {
            candidate = ext.isEmpty ? "\(strippedBase) \(counter)" : "\(strippedBase) \(counter).\(ext)"
            counter += 1
        }
        return candidate
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
    }

    var trashDirectory: VaultDirectory {
        let url = VaultDirectory.root.diskURL.appendingPathComponent(trashFolderName)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return VaultDirectory(name: "Recently Deleted", diskURL: url)
    }

    func moveToTrash(_ item: VaultItem) throws {
        let trashURL = trashDirectory.diskURL
        let uuid = UUID().uuidString
        let destination = trashURL.appendingPathComponent(uuid)
        try FileManager.default.moveItem(at: item.diskURL, to: destination)

        if item.isEncrypted {
            let sourceDir = item.diskURL.deletingLastPathComponent()
            var sourceMapping = loadMapping(from: sourceDir)
            sourceMapping.removeValue(forKey: item.diskURL.lastPathComponent)
            try saveMapping(sourceMapping, to: sourceDir)
        }

        var trashMap = loadTrashMap()
        trashMap[uuid] = TrashEntry(
            originalDiskName: item.diskURL.lastPathComponent,
            originalDirectoryURL: item.diskURL.deletingLastPathComponent().path,
            deletedAt: Date(),
            isEncrypted: item.isEncrypted,
            originalName: item.name
        )
        try saveTrashMap(trashMap)
    }
    
    func restoreFromTrash(_ item: VaultItem) throws {
        var trashMap = loadTrashMap()
        guard let uuid = trashMap.first(where: { $0.value.originalName == item.name })?.key,
              let entry = trashMap[uuid] else { return }

        let originalDir = URL(fileURLWithPath: entry.originalDirectoryURL)
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)

        let destination = originalDir.appendingPathComponent(entry.originalDiskName)
        try FileManager.default.moveItem(at: item.diskURL, to: destination)

        if entry.isEncrypted {
            var mapping = loadMapping(from: originalDir)
            mapping[entry.originalDiskName] = VaultMapping(originalName: entry.originalName)
            try saveMapping(mapping, to: originalDir)
        }

        trashMap.removeValue(forKey: uuid)
        try saveTrashMap(trashMap)
    }

    func contentsOfTrash() -> [VaultItem] {
        let trashMap = loadTrashMap()
        let trashURL = trashDirectory.diskURL
        return trashMap.compactMap { uuid, entry in
            let diskURL = trashURL.appendingPathComponent(uuid)
            guard FileManager.default.fileExists(atPath: diskURL.path) else { return nil }
            return VaultItem(
                id: UUID(),
                name: entry.originalName,
                isDirectory: false,
                dateModified: entry.deletedAt,
                fileSize: nil,
                diskURL: diskURL,
                isEncrypted: entry.isEncrypted
            )
        }.sorted { $0.dateModified > $1.dateModified }
    }

    func permanentlyDelete(_ item: VaultItem) throws {
        var trashMap = loadTrashMap()
        guard let uuid = trashMap.first(where: { $0.value.originalName == item.name })?.key else { return }
        try FileManager.default.removeItem(at: item.diskURL)
        trashMap.removeValue(forKey: uuid)
        try saveTrashMap(trashMap)
    }

    func emptyTrash() throws {
        let items = contentsOfTrash()
        for item in items {
            try? FileManager.default.removeItem(at: item.diskURL)
        }
        let mapURL = trashDirectory.diskURL.appendingPathComponent(trashMapName)
        try? FileManager.default.removeItem(at: mapURL)
    }

    func cleanupExpiredTrashItems() {
        var trashMap = loadTrashMap()
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60) // 30 days
        var changed = false
        for (uuid, entry) in trashMap {
            if entry.deletedAt < cutoff {
                let diskURL = trashDirectory.diskURL.appendingPathComponent(uuid)
                try? FileManager.default.removeItem(at: diskURL)
                trashMap.removeValue(forKey: uuid)
                changed = true
            }
        }
        if changed { try? saveTrashMap(trashMap) }
    }

    private func loadTrashMap() -> [String: TrashEntry] {
        let mapURL = trashDirectory.diskURL.appendingPathComponent(trashMapName)
        guard let data = try? Data(contentsOf: mapURL) else { return [:] }
        if CryptoService.shared.isKeyLoaded,
           let decrypted = try? CryptoService.shared.decrypt(data: data) {
            return (try? JSONDecoder().decode([String: TrashEntry].self, from: decrypted)) ?? [:]
        }
        return (try? JSONDecoder().decode([String: TrashEntry].self, from: data)) ?? [:]
    }

    private func saveTrashMap(_ map: [String: TrashEntry]) throws {
        let mapURL = trashDirectory.diskURL.appendingPathComponent(trashMapName)
        let data = try JSONEncoder().encode(map)
        if CryptoService.shared.isKeyLoaded {
            let encrypted = try CryptoService.shared.encrypt(data: data)
            try encrypted.write(to: mapURL)
        } else {
            try data.write(to: mapURL)
        }
    }

    // MARK: - Migration
    func migrateToEncrypted(in directory: VaultDirectory, progress: @escaping (Double) -> Void) throws {
        let items = try contents(of: directory)
        let files = items.filter { !$0.isDirectory && !$0.isEncrypted }
        let total = Double(files.count)
        guard total > 0 else { return }

        for (index, item) in files.enumerated() {
            let uuid = UUID().uuidString
            let destination = directory.diskURL.appendingPathComponent(uuid)
            try CryptoService.shared.encryptFile(at: item.diskURL, to: destination)
            var mapping = loadMapping(from: directory.diskURL)
            mapping[uuid] = VaultMapping(originalName: item.name)
            try saveMapping(mapping, to: directory.diskURL)
            try FileManager.default.removeItem(at: item.diskURL)
            progress(Double(index + 1) / total)
        }

        let subdirs = items.filter { $0.isDirectory }
        for subdir in subdirs {
            let subVaultDir = VaultDirectory(name: subdir.name, diskURL: subdir.diskURL)
            try migrateToEncrypted(in: subVaultDir, progress: progress)
        }
    }

    func migrateToDecrypted(in directory: VaultDirectory, progress: @escaping (Double) -> Void) throws {
        let mapping = loadMapping(from: directory.diskURL)
        let total = Double(mapping.count)

        for (index, (uuid, vaultMapping)) in mapping.enumerated() {
            let encryptedURL = directory.diskURL.appendingPathComponent(uuid)
            let name = resolvedName(for: vaultMapping.originalName, in: directory.diskURL)
            let decryptedURL = directory.diskURL.appendingPathComponent(name)
            try CryptoService.shared.decryptFile(at: encryptedURL, to: decryptedURL)
            try FileManager.default.removeItem(at: encryptedURL)
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
            let subVaultDir = VaultDirectory(name: subdir.lastPathComponent, diskURL: subdir)
            try migrateToDecrypted(in: subVaultDir, progress: progress)
        }
    }

    // MARK: - Cleanup
    func cleanupTempFiles() {
        let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        files?.forEach { try? FileManager.default.removeItem(at: $0) }
    }
    
    func diagnoseDiskState() {
        let root = VaultDirectory.root.diskURL
        let mapping = loadMapping(from: root)
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

    // MARK: - Helpers
    private func resolvedName(for name: String, in directory: URL) -> String {
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
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(strippedBase) \(counter)" : "\(strippedBase) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private func loadMapping(from directory: URL) -> [String: VaultMapping] {
        let mapURL = directory.appendingPathComponent(mappingFileName)
       
        guard FileManager.default.fileExists(atPath: mapURL.path),
              let data = try? Data(contentsOf: mapURL) else { return [:] }
        if CryptoService.shared.isKeyLoaded,
           let decrypted = try? CryptoService.shared.decrypt(data: data) {
            return (try? JSONDecoder().decode([String: VaultMapping].self, from: decrypted)) ?? [:]
        }
        return (try? JSONDecoder().decode([String: VaultMapping].self, from: data)) ?? [:]
    }

    private func saveMapping(_ mapping: [String: VaultMapping], to directory: URL) throws {
        let mapURL = directory.appendingPathComponent(mappingFileName)
        let data = try JSONEncoder().encode(mapping)
        if CryptoService.shared.isKeyLoaded {
            let encrypted = try CryptoService.shared.encrypt(data: data)
            try encrypted.write(to: mapURL)
        } else {
            try data.write(to: mapURL)
        }
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
    func testTrashMap() -> [String: TrashEntry] { loadTrashMap() }
    func saveTestTrashMap(_ map: [String: TrashEntry]) throws { try saveTrashMap(map) }
    typealias TrashEntryForTesting = TrashEntry
    #endif
}
