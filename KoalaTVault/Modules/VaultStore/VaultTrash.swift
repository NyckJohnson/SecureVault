import Foundation
import os

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

/// Logs each removal of unreadable trash, without names.
private let unreadableTrashLog = Logger(subsystem: "com.KoalaTVault", category: "VaultStore")

/// Finding and clearing unreadable trash: trash sealed with a key the vault no longer has.
///
/// Deliberately strict, because what it finds is deleted: something is unreadable only in encrypted mode with the
/// key loaded, when the key opens the vault (`keyMatchesVault`), when the store itself has read the bytes in full,
/// and when the cipher then reports an authentication failure (`VaultCryptoError.decryptionFailed`) under every
/// context the data may have been sealed with. A read error, a missing key, any other cipher error or anything
/// else uncertain is never unreadable. Only `.trash` is ever looked at.
///
/// Each operation runs without suspending, so the check and the removal are one serialized step on the actor.
extension LiveVaultStore {
    /// What is unreadable in the trash right now.
    private enum UnreadableTrash {
        /// Nothing (or nothing certain).
        case none
        /// Kind (a): the trash index itself, so the whole trash.
        case wholeTrash
        /// Kind (b): these top-level trash items (disk names), with the readable trash map they belong to.
        case items([String], map: [String: VaultTrashEntry])
    }

    /// The verdict on one piece of sealed data.
    private enum SealCheck {
        /// Opens with the loaded key, or isn't sealed at all.
        case readable
        /// Read in full and fails authentication: sealed with another key.
        case foreign
        /// Couldn't be decided (read error, no key, any other failure).
        case uncertain
    }

    /// The verdict on a sealed JSON file (an index), with its JSON when it opens.
    private enum JSONSealCheck {
        case readable(Data)
        case foreign
        case uncertain
    }

    // MARK: - Entry points

    /// Whether the trash holds unreadable trash; false on any error (never throws).
    func hasUnreadableTrash() -> Bool {
        guard let mode = try? beginOperation() else { return false }
        if case .none = unreadableTrash(mode: mode) { return false }
        return true
    }

    /// Re-checks and removes only what is unreadable now: the whole of `.trash` for an unreadable trash index,
    /// otherwise the unreadable items and their entries.
    /// - Throws: `.locked` in encrypted mode without the key (nothing removed); `.io` after the rest are removed
    ///   when a removal fails; the trash map's write error when the remaining entries can't be saved.
    func clearUnreadableTrash() throws {
        let mode = try beginOperation()
        switch unreadableTrash(mode: mode) {
        case .none:
            return
        case .wholeTrash:
            try removeWholeTrash()
        case .items(let names, let map):
            try removeTrashItems(names, map: map, mode: mode)
        }
    }

    // MARK: - Check

