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
    /// Contexts earlier versions sealed the map with: the file name, the root-relative path, then none.
    static let contexts = [fileName, folderName + "/" + fileName, ""]

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
        return try VaultIndex.readSealedJSON(
            [String: VaultTrashEntry].self, at: url, contexts: Self.contexts,
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
            // coverage-exempt-begin: callers have already created .trash
            throw VaultStoreError.from(error)
            // coverage-exempt-end
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
        try autoreleasepool { try unpooledMoveToTrash(item) }
    }

    private func unpooledMoveToTrash(_ item: VaultItem) throws {
        let mode = try beginOperation()
        try requireExists(item.diskURL)
        let sourceFolder = item.diskURL.deletingLastPathComponent()
        let diskName = item.diskURL.lastPathComponent
        // Every read happens before anything changes, so an unreadable map or index changes nothing.
        let oldMap = try trashMap.read(mode: mode)
        var sourceEntries = item.isEncrypted ? try index.read(in: sourceFolder, mode: mode) : [:]
        let trashName = freshDiskName(in: trashMap.folderURL)
        var newMap = oldMap
        newMap[trashName] = trashEntry(for: item, originalName: sourceEntries[diskName]?.originalName)
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

    /// The trash entry for `item`, trashed now from its folder; `originalName` is its index entry's name, if any.
    private func trashEntry(for item: VaultItem, originalName: String?) -> VaultTrashEntry {
        VaultTrashEntry(
            originalDiskName: item.diskURL.lastPathComponent,
            originalDirectoryURL: index.relativePath(of: item.diskURL.deletingLastPathComponent()),
            deletedAt: Date(),
            isEncrypted: item.isEncrypted,
            originalName: originalName ?? item.name,
            rootURL: root.rootURL.path)
    }

    /// Trashes `items` in one serialized step, each exactly as `moveToTrash(_:)` would, reading and writing the
    /// trash map once and each source folder's index once.
    ///
    /// Write order keeps every item findable in exactly one place: the map with every new entry is written before
    /// any file moves; the entries of items whose move failed are dropped by a second map write; source indexes are
    /// written last. A failure before any file moved (no key, an unreadable or unwritable map) is every item's error.
    /// - Returns: the error of each item that stayed where it was, by id (`.notFound` for an unknown item, `.io`
    ///   for a failed move, its folder's index error); an item whose source index then fails to save is in the
    ///   trash but reported with that error, as the single call throws it.
    func moveToTrash(_ items: [VaultItem]) -> [VaultItem.ID: VaultStoreError] {
        guard !items.isEmpty else { return [:] }
        return autoreleasepool { unpooledMoveToTrash(items) }
    }

    /// One item of a batch trash, planned before anything changes.
    private struct PlannedTrash {
        let item: VaultItem
        let trashName: String
        let entry: VaultTrashEntry
    }

    /// The source folders' indexes of a batch trash, each read at most once, keyed by the folder's path.
    private struct BatchSourceIndexes {
        var entries: [String: [String: VaultIndexEntry]] = [:]
        var readErrors: [String: VaultStoreError] = [:]
        var folders: [String: URL] = [:]
        /// The ids of the items moved out of each folder (whose entries were removed).
        var moved: [String: [VaultItem.ID]] = [:]

        static func key(_ folder: URL) -> String { folder.standardizedFileURL.path }

        /// The folder's index, read through `read` the first time it is asked for.
        mutating func entries(
            in folder: URL, read: (URL) throws -> [String: VaultIndexEntry]
        ) throws -> [String: VaultIndexEntry] {
            let key = Self.key(folder)
            if let cached = entries[key] { return cached }
            if let error = readErrors[key] { throw error }
            do {
                let read = try read(folder)
                entries[key] = read
                folders[key] = folder
                return read
            } catch {
                let storeError = VaultStoreError.from(error)
                readErrors[key] = storeError
                throw storeError
            }
        }

        /// Removes the moved item's entry from its folder's index.
        mutating func remove(_ item: VaultItem) {
            let key = Self.key(item.diskURL.deletingLastPathComponent())
            entries[key]?.removeValue(forKey: item.diskURL.lastPathComponent)
            moved[key, default: []].append(item.id)
        }
    }

    private func unpooledMoveToTrash(_ items: [VaultItem]) -> [VaultItem.ID: VaultStoreError] {
        let mode: VaultOperationMode
        let oldMap: [String: VaultTrashEntry]
        do {
            mode = try beginOperation()
            oldMap = try trashMap.read(mode: mode)
        } catch {
            return Self.failures(of: items, error)
        }
        var failures: [VaultItem.ID: VaultStoreError] = [:]
        var sources = BatchSourceIndexes()
        var newMap = oldMap
        var planned: [PlannedTrash] = []
        for item in items {
            // Each item's work frees its temporary memory before the next.
            autoreleasepool {
                do {
                    let plan = try planTrash(item, taken: newMap, sources: &sources, mode: mode)
                    newMap[plan.trashName] = plan.entry
                    planned.append(plan)
                } catch {
                    failures[item.id] = VaultStoreError.from(error)
                }
            }
        }
        guard !planned.isEmpty else { return failures }
        do {
            try FileManager.default.createDirectory(at: trashMap.folderURL, withIntermediateDirectories: true)
            try trashMap.write(newMap, mode: mode)
        } catch {
            // Nothing has moved: every planned item stays where it was.
            return failures.merging(Self.failures(of: planned.map(\.item), error)) { current, _ in current }
        }
        var anyMoveFailed = false
        for plan in planned {
            autoreleasepool {
                do {
                    try FileManager.default.moveItem(
                        at: plan.item.diskURL, to: trashMap.folderURL.appendingPathComponent(plan.trashName))
                } catch {
                    failures[plan.item.id] = VaultStoreError.from(error)
                    newMap.removeValue(forKey: plan.trashName)
                    anyMoveFailed = true
                    return
                }
                if plan.item.isEncrypted { sources.remove(plan.item) }
            }
        }
        if anyMoveFailed {
            // Best effort, as the single call's undo: should this fail, the failed items' entries name files that
            // aren't in the trash, which are never listed (and restore or delete just drops them).
            try? trashMap.write(newMap, mode: mode)
        }
        writeSourceIndexes(sources, mode: mode, failures: &failures)
        return failures
    }

    /// Plans trashing `item` without changing anything: checks it exists, reads its folder's index (once per
    /// folder) for its display name and picks a trash name not on disk and not in `taken`.
    /// - Throws: `.notFound` for an unknown item; its folder's index read error.
    private func planTrash(
        _ item: VaultItem, taken: [String: VaultTrashEntry], sources: inout BatchSourceIndexes,
        mode: VaultOperationMode
    ) throws -> PlannedTrash {
        try requireExists(item.diskURL)
        var originalName: String?
        if item.isEncrypted {
            let entries = try sources.entries(in: item.diskURL.deletingLastPathComponent()) { folder in
                try index.read(in: folder, mode: mode)
            }
            originalName = entries[item.diskURL.lastPathComponent]?.originalName
        }
        var trashName = freshDiskName(in: trashMap.folderURL)
        while taken[trashName] != nil { trashName = freshDiskName(in: trashMap.folderURL) }
        return PlannedTrash(item: item, trashName: trashName, entry: trashEntry(for: item, originalName: originalName))
    }

    /// Writes each source folder that lost entries, last; a failed write is the error of the items moved out of
    /// that folder (they are in the trash, and their stale entries name files that aren't there).
    private func writeSourceIndexes(
        _ sources: BatchSourceIndexes, mode: VaultOperationMode, failures: inout [VaultItem.ID: VaultStoreError]
    ) {
        for (key, ids) in sources.moved.sorted(by: { $0.key < $1.key }) {
            guard let folder = sources.folders[key], let entries = sources.entries[key] else { continue }
            do {
                try index.write(entries, in: folder, mode: mode)
            } catch {
                for id in ids { failures[id] = VaultStoreError.from(error) }
            }
        }
    }

    /// `error` for every one of `items`, by id.
    private static func failures(of items: [VaultItem], _ error: any Error) -> [VaultItem.ID: VaultStoreError] {
        let storeError = VaultStoreError.from(error)
        var result: [VaultItem.ID: VaultStoreError] = [:]
        for item in items { result[item.id] = storeError }
        return result
    }

    // MARK: - List

    func trashContents() throws -> [VaultItem] {
        try autoreleasepool { try unpooledTrashContents() }
    }

    /// Never opens, copies or decrypts a trash file: each item's `isEncrypted` is its entry's stored flag.
    private func unpooledTrashContents() throws -> [VaultItem] {
        let mode = try beginOperation()
        return trashItems(map: try trashMap.read(mode: mode))
    }

    /// The trash items for `map`, newest first, with each entry's stored flag; entries whose file is missing (or
    /// whose key isn't an item name) are left out.
    ///
    /// Large trash: one pass, as `listing(of:)` is. `.trash` is read once with attributes prefetched (size, date,
    /// folder flag), its root-relative path worked out once, and each file matched to its entry by name.
    func trashItems(map: [String: VaultTrashEntry]) -> [VaultItem] {
        guard !map.isEmpty,
            let urls = try? FileManager.default.contentsOfDirectory(
                at: trashMap.folderURL, includingPropertiesForKeys: Self.itemResourceKeys)
        else { return [] }
        let directory = trashDirectory
        let folderPath = index.relativePath(of: directory.diskURL)
        let keys = Set(Self.itemResourceKeys)
        let items = urls.compactMap { url -> VaultItem? in
            let trashName = url.lastPathComponent
            // Prefetched values are cached on the URL; an entry gone before they were read has none.
            guard VaultTrashMap.isItemName(trashName), let entry = map[trashName],
                let values = try? url.resourceValues(forKeys: keys)
            else { return nil }
            let item = makeItem(
                diskName: trashName, in: directory, folderPath: folderPath, displayName: entry.originalName,
                isEncrypted: entry.isEncrypted, values: values)
            return VaultItem(
                id: item.id, name: item.name, isDirectory: item.isDirectory, dateModified: item.dateModified,
                fileSize: item.fileSize, deletedAt: entry.deletedAt, diskURL: item.diskURL, rootURL: item.rootURL,
                isEncrypted: item.isEncrypted)
        }
        return items.sorted { lhs, rhs in
            let lhsDate = lhs.deletedAt ?? .distantPast
            let rhsDate = rhs.deletedAt ?? .distantPast
            return lhsDate == rhsDate ? lhs.id < rhs.id : lhsDate > rhsDate
        }
    }

    // MARK: - Restore

    func restore(_ trashed: VaultItem) throws -> VaultItem {
        try autoreleasepool { try unpooledRestore(trashed) }
    }

    private func unpooledRestore(_ trashed: VaultItem) throws -> VaultItem {
        let mode = try beginOperation()
        var map = try trashMap.read(mode: mode)
        let trashName = trashed.diskURL.lastPathComponent
        guard isTrashItem(trashed), VaultTrashMap.isItemName(trashName), var entry = map[trashName]
        else { throw VaultStoreError.notFound }
        let source = trashMap.folderURL.appendingPathComponent(trashName)
        guard FileManager.default.fileExists(atPath: source.path) else {
            // The file is gone: its entry names nothing, so it is dropped.
            map.removeValue(forKey: trashName)
            try trashMap.write(map, mode: mode)
            throw VaultStoreError.notFound
        }
        // Re-indexed or not by this file's real form, not only the entry's flag; no other trash file is read.
        let storedEncrypted = entry.isEncrypted
        entry.isEncrypted = realTrashFlag(of: source, stored: storedEncrypted)
        if storedEncrypted, !entry.isEncrypted, Self.isPlainDiskName(entry.originalName) {
            // Recorded as an encrypted `<UUID>` file but really plaintext: it comes back under its display name,
            // as a plaintext file is named on disk.
            entry.originalDiskName = entry.originalName
        }
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

    /// Whether `name` can be a plaintext file's disk name: not empty, no "/", not hidden.
    private static func isPlainDiskName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
    }

    /// Whether the trash file at `url` is encrypted, from its SVC5 header (read through a probe, so the cipher
    /// never opens the trash file) where that is conclusive; `stored` for a folder, an undetermined header or a
    /// file that can't be checked, so one unreadable file never stops a restore.
    private func realTrashFlag(of url: URL, stored: Bool) -> Bool {
        guard Self.isRegularFile(url) else { return stored }
        let probe = TrashFileProbe(store: self)
        defer { probe.close() }
        switch try? fileForm(at: url, probe: probe) {
        case .encrypted?: return true
        case .plaintext?: return false
        case .undetermined?, nil: return stored
        }
    }

    // MARK: - Delete

    func deletePermanently(_ trashed: VaultItem) throws {
        try autoreleasepool { try unpooledDeletePermanently(trashed) }
    }

    private func unpooledDeletePermanently(_ trashed: VaultItem) throws {
        let mode = try beginOperation()
        var map = try trashMap.read(mode: mode)
        let trashName = trashed.diskURL.lastPathComponent
        guard isTrashItem(trashed), VaultTrashMap.isItemName(trashName), map[trashName] != nil
        else { throw VaultStoreError.notFound }
        let url = trashMap.folderURL.appendingPathComponent(trashName)
        // A file already gone just has its entry dropped.
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw VaultStoreError.from(error)
            }
        }
        map.removeValue(forKey: trashName)
        try trashMap.write(map, mode: mode)
    }

    /// Removes everything in `.trash`, the map included, whether or not the map can be read: an unreadable map
    /// must never wedge the trash for good.
    func emptyTrash() {
        autoreleasepool { unpooledEmptyTrash() }
    }

    private func unpooledEmptyTrash() {
        let manager = FileManager.default
        // Best-effort by contract (non-throwing): whatever can't be removed now is removed next time.
        if let names = try? manager.contentsOfDirectory(atPath: trashMap.folderURL.path) {
            for name in names { try? manager.removeItem(at: trashMap.folderURL.appendingPathComponent(name)) }
        }
    }

    // MARK: - Purge

    func purgeExpiredTrash(now: Date) throws -> Int {
        try autoreleasepool { try unpooledPurgeExpiredTrash(now: now) }
    }

    private func unpooledPurgeExpiredTrash(now: Date) throws -> Int {
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
