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

/// The verdict on one piece of sealed data in the trash (unreadable-trash check).
enum TrashSealCheck {
    /// Opens with the loaded key, or isn't sealed at all.
    case readable
    /// Read by the store and fails authentication: sealed with another key.
    case foreign
    /// Couldn't be decided (read error, no key, any other failure).
    case uncertain
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
    private typealias SealCheck = TrashSealCheck

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
        // `.trash` must be a real folder: a symlink could lead anywhere, and anything else isn't trash.
        guard Self.fileType(trashMap.folderURL) == .typeDirectory else { return .none }
        var map: [String: VaultTrashEntry] = [:]
        if Self.fileType(trashMap.url) != nil {
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
        let itemNames = names.sorted().filter(VaultTrashMap.isItemName)
        guard !itemNames.isEmpty else { return .none }
        // Files are judged on private copies of their first bytes; without a place for them, nothing is decided.
        let probe = TrashFileProbe(store: self)
        defer { probe.close() }
        var unreadable: [String] = []
        for name in itemNames
        where trashItemCheck(folder.appendingPathComponent(name), entry: map[name], probe: probe) == .foreign {
            unreadable.append(name)
        }
        return unreadable.isEmpty ? .none : .items(unreadable, map: map)
    }

    /// Kind (b) for one top-level trash item: a file judged by its first chunk, a folder by its whole tree.
    private func trashItemCheck(_ url: URL, entry: VaultTrashEntry?, probe: TrashFileProbe) -> SealCheck {
        switch Self.fileType(url) {
        case .typeRegular?:
            return probe.check(url)
        case .typeDirectory?:
            return trashFolderCheck(url, originalPath: entry.flatMap(originalPath(of:)), probe: probe)
        default:
            // A symlink, anything else, or a read error.
            return .uncertain
        }
    }

