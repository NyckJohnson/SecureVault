import Foundation

/// One entry of `.trash_map`, keyed by the trash UUID (the item's disk name in `.trash`).
///
/// Encodes with the field names and the default `Date` encoding earlier app versions wrote, so existing
/// vaults stay readable. `originalDirectoryURL` is written relative to the vault root ("" for the root);
/// older entries hold an absolute path, which `VaultTrashMap.originalFolder(of:)` re-bases.
struct VaultTrashEntry: Codable, Sendable, Equatable {
    /// The item's disk name in its original folder.
    var originalDiskName: String
    /// The original folder, relative to the vault root (older entries: absolute).
    var originalDirectoryURL: String
    /// When the item was moved to the trash.
    var deletedAt: Date
    /// Whether the item is an encrypted `<UUID>` file listed in its folder's index.
    var isEncrypted: Bool
    /// The display name.
    var originalName: String
    /// The vault root's path when the item was trashed; kept for compatibility, never read.
    var rootURL: String?
}

/// Reads and writes the vault's trash map, `<root>/.trash/.trash_map` (`{ "<trashUUID>": VaultTrashEntry }`),
/// where earlier app versions keep it.
///
/// Plaintext JSON in plaintext mode, sealed with context ".trash_map" in encrypted mode. Reads accept plaintext
/// JSON in either mode (a map written before a lock was added), so it is saved encrypted on the next write.
/// The map's name starts with ".", like every staging file in `.trash`, so it is never taken for a trash item.
struct VaultTrashMap: Sendable {
    /// The map file's name, also its encryption context.
    static let fileName = ".trash_map"
    /// The trash folder's name under the vault root.
    static let folderName = ".trash"
    /// The label `.indexUnreadable` uses for the trash.
    static let label = ".trash"
    /// Items trashed more than this long ago are purged.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    let cipher: any FileCipher
    let rootURL: URL

    /// The `.trash` folder.
    var folderURL: URL { rootURL.appendingPathComponent(Self.folderName, isDirectory: true) }
    /// The map file, inside `.trash`.
    var url: URL { folderURL.appendingPathComponent(Self.fileName) }

    /// Whether the map file exists.
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Whether `name` (a disk name in `.trash`) can be a trash item: not the map, not a hidden staging file.
    static func isItemName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
    }

    /// The map: empty when absent.
    /// - Throws: `.indexUnreadable(folder: ".trash")` when it exists but can't be read; `.locked` when the
    ///   key disappeared during an encrypted-mode read.
    func read(mode: VaultOperationMode) throws -> [String: VaultTrashEntry] {
        guard exists else { return [:] }
        // Contexts earlier versions sealed with: the file name, the root-relative path, then none.
        return try VaultIndex.readSealedJSON(
            [String: VaultTrashEntry].self, at: url,
            contexts: [Self.fileName, Self.folderName + "/" + Self.fileName, ""],
            cipher: cipher, mode: mode, unreadable: .indexUnreadable(folder: Self.label))
    }

    /// Writes the map (sealed in encrypted mode, never plaintext there), creating `.trash` if needed. An empty
    /// map is not created where none exists.
    /// - Throws: `.locked` when the key is gone in encrypted mode (nothing is written), `.io` otherwise.
    func write(_ entries: [String: VaultTrashEntry], mode: VaultOperationMode) throws {
        if entries.isEmpty, !exists { return }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            throw VaultStoreError.from(error)
        }
        try VaultIndex.writeSealedJSON(entries, to: url, context: Self.fileName, cipher: cipher, mode: mode)
    }

    /// The folder `entry` was trashed from, under the current root.
    ///
    /// A relative path is taken as it is; an absolute one (older entries) is re-based onto the current root
    /// by the part after the vault root's folder name. Untrusted (a plaintext map is unauthenticated), so it
    /// must stay inside the vault.
    /// - Throws: `.io` when the entry's folder or disk name points outside the vault or at a hidden folder.
    func originalFolder(of entry: VaultTrashEntry) throws -> URL {
        let outside = VaultStoreError.io("This item can't be restored: its original location is outside the vault.")
        let diskName = entry.originalDiskName
        guard !diskName.isEmpty, !diskName.contains("/"), diskName != ".", diskName != ".." else { throw outside }
        var components = entry.originalDirectoryURL.split(separator: "/").map(String.init)
        if entry.originalDirectoryURL.hasPrefix("/") {
            let rootPath = LiveVaultStore.standardPath(rootURL)
            let path = URL(fileURLWithPath: entry.originalDirectoryURL).standardizedFileURL.path
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                components = String(path.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
            } else if let rootIndex = components.firstIndex(of: rootURL.lastPathComponent) {
                components = Array(components[(rootIndex + 1)...])
            } else {
                throw outside
            }
        }
        // Hidden components would put the item where no listing shows it (or inside the trash).
        guard !components.contains(where: { $0.hasPrefix(".") }) else { throw outside }
        let folder = components.reduce(rootURL) { $0.appendingPathComponent($1, isDirectory: true) }
        // A symlink inside the vault must not lead out of it.
        guard LiveVaultStore.isSameOrInside(folder, rootURL) else { throw outside }
        return folder
    }
}