    private func unreadableTrash(mode: VaultOperationMode) -> UnreadableTrash {
        guard mode.isEncrypted, mode.keyLoaded, keyMatchesVault() else { return .none }
        var map: [String: VaultTrashEntry] = [:]
        if trashMap.exists {
            switch sealedJSONCheck(at: trashMap.url, contexts: VaultTrashMap.contexts) {
            case .foreign:
                return .wholeTrash
            case .uncertain:
                return .none
            case .readable(let json):
                // A map that opens but doesn't decode is damaged, not foreign: nothing is decided.
                guard let decoded = try? JSONDecoder().decode([String: VaultTrashEntry].self, from: json) else {
                    return .none
                }
                map = decoded
            }
        }
        let folder = trashMap.folderURL
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return .none }
        let unreadable = names.sorted().filter { name in
            guard VaultTrashMap.isItemName(name) else { return false }
            return trashItemCheck(folder.appendingPathComponent(name), entry: map[name]) == .foreign
        }
        return unreadable.isEmpty ? .none : .items(unreadable, map: map)
    }

    /// Kind (b) for one top-level trash item: a file judged by its first chunk, a folder by its whole tree.
    private func trashItemCheck(_ url: URL, entry: VaultTrashEntry?) -> SealCheck {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        else { return .uncertain }
        if values.isSymbolicLink == true { return .uncertain }
        if values.isRegularFile == true { return sealedFileCheck(url) }
        if values.isDirectory == true { return trashFolderCheck(url, originalPath: entry.flatMap(originalPath(of:))) }
        return .uncertain
    }

    /// A trashed folder is foreign when any `.vault_map` or SVC5 file in its tree is foreign and nothing in the
    /// tree is uncertain (one doubt keeps the whole folder).
    /// - Parameter originalPath: the folder's root-relative path before it was trashed, for older index contexts.
    private func trashFolderCheck(_ itemURL: URL, originalPath: String?) -> SealCheck {
        var foundForeign = false
        // (folder, its path below the trashed item: "" for the item itself)
        var pending: [(URL, String)] = [(itemURL, "")]
        while let (folder, subpath) = pending.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
                return .uncertain
            }
            let original = originalPath.map { subpath.isEmpty ? $0 : $0 + "/" + subpath }
            for name in names {
                switch folderEntryCheck(name, in: folder, originalPath: original) {
                case .foreign: foundForeign = true
                case .uncertain: return .uncertain
                case .readable: break
                case .subfolder:
                    let below = subpath.isEmpty ? name : subpath + "/" + name
                    pending.append((folder.appendingPathComponent(name), below))
                }
            }
        }
        return foundForeign ? .foreign : .readable
    }

    /// The verdict on one entry of a folder inside a trashed folder.
    private enum FolderEntryCheck {
        case readable, foreign, uncertain
        /// A subfolder, judged on its own.
        case subfolder
    }

    /// One entry of `folder`: its `.vault_map` (sealed JSON), an SVC5 or plaintext file, or a subfolder. Other
    /// hidden files (staging leftovers) and symlinks are neither an index nor an item, so they count as readable.
    private func folderEntryCheck(_ name: String, in folder: URL, originalPath: String?) -> FolderEntryCheck {
        let url = folder.appendingPathComponent(name)
        if name == VaultIndex.fileName {
            switch sealedJSONCheck(at: url, contexts: folderIndexContexts(folder, originalPath: originalPath)) {
            case .foreign: return .foreign
            case .uncertain: return .uncertain
            case .readable: return .readable
            }
        }
        guard !name.hasPrefix(".") else { return .readable }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        else { return .uncertain }
        if values.isSymbolicLink == true { return .readable }
        if values.isDirectory == true { return .subfolder }
        guard values.isRegularFile == true else { return .readable }
        switch sealedFileCheck(url) {
        case .foreign: return .foreign
        case .uncertain: return .uncertain
        case .readable: return .readable
        }
    }

    /// An SVC5 file whose first chunk fails authentication, after the store has read every byte of it. A file
    /// without an SVC5 header is plaintext, never foreign.
    private func sealedFileCheck(_ url: URL) -> SealCheck {
        guard Self.readsInFull(url) else { return .uncertain }
        let info: StreamInfo
        do {
            info = try cipher.streamInfo(of: url)
        } catch VaultCryptoError.decryptionFailed {
            return .readable  // No SVC5 header: a plaintext file.
        } catch {
            return .uncertain
        }
        // An empty (or malformed) layout has no first chunk to judge.
        guard info.totalSize > 0, info.chunkSize > 0 else { return .uncertain }
        do {
            _ = try cipher.decryptChunk(0, of: url, info: info)
            return .readable
        } catch VaultCryptoError.decryptionFailed {
            return .foreign
        } catch {
            return .uncertain
        }
    }

    /// A JSON file read by the store: plaintext JSON or opening under one of `contexts` is readable; failing
    /// authentication under all of them is foreign; a read error or any other cipher error is uncertain.
    private func sealedJSONCheck(at url: URL, contexts: [String]) -> JSONSealCheck {
        guard let data = try? Data(contentsOf: url) else { return .uncertain }
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return .readable(data) }
        do {
            return .readable(try cipher.decrypt(data, contexts: contexts))
        } catch VaultCryptoError.decryptionFailed {
            return .foreign
        } catch {
            return .uncertain
        }
    }

    /// Every context a trashed folder's index may have been sealed with: ".vault_map", its current and its
    /// original root-relative path (each also as "<path>/.vault_map"), then "".
    private func folderIndexContexts(_ folder: URL, originalPath: String?) -> [String] {
        var contexts = [VaultIndex.fileName]
        for path in [index.relativePath(of: folder), originalPath ?? ""] where !path.isEmpty {
            contexts.append(path)
            contexts.append(path + "/" + VaultIndex.fileName)
        }
        contexts.append("")
        return contexts
    }

    /// The root-relative path a trashed item had before it was trashed, or nil when its entry doesn't give one
    /// inside the vault.
    private func originalPath(of entry: VaultTrashEntry) -> String? {
        guard let folder = try? trashMap.originalFolder(of: entry) else { return nil }
        // `originalFolder` builds on the root URL component by component, so its path starts with the root's.
        let rootPath = root.rootURL.path
        guard folder.path.hasPrefix(rootPath) else { return nil }
        let relative = folder.path.dropFirst(rootPath.count).split(separator: "/").joined(separator: "/")
        return relative.isEmpty ? entry.originalDiskName : relative + "/" + entry.originalDiskName
    }

    /// Whether every byte of the file at `url` can be read (streamed, so large files aren't held in memory).
    private static func readsInFull(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {}
            return true
        } catch {
            return false
        }
    }

    // MARK: - Removal

    /// Kind (a): removes everything in `.trash`, the map included.
    /// - Throws: `.io` after the rest are removed when anything can't be.
    private func removeWholeTrash() throws {
        let folder = trashMap.folderURL
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw VaultStoreError.io(error.localizedDescription)
        }
        var firstError: VaultStoreError?
        for name in names {
            do {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                unreadableTrashLog.notice("Removed an item of unreadable trash (the trash index can't be decrypted)")
            } catch {
                firstError = firstError ?? .io(error.localizedDescription)
            }
        }
        if let firstError { throw firstError }
    }

    /// Kind (b): removes the named top-level items and their entries; the other items and entries stay.
    /// - Throws: the map's write error; then `.io` when an item couldn't be removed (its entry is kept).
    private func removeTrashItems(
        _ names: [String], map: [String: VaultTrashEntry], mode: VaultOperationMode
    ) throws {
        var map = map
        var mapChanged = false
        var firstError: VaultStoreError?
        for name in names {
            do {
                try FileManager.default.removeItem(at: trashMap.folderURL.appendingPathComponent(name))
            } catch {
                firstError = firstError ?? .io(error.localizedDescription)
                continue
            }
            unreadableTrashLog.notice("Removed an unreadable trash item (sealed with a key the vault no longer has)")
            if map.removeValue(forKey: name) != nil { mapChanged = true }
        }
        if mapChanged { try trashMap.write(map, mode: mode) }
        if let firstError { throw firstError }
    }
}