    /// The type of the item at `url` itself (a symlink is not followed), or nil when it can't be read.
    private static func fileType(_ url: URL) -> FileAttributeType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType
        else { return nil }
        return type
    }

    /// A trashed folder is foreign when any `.vault_map` or SVC5 file in its tree is foreign and nothing in the
    /// tree is uncertain (one doubt keeps the whole folder).
    /// - Parameter originalPath: the folder's root-relative path before it was trashed, for older index contexts.
    private func trashFolderCheck(_ itemURL: URL, originalPath: String?, probe: TrashFileProbe) -> SealCheck {
        var foundForeign = false
        // (folder, its path below the trashed item: "" for the item itself)
        var pending: [(URL, String)] = [(itemURL, "")]
        while let (folder, subpath) = pending.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
                return .uncertain
            }
            let original = originalPath.map { subpath.isEmpty ? $0 : $0 + "/" + subpath }
            for name in names {
                switch folderEntryCheck(name, in: folder, originalPath: original, probe: probe) {
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
    private func folderEntryCheck(
        _ name: String, in folder: URL, originalPath: String?, probe: TrashFileProbe
    ) -> FolderEntryCheck {
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
        switch probe.check(url) {
        case .foreign: return .foreign
        case .uncertain: return .uncertain
        case .readable: return .readable
        }
    }

    /// The shortest sealed record: a 12-byte nonce and a 16-byte authentication tag around an empty payload.
    private static let minimumSealedLength = 12 + 16

    /// A JSON file read by the store: plaintext JSON or opening under one of `contexts` is readable; failing
    /// authentication under all of them is foreign, but only when the data is at least as long as a sealed record
    /// (an empty or shorter file is damaged, not sealed with another key); a file that isn't a regular file, a read
    /// error or any other cipher error is uncertain.
    private func sealedJSONCheck(at url: URL, contexts: [String]) -> JSONSealCheck {
        guard Self.fileType(url) == .typeRegular, let data = try? Data(contentsOf: url) else { return .uncertain }
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return .readable(data) }
        guard data.count >= Self.minimumSealedLength else { return .uncertain }
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
    ///
    /// The trash map is rewritten without the items' entries first, so a failed write removes nothing. An item
    /// whose removal then fails gets its entry back (best effort) and is found again by the next check.
    /// - Throws: the map's write error (`.locked` or `.io`), nothing removed; else `.io` after the rest are removed
    ///   when an item couldn't be removed.
    private func removeTrashItems(
        _ names: [String], map: [String: VaultTrashEntry], mode: VaultOperationMode
    ) throws {
        var remaining = map
        for name in names { remaining.removeValue(forKey: name) }
        if remaining.count != map.count { try trashMap.write(remaining, mode: mode) }
        var firstError: VaultStoreError?
        var kept: [String: VaultTrashEntry] = [:]
        for name in names {
            do {
                try FileManager.default.removeItem(at: trashMap.folderURL.appendingPathComponent(name))
            } catch {
                firstError = firstError ?? .io(error.localizedDescription)
                kept[name] = map[name]
                continue
            }
            unreadableTrashLog.notice("Removed an unreadable trash item (sealed with a key the vault no longer has)")
        }
        if !kept.isEmpty {
            // Best effort: the removal error below is what the caller needs; a missing entry only hides an
            // item that the next check finds and clears again.
            try? trashMap.write(remaining.merging(kept) { current, _ in current }, mode: mode)
        }
        if let firstError { throw firstError }
    }
}

/// Lets the cipher judge an SVC5 file on bytes the store reads itself, never on the file.
///
/// The store reads a file's leading bytes (the header and, for `check`, the first chunk: at most `chunkSize`
/// plus `headerAllowance` bytes, never the whole file), writes them to a private copy in one store temp folder
/// (`makeTempDirectory`), and asks the cipher about that copy only. So the cipher never opens a trash item, and
/// a read or file-protection error is the store's own read failing, never something that passes for a wrong key.
/// A copy of the leading bytes reads exactly as the original: an SVC5 header carries the file's id and layout,
/// and chunk 0 sits at the same offset in both, so it authenticates (or fails) the same way.
///
/// One probe serves one operation on the store's actor; `close()` removes its own folder and never the store's
/// shared temp folder, which a concurrent `open` or `write` may be using.
final class TrashFileProbe {
    /// Bytes read before the header is known; also the room allowed above `chunkSize` for the header and the
    /// first record's framing (an SVC5 header and a record's length prefix, nonce and tag are far smaller).
    static let headerAllowance = 64 * 1024
    /// Bytes copied for a header-only read (`streamInfo(of:)`): an SVC5 header is far smaller.
    static let headerReadSize = 4 * 1024
    /// Larger chunk sizes are not a real layout; such a header is uncertain.
    private static let maximumChunkSize = 64 * 1_048_576

    /// Why a copy couldn't be made.
    enum CopyError: Error {
        /// The store's own read of the file failed.
        case read(any Error)
        /// The temp folder or the copy couldn't be created or written.
        case scratch(any Error)
    }

    private let store: LiveVaultStore
    private var folder: URL?

    init(store: LiveVaultStore) { self.store = store }

    /// Removes the copy's own folder; the store's temp folder stays.
    func close() {
        guard let folder else { return }
        store.removeTemporary(folder)
        self.folder = nil
    }

    /// The header facts of the file at `url`, asked of a copy of its leading bytes.
    /// - Returns: nil when the cipher finds no SVC5 header there (`decryptionFailed`): a plaintext file.
    /// - Throws: `CopyError` when the store's read or the copy fails; any other cipher error as it is.
    func streamInfo(of url: URL) throws -> StreamInfo? {
        let copy = try copyLeadingBytes(of: url, count: Self.headerReadSize).copy
        do {
            return try store.cipher.streamInfo(of: copy)
        } catch VaultCryptoError.decryptionFailed {
            return nil
        }
    }

    /// The verdict on one regular file: plaintext (no SVC5 header) or a first chunk that opens is readable; a
    /// first chunk that fails authentication or is incomplete is foreign; anything else is uncertain.
    func check(_ url: URL) -> TrashSealCheck {
        let head: (copy: URL, length: Int)
        let info: StreamInfo
        do {
            head = try copyLeadingBytes(of: url, count: Self.headerAllowance)
            do {
                info = try store.cipher.streamInfo(of: head.copy)
            } catch VaultCryptoError.decryptionFailed {
                // The header, if any, lies within the bytes copied: none parses, so the file is plaintext.
                return .readable
            }
        } catch {
            return .uncertain
        }
        // An empty or malformed layout has no first chunk to judge.
        guard info.totalSize > 0, (1...Self.maximumChunkSize).contains(info.chunkSize) else { return .uncertain }
        var copy = head.copy
        // Fewer bytes than asked for means the copy already holds the whole file.
        if head.length == Self.headerAllowance {
            guard let full = try? copyLeadingBytes(of: url, count: info.chunkSize + Self.headerAllowance) else {
                return .uncertain
            }
            copy = full.copy
        }
        do {
            _ = try store.cipher.decryptChunk(0, of: copy, info: info)
            return .readable
        } catch VaultCryptoError.decryptionFailed {
            return .foreign
        } catch {
            return .uncertain
        }
    }

    /// Reads up to `count` bytes from the start of the file at `url` (fewer only at its end) and writes them to
    /// the probe's copy, one file overwritten each time so copies don't pile up.
    /// - Returns: the copy and how many bytes it holds.
    private func copyLeadingBytes(of url: URL, count: Int) throws(CopyError) -> (copy: URL, length: Int) {
        var data = Data()
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while data.count < count {
                guard let block = try handle.read(upToCount: count - data.count), !block.isEmpty else { break }
                data.append(block)
            }
        } catch {
            throw .read(error)
        }
        do {
            let copy = try probeFolder().appendingPathComponent("probe")
            try data.write(to: copy, options: [.completeFileProtection])
            return (copy, data.count)
        } catch {
            throw .scratch(error)
        }
    }

    private func probeFolder() throws -> URL {
        if let folder { return folder }
        let made = try store.makeTempDirectory()
        folder = made
        return made
    }
}