/// Moving to the trash, listing it, restoring, deleting for good and the 30-day purge.
///
/// Each operation runs without suspending, so its trash-map and index read-modify-writes are one serialized
/// step on the actor. The trash entry is written before the file moves into `.trash`, so a file in the trash
/// is never without its entry; an entry whose file is missing is never listed.
extension LiveVaultStore {
    /// The trash map of this vault.
    var trashMap: VaultTrashMap { VaultTrashMap(cipher: cipher, rootURL: root.rootURL) }

    /// The `.trash` folder as a directory (for item ids `.trash/<uuid>`).
    var trashDirectory: VaultDirectory {
        VaultDirectory(name: VaultTrashMap.folderName, diskURL: trashMap.folderURL, rootURL: root.rootURL)
    }

    /// Whether `item` sits directly in `.trash` (a trash item, not something inside a trashed folder).
    func isTrashItem(_ item: VaultItem) -> Bool {
        Self.samePath(item.diskURL.deletingLastPathComponent(), trashMap.folderURL)
    }

    // MARK: - Move to trash

    func moveToTrash(_ item: VaultItem) throws {
        let mode = try beginOperation()
        try requireExists(item.diskURL)
        let sourceFolder = item.diskURL.deletingLastPathComponent()
        let diskName = item.diskURL.lastPathComponent
        // Every read happens before anything changes, so an unreadable map or index changes nothing.
        let oldMap = try trashMap.read(mode: mode)
        var sourceEntries = item.isEncrypted ? try index.read(in: sourceFolder, mode: mode) : [:]
        let trashName = freshDiskName(in: trashMap.folderURL)
        var newMap = oldMap
        newMap[trashName] = VaultTrashEntry(
            originalDiskName: diskName,
            originalDirectoryURL: index.relativePath(of: sourceFolder),
            deletedAt: Date(),
            isEncrypted: item.isEncrypted,
            originalName: sourceEntries[diskName]?.originalName ?? item.name,
            rootURL: root.rootURL.path)
        do {
            try FileManager.default.createDirectory(at: trashMap.folderURL, withIntermediateDirectories: true)
        } catch {
            throw VaultStoreError.from(error)
        }
        try trashMap.write(newMap, mode: mode)
        do {
            try FileManager.default.moveItem(at: item.diskURL, to: trashMap.folderURL.appendingPathComponent(trashName))
        } catch {
            // Undo the entry; if that fails too, an entry whose file is missing is never listed and the item is
            // still in place.
            try? trashMap.write(oldMap, mode: mode)
            throw VaultStoreError.from(error)
        }
        guard item.isEncrypted else { return }
        // Source index last: if this write fails the item is already in the trash, and the stale entry names a
        // file that isn't there, so it isn't listed.
        sourceEntries.removeValue(forKey: diskName)
        try index.write(sourceEntries, in: sourceFolder, mode: mode)
    }

    // MARK: - List

    func trashContents() throws -> [VaultItem] {
        let mode = try beginOperation()
        return try trashItems(map: correctedTrashMap(trashMap.read(mode: mode), strict: false))
    }

    /// The trash items for `map`, newest first; entries whose file is missing are left out.
    func trashItems(map: [String: VaultTrashEntry]) -> [VaultItem] {
        let items = map.compactMap { trashName, entry in trashItem(named: trashName, entry: entry) }
        return items.sorted { lhs, rhs in
            let lhsDate = lhs.deletedAt ?? .distantPast
            let rhsDate = rhs.deletedAt ?? .distantPast
            return lhsDate == rhsDate ? lhs.id < rhs.id : lhsDate > rhsDate
        }
    }

    /// The trash item `.trash/<trashName>`, or nil when its file is missing.
    func trashItem(named trashName: String, entry: VaultTrashEntry) -> VaultItem? {
        // A malformed key or a missing file is not listed (and `makeItem` failing means the file is gone).
        guard VaultTrashMap.isItemName(trashName),
            let item = try? makeItem(
                diskName: trashName, in: trashDirectory, displayName: entry.originalName,
                isEncrypted: entry.isEncrypted)
        else { return nil }
        return VaultItem(
            id: item.id, name: item.name, isDirectory: item.isDirectory, dateModified: item.dateModified,
            fileSize: item.fileSize, deletedAt: entry.deletedAt, diskURL: item.diskURL, rootURL: item.rootURL,
            isEncrypted: item.isEncrypted)
    }

