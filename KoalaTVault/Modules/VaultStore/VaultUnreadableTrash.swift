import Foundation
import os

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
/// `clearUnreadableTrash` runs without suspending, so its check and removal are one serialized step on the actor.
/// `hasUnreadableTrash` checks the top-level items in batches, each its own step, so it never holds up a Restore or
/// a Delete for long.
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

    /// What the first step of a trash check found, before any item is checked.
    private enum UnreadableTrashCandidates {
        /// Nothing can be unreadable (or nothing is certain).
        case none
        /// Kind (a): the trash index itself, so the whole trash.
        case wholeTrash
        /// These top-level trash items (disk names, sorted) are to be checked, with the readable trash map.
        case items([String], map: [String: VaultTrashEntry])
    }

    /// The most top-level trash items `hasUnreadableTrash()` checks in one step.
    private static let unreadableTrashBatchSize = 256

    /// Whether the trash holds unreadable trash; false on any error (never throws).
    ///
    /// The first step checks the mode, the key and the trash index and lists `.trash`; the top-level items are
    /// then checked in batches of at most `unreadableTrashBatchSize`, each its own step (the mode and `.trash`
    /// checked again), suspending only between steps so other store operations may run. It stops at the first
    /// unreadable item; a cancelled task or a vault locked mid-way answers false.
    func hasUnreadableTrash() async -> Bool {
        let candidates: UnreadableTrashCandidates = autoreleasepool {
            guard let mode = try? beginOperation() else { return .none }
            return unreadableTrashCandidates(mode: mode)
        }
        guard case .items(let names, let map) = candidates else {
            if case .wholeTrash = candidates { return true }
            return false
        }
        var pending = ArraySlice(names)
        while !pending.isEmpty {
            await Task.yield()
            guard !Task.isCancelled else { return false }
            let batch = pending.prefix(Self.unreadableTrashBatchSize)
            pending = pending.dropFirst(batch.count)
            // Each step frees its temporary memory when it ends.
            switch autoreleasepool(invoking: { unreadableTrashBatchStep(batch, map: map) }) {
            case .found: return true
            case .stopped: return false
            case .clean: continue
            }
        }
        return false
    }

    /// What one batch of `hasUnreadableTrash()` found.
    private enum UnreadableTrashBatch {
        /// An unreadable item: the answer is true.
        case found
        /// Nothing unreadable in this batch.
        case clean
        /// The vault locked or `.trash` stopped being a real folder: nothing more is decided.
        case stopped
    }

    /// One batch of `hasUnreadableTrash()`: whether any of `names` is unreadable, stopping at the first. Never
    /// suspends.
    private func unreadableTrashBatchStep(
        _ names: ArraySlice<String>, map: [String: VaultTrashEntry]
    ) -> UnreadableTrashBatch {
        guard let mode = try? beginOperation(), mode.isEncrypted, mode.keyLoaded,
            Self.fileType(trashMap.folderURL) == .typeDirectory
        else { return .stopped }
        let folder = trashMap.folderURL
        let probe = TrashFileProbe(store: self)
        defer { probe.close() }
        for name in names
        where trashItemCheck(folder.appendingPathComponent(name), entry: map[name], probe: probe) == .foreign {
            return .found
        }
        return .clean
    }

    /// Re-checks and removes only what is unreadable now: the whole of `.trash` for an unreadable trash index,
    /// otherwise the unreadable items and their entries.
    /// - Throws: `.locked` in encrypted mode without the key (nothing removed); `.io` after the rest are removed
    ///   when a removal fails; the trash map's write error when the remaining entries can't be saved.
    func clearUnreadableTrash() throws {
        try autoreleasepool { try unpooledClearUnreadableTrash() }
    }

    private func unpooledClearUnreadableTrash() throws {
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
        switch unreadableTrashCandidates(mode: mode) {
        case .none:
            return .none
        case .wholeTrash:
            return .wholeTrash
        case .items(let itemNames, let map):
            // Files are judged on private copies of their first bytes; without a place for them, nothing is decided.
            let folder = trashMap.folderURL
            let probe = TrashFileProbe(store: self)
            defer { probe.close() }
            var unreadable: [String] = []
            for name in itemNames
            where trashItemCheck(folder.appendingPathComponent(name), entry: map[name], probe: probe) == .foreign {
                unreadable.append(name)
            }
            return unreadable.isEmpty ? .none : .items(unreadable, map: map)
        }
    }

    /// The first part of the check: the mode, the key, `.trash` itself and kind (a), the trash index; then the
    /// top-level item names still to check.
    private func unreadableTrashCandidates(mode: VaultOperationMode) -> UnreadableTrashCandidates {
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
        return itemNames.isEmpty ? .none : .items(itemNames, map: map)
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
    static func fileType(_ url: URL) -> FileAttributeType? {
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
        // Each probe is one file of a loop over the trash: a pool per call frees its read buffers right away.
        try autoreleasepool { try unpooledStreamInfo(of: url) }
    }

    private func unpooledStreamInfo(of url: URL) throws -> StreamInfo? {
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
        // Each check is one file of a loop over the trash: a pool per call frees its read buffers right away.
        autoreleasepool { unpooledCheck(url) }
    }

    private func unpooledCheck(_ url: URL) -> TrashSealCheck {
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
