import Foundation

/// The per-file steps that encrypt a vault's leftover plaintext files, and the checks around them. A store's
/// encryption is fixed for its life, so nothing decrypts a whole vault; these steps only ever encrypt.
///
/// Every step can be interrupted and run again without losing content. For files in folders, at each point
/// either the source or a verified, indexed copy exists, and a rerun finishes the work (a leftover plaintext
/// is removed only after a byte-for-byte match; an incomplete copy is dropped with its entry).
///
/// The trash is encrypted too: trash items are converted in place and keep their trash id; folders in the
/// trash are walked like any other folder. A kill between a trash item's map update and its file replace
/// leaves the entry's flag disagreeing with the file. That is harmless because a file's real form is always
/// read from its SVC5 header (`fileForm(at:)`), never from an index or trash-entry flag alone: listings,
/// and the encrypt steps use the real form and correct the entry, and the next step on that item removes its
/// leftover hidden `.<id>.migrating` staging file and converts it from the untouched original.
///
/// Steps run without suspending, so each is one serialized step on the actor. `hasUnencryptedFiles()` differs:
/// it suspends between folders (never inside one), so browsing isn't held up.
extension LiveVaultStore {
    // MARK: - Counting and listing

    /// Counts regular files under the root; hidden entries (indexes, the trash) are skipped. Reads no index or
    /// file content, so it needs no key.
    func countFiles() throws -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        var count = 0
        var enumerationError: (any Error)?
        guard
            let enumerator = FileManager.default.enumerator(
                at: root.diskURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    enumerationError = enumerationError ?? error
                    return true
                })
        else { throw VaultStoreError.io("The vault folder can't be read.") }
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true { count += 1 }
        }
        if let enumerationError { throw VaultStoreError.from(enumerationError) }
        return count
    }

    /// Every plaintext file under the root and in the trash; empty for a plaintext store, which never encrypts.
    func itemsToEncrypt() throws -> [VaultItem] {
        guard isEncrypted else { return [] }
        return try plaintextFiles()
    }

    /// Whether any plaintext file is under the root or in the trash (in either kind of store), judged by each
    /// file's SVC5 header as `itemsToEncrypt()` judges it; stops at the first one found.
    ///
    /// Works one folder at a time, so housekeeping never holds up browsing: the root's folders first (the root
    /// itself in the first step), then the trash (its map and its files as one step), then the folders in the
    /// trash. Each step checks the mode again and has no suspension inside it; the check suspends only between
    /// steps, where other store operations may run. A folder removed in between is skipped; one changed is
    /// judged as it is when its step runs.
    /// - Throws: `.locked` without the key in encrypted mode (checked at every step); `.indexUnreadable` /
    ///   `.io` when an index or a file's form can't be read.
    func hasUnencryptedFiles() async throws -> Bool {
        var pending = [root]
        var trashChecked = false
        var isFirstStep = true
        while true {
            if !isFirstStep { await Task.yield() }
            isFirstStep = false
            let mode = try beginOperation()
            if let folder = pending.popLast() {
                guard let subfolders = try plaintextCheckStep(folder, mode: mode) else { return true }
                pending += subfolders
            } else if !trashChecked {
                trashChecked = true
                let items = trashItems(map: try correctedTrashMap(trashMap.read(mode: mode)))
                if items.contains(where: { !$0.isDirectory && !$0.isEncrypted }) { return true }
                pending = items.compactMap(\.asDirectory)
            } else {
                return false
            }
        }
    }

    /// One step of `hasUnencryptedFiles()`: checks the files directly in `folder`. Never suspends.
    /// - Returns: nil when a plaintext file is found; otherwise the folder's subfolders (none when the folder
    ///   was removed since it was queued).
    private func plaintextCheckStep(_ folder: VaultDirectory, mode: VaultOperationMode) throws -> [VaultDirectory]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.diskURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }
        let items = try listing(of: folder, mode: mode)
        for item in items where !item.isDirectory {
            if try realForm(of: item) == .plaintext { return nil }
        }
        return items.compactMap(\.asDirectory)
    }

    /// Every plaintext file under the root and in the trash, each judged by its SVC5 header; unindexed SVC5
    /// files (orphans) are left out.
    /// - Throws: `.locked` without the key in encrypted mode; `.indexUnreadable` / `.io` when an index or a
    ///   file's form can't be read.
    private func plaintextFiles() throws -> [VaultItem] {
        let mode = try beginOperation()
        let map = try correctedTrashMap(trashMap.read(mode: mode))
        var result: [VaultItem] = []
        try forEachListing(trash: map, mode: mode) { _, items in
            for item in items where !item.isDirectory {
                let form = try realForm(of: item)
                guard form == .plaintext else { continue }
                result.append(Self.plaintext(item))
            }
        }
        result += trashItems(map: map).filter { !$0.isDirectory && !$0.isEncrypted }
        return result
    }

    /// Calls `body` with every folder and its listing: the root and its non-hidden subfolders, then each folder
    /// in the trash and its subfolders. Never visits `.trash` itself (its items are in `trash`).
    /// - Throws: `.indexUnreadable` for the first folder whose index can't be read.
    private func forEachListing(
        trash: [String: VaultTrashEntry], mode: VaultOperationMode,
        _ body: (VaultDirectory, [VaultItem]) throws -> Void
    ) throws {
        var pending = [root] + trashItems(map: trash).compactMap(\.asDirectory)
        while let folder = pending.popLast() {
            let items = try listing(of: folder, mode: mode)
            try body(folder, items)
            pending += items.compactMap(\.asDirectory)
        }
    }

    /// What a listed file really is for encryption.
    private enum MigrationForm {
        case encrypted, plaintext
        /// An unindexed SVC5 file: an orphan, never encrypted (the sweep removes it).
        case orphan
    }

    /// A listed file's real form, judged by its header where that is conclusive: an indexed file that isn't an
    /// SVC5 file is plaintext; an unindexed SVC5 file is an orphan.
    private func realForm(of item: VaultItem) throws -> MigrationForm {
        let form = try fileForm(at: item.diskURL)
        if item.isEncrypted { return form == .plaintext ? .plaintext : .encrypted }
        return form == .encrypted ? .orphan : .plaintext
    }

    /// `item` marked plaintext (an indexed entry whose file isn't an SVC5 file is listed as encrypted).
    private static func plaintext(_ item: VaultItem) -> VaultItem {
        guard item.isEncrypted else { return item }
        return VaultItem(
            id: item.id, name: item.name, isDirectory: item.isDirectory, dateModified: item.dateModified,
            fileSize: item.fileSize, deletedAt: item.deletedAt, diskURL: item.diskURL, rootURL: item.rootURL,
            isEncrypted: false)
    }

    /// `map` with each trash file's `isEncrypted` set from the file's real form where its header is conclusive.
    ///
    /// Encrypt steps pass `strict: true`: a file whose form can't be read stops them. Listing and restore pass
    /// `strict: false`: such a file keeps its stored flag, so one unreadable trash file never hides the others.
    /// - Throws: with `strict`, `.locked` without the key, `.io` when a trash file can't be read.
    func correctedTrashMap(_ map: [String: VaultTrashEntry], strict: Bool = true) throws -> [String: VaultTrashEntry] {
        var result = map
        // Trash files are judged on copies of bytes the store reads itself; the cipher never opens them.
        let probe = TrashFileProbe(store: self)
        defer { probe.close() }
        for (trashName, entry) in map where VaultTrashMap.isItemName(trashName) {
            let url = trashMap.folderURL.appendingPathComponent(trashName)
            guard Self.isRegularFile(url) else { continue }
            let form: FileForm
            do {
                form = try fileForm(at: url, probe: probe)
            } catch {
                guard !strict else { throw error }
                // Best-effort for listing and restore: the stored flag stands for a file that can't be checked.
                continue
            }
            switch form {
            case .encrypted where !entry.isEncrypted: result[trashName]?.isEncrypted = true
            case .plaintext where entry.isEncrypted: result[trashName]?.isEncrypted = false
            default: break
            }
        }
        return result
    }

    /// What a file's header says it is.
    enum FileForm {
        /// An SVC5 file: the header parses and the file is longer than the plaintext it records.
        case encrypted
        /// Not an SVC5 file (no valid header, or empty).
        case plaintext
        /// The header can't tell (the cipher reads it but the sizes don't settle it).
        case undetermined
    }

    /// The real form of the file at `url`, from its SVC5 header.
    /// - Throws: `.locked` without the key; `.io` / `.notFound` when the file can't be read at all, so
    ///   "couldn't check" is never taken for "plaintext".
    func fileForm(at url: URL) throws -> FileForm {
        let info: StreamInfo
        do {
            info = try cipher.streamInfo(of: url)
        } catch VaultCryptoError.noKeyLoaded {
            throw VaultStoreError.locked
        } catch {
            do {
                try Self.readFirstByte(of: url)
            } catch {
                throw VaultStoreError.from(error)
            }
            return .plaintext
        }
        // An encrypted file always carries a header on top of its plaintext's length.
        return try fileSize(of: url) > info.totalSize ? .encrypted : .undetermined
    }

    /// `fileForm(at:)` for a trash file, with the header read through `probe` (a copy of the file's leading
    /// bytes the store read itself), so the cipher never opens the trash file.
    /// - Throws: `.locked` without the key; `.io` / `.notFound` when the store can't read the file or make the copy.
    func fileForm(at url: URL, probe: TrashFileProbe) throws -> FileForm {
        let info: StreamInfo?
        do {
            info = try probe.streamInfo(of: url)
        } catch VaultCryptoError.noKeyLoaded {
            throw VaultStoreError.locked
        } catch TrashFileProbe.CopyError.read(let error), TrashFileProbe.CopyError.scratch(let error) {
            throw VaultStoreError.from(error)
        } catch {
            // Any other cipher error on bytes the store has read: no SVC5 header there (as `fileForm(at:)`).
            return .plaintext
        }
        guard let info else { return .plaintext }
        // An encrypted file always carries a header on top of its plaintext's length.
        return try fileSize(of: url) > info.totalSize ? .encrypted : .undetermined
    }

    // MARK: - Encrypt

    /// Encrypt → verify (byte for byte) → index entry saved encrypted → read back → verify again → plaintext
    /// removed. A plaintext whose same-name encrypted copy already matches byte for byte (an earlier run that
    /// stopped before removing it) is only removed; a different copy keeps both, the new one numbered.
    func migrateToEncrypted(_ item: VaultItem) throws {
        let mode = try beginOperation()
        guard mode.keyLoaded else { throw VaultStoreError.locked }
        guard !item.isDirectory else { throw VaultStoreError.io("A folder has no content to encrypt.") }
        // Encrypted content gets an encrypted index, whatever the lock mode says.
        let sealed = VaultOperationMode(isEncrypted: true, keyLoaded: true)
        if isTrashItem(item) {
            try encryptTrashItem(item, mode: sealed)
            return
        }
        // Removed only by an earlier run, after its copy and entry were verified.
        guard FileManager.default.fileExists(atPath: item.diskURL.path) else { return }
        let folder = item.diskURL.deletingLastPathComponent()
        let plainName = item.diskURL.lastPathComponent
        var entries = try index.read(in: folder, mode: sealed)
        if entries[plainName] != nil {
            // Listed in the index: already encrypted, unless the file isn't an SVC5 file (an entry naming a
            // plaintext file, which is encrypted like any other under the entry's name).
            guard try fileForm(at: item.diskURL) == .plaintext else { return }
            entries.removeValue(forKey: plainName)
        }
        // Entries without their file name nothing; they are dropped with the next write.
        entries = entries.filter { exists($0.key, in: folder) }
        var incomplete: [URL] = []
        if try hasIdenticalCopy(of: item, in: folder, entries: &entries, incomplete: &incomplete) {
            if !incomplete.isEmpty {
                try index.write(entries, in: folder, mode: sealed)
                try incomplete.forEach(removeFile)
            }
            try removeFile(item.diskURL)
            return
        }
        let plaintextSize = try fileSize(of: item.diskURL)
        let taken = try takenNames(in: folder, entries: entries, excluding: plainName)
        let displayName = VaultNaming.resolvedName(for: item.name) { taken.contains($0) }
        let diskName = freshDiskName(in: folder)
        let destination = folder.appendingPathComponent(diskName)
        do {
            try cipher.encryptFile(at: item.diskURL, to: destination)
            guard try encryptedFile(at: destination, matches: item.diskURL) else { throw Self.copyMismatch(item) }
            entries[diskName] = VaultIndexEntry(originalName: displayName)
            try index.write(entries, in: folder, mode: sealed)
        } catch {
            // The plaintext is untouched; drop the copy so no unindexed encrypted file is left.
            removeLeftover(destination)
            throw VaultStoreError.from(error)
        }
        // The entry must be on disk before the plaintext goes; if this throws, both stay and a rerun dedupes.
        var saved = try index.read(in: folder, mode: sealed)
        guard saved[diskName]?.originalName == displayName else {
            throw VaultStoreError.io("The index entry for “\(displayName)” wasn't saved.")
        }
        guard try isCompleteEncryptedCopy(at: destination, plaintextSize: plaintextSize) else {
            // coverage-exempt-begin: unreachable: the earlier byte-for-byte verify already proves this
            // Keep the plaintext; drop the bad copy and its entry (a rerun encrypts again).
            saved.removeValue(forKey: diskName)
            try? index.write(saved, in: folder, mode: sealed)
            removeLeftover(destination)
            throw Self.copyMismatch(item)
            // coverage-exempt-end
        }
        // Their entries went with the index write above.
        try incomplete.forEach(removeFile)
        try removeFile(item.diskURL)
    }

    /// Whether an entry with the item's name already holds its exact content (an earlier run that stopped before
    /// removing the plaintext): a complete copy whose header records the plaintext's size and whose content
    /// matches byte for byte. Same-name copies that are unusable are removed from `entries` and added to
    /// `incomplete`, to be dropped with their entries (the plaintext holds the content):
    /// - an incomplete copy (its last chunk doesn't authenticate), an interrupted run's leftover;
    /// - a copy that holds the plaintext's content but whose header records a different size, so it would
    ///   open as something else.
    ///
    /// A complete copy of different content (whatever its size) is a different file and is kept.
    private func hasIdenticalCopy(
        of item: VaultItem, in folder: URL, entries: inout [String: VaultIndexEntry], incomplete: inout [URL]
    ) throws -> Bool {
        let plaintextSize = try fileSize(of: item.diskURL)
        // Every same-name entry is examined (in disk-name order, so runs are repeatable) before answering:
        // stopping at the first identical copy would leave an unusable copy visited later in the index.
        var found = false
        let sameName = entries.filter { $0.value.originalName == item.name }.keys.sorted()
        for diskName in sameName {
            // A pool per copy frees the buffers its header and last-chunk reads leave behind.
            try autoreleasepool { () throws in
                let copy = folder.appendingPathComponent(diskName)
                guard Self.isRegularFile(copy) else { return }
                guard try isCompleteEncryptedCopy(at: copy), let info = try streamInfo(of: copy) else {
                    entries.removeValue(forKey: diskName)
                    incomplete.append(copy)
                    return
                }
                if info.totalSize == plaintextSize {
                    // A further complete copy is kept as it is, as before; only the first match needs comparing.
                    if !found, try encryptedFile(at: copy, matches: item.diskURL) { found = true }
                    return
                }
                // The header's size is wrong for this content: read the copy as a plaintext-sized file.
                let asPlaintextSize = StreamInfo(totalSize: plaintextSize, chunkSize: info.chunkSize)
                if try encryptedFile(at: copy, matches: item.diskURL, info: asPlaintextSize) {
                    entries.removeValue(forKey: diskName)
                    incomplete.append(copy)
                }
            }
        }
        return found
    }

    /// Encrypts a plaintext trash item in place: the copy is staged next to it and verified, the entry is
    /// marked encrypted, then the copy replaces the file (the entry is restored if that fails).
    private func encryptTrashItem(_ item: VaultItem, mode: VaultOperationMode) throws {
        let trashName = item.diskURL.lastPathComponent
        guard
            let prepared = try prepareTrashEncryption(trashName, at: item.diskURL, mode: mode),
            var entry = prepared.map[trashName]
        else { return }
        let (map, staging) = (prepared.map, prepared.staging)
        do {
            try cipher.encryptFile(at: item.diskURL, to: staging)
            guard try encryptedFile(at: staging, matches: item.diskURL) else { throw Self.copyMismatch(item) }
        } catch {
            removeLeftover(staging)
            throw VaultStoreError.from(error)
        }
        entry.isEncrypted = true
        try replaceTrashFile(trashName, with: staging, entry: entry, map: map, mode: mode)
    }

    /// Readies the encryption of trash item `trashName`: removes a leftover staging file (an interrupted run's;
    /// the original is untouched until the final replace, so it is redone from the original), reads the
    /// item's real form, and saves a corrected entry when the item is already encrypted.
    /// - Returns: the corrected map and the staging URL, or nil when there is nothing to encrypt.
    /// - Throws: `.notFound` for an unknown trash item.
    private func prepareTrashEncryption(
        _ trashName: String, at url: URL, mode: VaultOperationMode
    ) throws -> (map: [String: VaultTrashEntry], staging: URL)? {
        let stored = try trashMap.read(mode: mode)
        guard VaultTrashMap.isItemName(trashName), let storedEntry = stored[trashName] else {
            throw VaultStoreError.notFound
        }
        let staging = Self.stagingURL(for: trashName, in: trashMap.folderURL)
        if FileManager.default.fileExists(atPath: staging.path) { try removeFile(staging) }
        // A trash item whose file is gone has nothing to encrypt; checked before any cipher or probe call.
        guard Self.isRegularFile(url) else { return nil }
        let map = try correctedTrashMap(stored)
        guard let entry = map[trashName], !entry.isEncrypted else {
            if map[trashName] != storedEntry { try trashMap.write(map, mode: mode) }
            return nil
        }
        return (map, staging)
    }

    /// The hidden staging file for encrypting trash item `trashName`.
    private static func stagingURL(for trashName: String, in trashFolder: URL) -> URL {
        trashFolder.appendingPathComponent(".\(trashName)\(stagingSuffix)")
    }

    private static let stagingSuffix = ".migrating"

    /// Saves `entry` for `trashName`, then moves `staging` over the trash file. On failure the staged file is
    /// removed and the map put back, so the trash item stays as it was.
    private func replaceTrashFile(
        _ trashName: String, with staging: URL, entry: VaultTrashEntry, map: [String: VaultTrashEntry],
        mode: VaultOperationMode
    ) throws {
        var newMap = map
        newMap[trashName] = entry
        do {
            try trashMap.write(newMap, mode: mode)
        } catch {
            removeLeftover(staging)
            throw error
        }
        do {
            _ = try FileManager.default.replaceItemAt(
                trashMap.folderURL.appendingPathComponent(trashName), withItemAt: staging)
        } catch {
            // coverage-exempt-begin: replaceItemAt failing after the same folder's map write succeeded can't be provoked
            try? trashMap.write(map, mode: mode)
            removeLeftover(staging)
            throw VaultStoreError.from(error)
            // coverage-exempt-end
        }
    }

    // MARK: - Finish

    /// The last step of an encrypt migration. Seals every index older builds left as plaintext JSON: each
    /// `.vault_map` under the root (and in folders in the trash) with ".vault_map", and `.trash/.trash_map`
    /// with ".trash_map", keeping their entries. Already-encrypted and unreadable indexes are left byte for
    /// byte; plaintext mode changes nothing. Runs without suspending, so it is one serialized step with every
    /// other index write.
    /// - Throws: `.locked` in encrypted mode without the key (before anything is written); `.io` when a
    ///   folder can't be listed or an index can't be written.
    func finishEncryption() throws {
        let mode = try beginOperation()
        guard mode.isEncrypted else { return }
        var pending = [root.diskURL] + (try subfolders(of: trashMap.folderURL))
        while let folder = pending.popLast() {
            let url = folder.appendingPathComponent(VaultIndex.fileName)
            if let entries = Self.plaintextJSON([String: VaultIndexEntry].self, at: url) {
                try VaultIndex.writeSealedJSON(
                    entries, to: url, context: VaultIndex.fileName, cipher: cipher, mode: mode)
            }
            pending += try subfolders(of: folder)
        }
        if let entries = Self.plaintextJSON([String: VaultTrashEntry].self, at: trashMap.url) {
            try trashMap.write(entries, mode: mode)
        }
    }

    /// The value decoded from the file at `url` when it is plaintext JSON of that type; nil when it is
    /// absent, unreadable, encrypted or anything else.
    private static func plaintextJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The non-hidden folders directly in `folder` (none when `folder` doesn't exist).
    /// - Throws: `.io` when an existing folder can't be listed.
    private func subfolders(of folder: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: .skipsHiddenFiles)
        } catch {
            throw VaultStoreError.from(error)
        }
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    func keyMatchesVault() -> Bool {
        let url = root.diskURL.appendingPathComponent(VaultIndex.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        // A plaintext index reads without a key (nothing encrypted to check); an encrypted one needs the key
        // that sealed it. Any read failure is the answer "doesn't match".
        let mode = VaultOperationMode(isEncrypted: true, keyLoaded: keyStore.isKeyLoaded)
        return (try? index.read(in: root.diskURL, mode: mode)) != nil
    }

    // MARK: - Content checks

    /// Whether the encrypted file at `url` decrypts, chunk by chunk, to exactly the bytes of the file at
    /// `plainURL`. A damaged or different copy gives false.
    /// - Throws: `.locked` without the key, or the read error of either file, so "couldn't check" is never
    ///   taken for "different".
    /// - Parameter info: the stream layout to read `url` with; its own header's when nil.
    private func encryptedFile(at url: URL, matches plainURL: URL, info layout: StreamInfo? = nil) throws -> Bool {
        let plain: FileHandle
        do {
            // Opened first so an unreadable file throws instead of counting as different.
            try Self.readFirstByte(of: url)
            plain = try FileHandle(forReadingFrom: plainURL)
        } catch {
            throw VaultStoreError.from(error)
        }
        defer { try? plain.close() }
        guard let info = try layout ?? streamInfo(of: url), info.totalSize == (try fileSize(of: plainURL)) else {
            return false
        }
        for chunk in 0..<Self.chunkCount(info) {
            // Each chunk's buffers (decrypted and read) are autoreleased; a pool per chunk frees them before the
            // next, so a large file is checked in about two chunks of memory instead of several times its size.
            let chunkMatches = try autoreleasepool { () throws -> Bool in
                let decrypted: Data
                do {
                    decrypted = try cipher.decryptChunk(chunk, of: url, info: info)
                } catch VaultCryptoError.noKeyLoaded {
                    throw VaultStoreError.locked
                } catch {
                    return false
                }
                let original: Data
                do {
                    original = try plain.read(upToCount: decrypted.count) ?? Data()
                } catch {
                    // coverage-exempt-begin: read on an open handle can't fail
                    throw VaultStoreError.from(error)
                    // coverage-exempt-end
                }
                return original == decrypted
            }
            guard chunkMatches else { return false }
        }
        // The plaintext must end here too.
        do {
            return try plain.read(upToCount: 1)?.isEmpty ?? true
        } catch {
            // coverage-exempt-begin: read on an open handle can't fail
            throw VaultStoreError.from(error)
        }
        // coverage-exempt-end
    }

    /// Whether `url` holds a complete encrypted copy of a `plaintextSize`-byte file: the header records that
    /// size and the last chunk authenticates with the loaded key.
    /// - Throws: `.locked` without the key.
    private func isCompleteEncryptedCopy(at url: URL, plaintextSize: Int) throws -> Bool {
        guard let info = try streamInfo(of: url), info.totalSize == plaintextSize else { return false }
        let count = Self.chunkCount(info)
        guard count > 0 else { return true }
        do {
            _ = try cipher.decryptChunk(count - 1, of: url, info: info)
            return true
        } catch VaultCryptoError.noKeyLoaded {
            throw VaultStoreError.locked
        } catch {
            return false
        }
    }

    /// Whether `url` is a complete encrypted file: its header reads and its last chunk authenticates.
    /// - Throws: `.locked` without the key.
    private func isCompleteEncryptedCopy(at url: URL) throws -> Bool {
        guard let info = try streamInfo(of: url) else { return false }
        return try isCompleteEncryptedCopy(at: url, plaintextSize: info.totalSize)
    }

    /// The file's stream header, or nil when it isn't a readable encrypted file.
    /// - Throws: `.locked` without the key.
    private func streamInfo(of url: URL) throws -> StreamInfo? {
        do {
            return try cipher.streamInfo(of: url)
        } catch VaultCryptoError.noKeyLoaded {
            throw VaultStoreError.locked
        } catch {
            return nil
        }
    }

    private static func chunkCount(_ info: StreamInfo) -> Int {
        guard info.chunkSize > 0, info.totalSize > 0 else { return 0 }
        return (info.totalSize + info.chunkSize - 1) / info.chunkSize
    }

    private static func copyMismatch(_ item: VaultItem) -> VaultStoreError {
        .io("The encrypted copy of “\(item.name)” doesn't match the original.")
    }

    // MARK: - File helpers

    private func fileSize(of url: URL) throws -> Int {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? Int else { throw VaultStoreError.io("The file size can't be read.") }
            return size
        } catch {
            // coverage-exempt-begin: stat failing after an existence check can't be provoked
            throw VaultStoreError.from(error)
        }
        // coverage-exempt-end
    }

    private func removeFile(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw VaultStoreError.from(error)
        }
    }

    private static func readFirstByte(of url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = try handle.read(upToCount: 1)
    }

    /// Whether `url` is a regular file right now (a symlink is not followed). Asked of the file system each
    /// time: a `URL`'s cached resource values can still describe a file that has since been removed.
    static func isRegularFile(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }
}