    // MARK: - Restore

    func restore(_ trashed: VaultItem) throws -> VaultItem {
        let mode = try beginOperation()
        // Re-indexed or not by the file's real form, not only the entry's flag.
        var map = try correctedTrashMap(trashMap.read(mode: mode), strict: false)
        let trashName = trashed.diskURL.lastPathComponent
        guard isTrashItem(trashed), VaultTrashMap.isItemName(trashName), let entry = map[trashName]
        else { throw VaultStoreError.notFound }
        let source = trashMap.folderURL.appendingPathComponent(trashName)
        try requireExists(source)
        let folderURL = try trashMap.originalFolder(of: entry)
        var entries = try index.read(in: folderURL, mode: mode)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            throw VaultStoreError.from(error)
        }
        let folder = VaultDirectory(name: folderURL.lastPathComponent, diskURL: folderURL, rootURL: root.rootURL)
        let taken = try takenNames(in: folderURL, entries: entries)
        let diskName: String
        let displayName: String
        if entry.isEncrypted {
            displayName = VaultNaming.resolvedName(for: entry.originalName) { taken.contains($0) }
            let originalDiskName = entry.originalDiskName
            diskName = exists(originalDiskName, in: folderURL) ? freshDiskName(in: folderURL) : originalDiskName
            // Index first, then the file: until the file moves, the stale entry names nothing and isn't listed.
            let oldEntries = entries
            entries[diskName] = VaultIndexEntry(originalName: displayName)
            try index.write(entries, in: folderURL, mode: mode)
            do {
                try FileManager.default.moveItem(at: source, to: folderURL.appendingPathComponent(diskName))
            } catch {
                try? index.write(oldEntries, in: folderURL, mode: mode)
                throw VaultStoreError.from(error)
            }
        } else {
            diskName = VaultNaming.resolvedName(for: entry.originalDiskName) { candidate in
                taken.contains(candidate) || exists(candidate, in: folderURL)
            }
            displayName = diskName
            do {
                try FileManager.default.moveItem(at: source, to: folderURL.appendingPathComponent(diskName))
            } catch {
                throw VaultStoreError.from(error)
            }
        }
        // Entry last: if this write fails the item is already back, and the stale entry names a missing file.
        map.removeValue(forKey: trashName)
        try trashMap.write(map, mode: mode)
        return try makeItem(diskName: diskName, in: folder, displayName: displayName, isEncrypted: entry.isEncrypted)
    }

    // MARK: - Delete

    func deletePermanently(_ trashed: VaultItem) throws {
        let mode = try beginOperation()
        var map = try trashMap.read(mode: mode)
        let trashName = trashed.diskURL.lastPathComponent
        guard isTrashItem(trashed), VaultTrashMap.isItemName(trashName), map[trashName] != nil
        else { throw VaultStoreError.notFound }
        let url = trashMap.folderURL.appendingPathComponent(trashName)
        try requireExists(url)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw VaultStoreError.from(error)
        }
        map.removeValue(forKey: trashName)
        try trashMap.write(map, mode: mode)
    }

    /// Removes everything in `.trash`, the map included, whether or not the map can be read: an unreadable map
    /// must never wedge the trash for good.
    func emptyTrash() {
        let manager = FileManager.default
        // Best-effort by contract (non-throwing): whatever can't be removed now is removed next time.
        if let names = try? manager.contentsOfDirectory(atPath: trashMap.folderURL.path) {
            for name in names { try? manager.removeItem(at: trashMap.folderURL.appendingPathComponent(name)) }
        }
    }

    // MARK: - Purge

    func purgeExpiredTrash(now: Date) throws -> Int {
        let mode = try beginOperation()
        var map = try trashMap.read(mode: mode)
        var purged = 0
        var firstError: VaultStoreError?
        // Strictly more than 30 days: an item trashed exactly 30 days before `now` stays.
        for (trashName, entry) in map where entry.deletedAt.addingTimeInterval(VaultTrashMap.retention) < now {
            let url = trashMap.folderURL.appendingPathComponent(trashName)
            if VaultTrashMap.isItemName(trashName), FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    // Keep the entry so the next purge retries; the failure is reported after the map is saved.
                    firstError = firstError ?? VaultStoreError.from(error)
                    continue
                }
            }
            map.removeValue(forKey: trashName)
            purged += 1
        }
        if purged > 0 { try trashMap.write(map, mode: mode) }
        if let firstError { throw firstError }
        return purged
    }
}
