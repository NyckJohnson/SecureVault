import Foundation

/// The per-file steps of a lock migration, and the checks around it.
///
/// Every step can be interrupted and run again without losing content. For files in folders, at each point
/// either the source or a verified, indexed copy exists, and a rerun finishes the work (a leftover plaintext
/// is removed only after a byte-for-byte match; an incomplete copy is dropped with its entry).
///
/// The trash is migrated too: trash items are converted in place and keep their trash id; folders in the
/// trash are walked like any other folder. A kill between a trash item's map update and its file replace
/// leaves the entry's flag disagreeing with the file. That is harmless because a file's real form is always
/// read from its SVC5 header (`fileForm(at:)`), never from an index or trash-entry flag alone: listings,
/// migration steps and `finishDecryption` use the real form and correct the entry, and the next step on that
/// item removes its leftover hidden `.<id>.migrating` staging file and converts it from the untouched original.
///
/// Steps run without suspending, so each is one serialized step on the actor.
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

    func itemsToMigrate(toEncrypted: Bool) throws -> [VaultItem] {
        let mode = try beginOperation()
        let map = try correctedTrashMap(trashMap.read(mode: mode))
        var result: [VaultItem] = []
        try forEachListing(trash: map, mode: mode) { _, items in
            for item in items where !item.isDirectory {
                let form = try realForm(of: item)
                guard form != .orphan, (form == .encrypted) != toEncrypted else { continue }
                result.append(Self.item(item, isEncrypted: form == .encrypted))
            }
        }
        result += trashItems(map: map).filter { !$0.isDirectory && $0.isEncrypted != toEncrypted }
        return result
    }

    func hasUnencryptedFiles() throws -> Bool {
        try !itemsToMigrate(toEncrypted: true).isEmpty
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

    /// What a listed file really is for a migration.
    private enum MigrationForm {
        case encrypted, plaintext
        /// An unindexed SVC5 file: an orphan, never migrated (the sweep removes it).
        case orphan
    }

    /// A listed file's real form, judged by its header where that is conclusive: an indexed file that isn't an
    /// SVC5 file is plaintext; an unindexed SVC5 file is an orphan.
    private func realForm(of item: VaultItem) throws -> MigrationForm {
        let form = try fileForm(at: item.diskURL)
        if item.isEncrypted { return form == .plaintext ? .plaintext : .encrypted }
        return form == .encrypted ? .orphan : .plaintext
    }

    private static func item(_ item: VaultItem, isEncrypted: Bool) -> VaultItem {
        guard item.isEncrypted != isEncrypted else { return item }
        return VaultItem(
            id: item.id, name: item.name, isDirectory: item.isDirectory, dateModified: item.dateModified,
            fileSize: item.fileSize, deletedAt: item.deletedAt, diskURL: item.diskURL, rootURL: item.rootURL,
            isEncrypted: isEncrypted)
    }

    /// `map` with each trash file's `isEncrypted` set from the file's real form where its header is conclusive.
    ///
    /// Migration steps pass `strict: true`: a file whose form can't be read stops them. Listing and restore pass
    /// `strict: false`: such a file keeps its stored flag, so one unreadable trash file never hides the others.
    /// - Throws: with `strict`, `.locked` without the key, `.io` when a trash file can't be read.
    func correctedTrashMap(_ map: [String: VaultTrashEntry], strict: Bool = true) throws -> [String: VaultTrashEntry] {
        var result = map
        for (trashName, entry) in map where VaultTrashMap.isItemName(trashName) {
            let url = trashMap.folderURL.appendingPathComponent(trashName)
            guard Self.isRegularFile(url) else { continue }
            let form: FileForm
            do {
                form = try fileForm(at: url)
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
            // Keep the plaintext; drop the bad copy and its entry (a rerun encrypts again).
            saved.removeValue(forKey: diskName)
            try? index.write(saved, in: folder, mode: sealed)
            removeLeftover(destination)
            throw Self.copyMismatch(item)
        }
        // Their entries went with the index write above.
        try incomplete.forEach(removeFile)
        try removeFile(item.diskURL)
    }

    /// Whether an entry with the item's name already holds its exact content (an earlier run that stopped before
    /// removing the plaintext). Same-name copies that are incomplete are removed from `entries` and added to
    /// `incomplete`: an interrupted run's unusable copy, dropped with its entry (the plaintext holds the content).
    private func hasIdenticalCopy(
        of item: VaultItem, in folder: URL, entries: inout [String: VaultIndexEntry], incomplete: inout [URL]
    ) throws -> Bool {
        for (diskName, entry) in entries where entry.originalName == item.name {
            let copy = folder.appendingPathComponent(diskName)
            guard Self.isRegularFile(copy) else { continue }
            guard try isCompleteEncryptedCopy(at: copy) else {
                entries.removeValue(forKey: diskName)
                incomplete.append(copy)
                continue
            }
            if try encryptedFile(at: copy, matches: item.diskURL) { return true }
        }
        return false
    }

    /// Encrypts a plaintext trash item in place: the copy is staged next to it and verified, the entry is
    /// marked encrypted, then the copy replaces the file (the entry is restored if that fails).
    private func encryptTrashItem(_ item: VaultItem, mode: VaultOperationMode) throws {
        let trashName = item.diskURL.lastPathComponent
        guard
            let prepared = try prepareTrashConversion(trashName, at: item.diskURL, mode: mode, toEncrypted: true),
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

    // MARK: - Decrypt

    /// Plaintext written under the original name (" 1" on conflict) → entry removed → encrypted file removed.
    /// A decrypt failure leaves the encrypted file and its entry. An earlier run's plaintext that matches
    /// byte for byte is kept and only the encrypted file and its entry are removed.
    func migrateToDecrypted(_ item: VaultItem) throws {
        let mode = try beginOperation()
        guard mode.keyLoaded else { throw VaultStoreError.locked }
        guard !item.isDirectory else { throw VaultStoreError.io("A folder has no content to decrypt.") }
        if isTrashItem(item) {
            try decryptTrashItem(item, mode: mode)
            return
        }
        // Removed only by an earlier run, after its plaintext was in place.
        guard FileManager.default.fileExists(atPath: item.diskURL.path) else { return }
        let folder = item.diskURL.deletingLastPathComponent()
        let diskName = item.diskURL.lastPathComponent
        var entries = try index.read(in: folder, mode: mode)
        // Not listed: not an encrypted file, or an earlier run already removed its entry.
        guard let entry = entries[diskName] else { return }
        let originalName = Self.safeFileName(entry.originalName, fallback: diskName)
        let sameName = folder.appendingPathComponent(originalName)
        if Self.isRegularFile(sameName), try encryptedFile(at: item.diskURL, matches: sameName) {
            entries.removeValue(forKey: diskName)
            try index.write(entries, in: folder, mode: mode)
            try removeFile(item.diskURL)
            return
        }
        let staging = try makeTempDirectory()
        defer { removeTemporary(staging) }
        let plaintext = staging.appendingPathComponent("plain")
        do {
            try cipher.decryptFile(at: item.diskURL, to: plaintext)
        } catch {
            throw VaultStoreError.from(error)
        }
        let taken = try takenNames(in: folder, entries: entries, excluding: diskName)
        let name = VaultNaming.resolvedName(for: originalName) { candidate in
            taken.contains(candidate) || exists(candidate, in: folder)
        }
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: plaintext, to: destination)
        } catch {
            throw VaultStoreError.from(error)
        }
        entries.removeValue(forKey: diskName)
        do {
            try index.write(entries, in: folder, mode: mode)
        } catch {
            // Back to the state before: the encrypted file and its entry, no plaintext copy.
            removeLeftover(destination)
            throw error
        }
        try removeFile(item.diskURL)
    }

    /// Decrypts an encrypted trash item in place: the plaintext is staged next to it, the entry is marked
    /// plaintext, then the plaintext replaces the file (the entry is restored if that fails).
    private func decryptTrashItem(_ item: VaultItem, mode: VaultOperationMode) throws {
        let trashName = item.diskURL.lastPathComponent
        guard
            let prepared = try prepareTrashConversion(trashName, at: item.diskURL, mode: mode, toEncrypted: false),
            var entry = prepared.map[trashName]
        else { return }
        let (map, staging) = (prepared.map, prepared.staging)
        do {
            try cipher.decryptFile(at: item.diskURL, to: staging)
        } catch {
            removeLeftover(staging)
            throw VaultStoreError.from(error)
        }
        entry.isEncrypted = false
        try replaceTrashFile(trashName, with: staging, entry: entry, map: map, mode: mode)
    }

    /// Readies the conversion of trash item `trashName`: removes a leftover staging file (an interrupted run's;
    /// the original is untouched until the final replace, so it is redone from the original), reads the
    /// item's real form, and saves a corrected entry when the item is already in the wanted form.
    /// - Returns: the corrected map and the staging URL, or nil when there is nothing to convert.
    /// - Throws: `.notFound` for an unknown trash item.
    private func prepareTrashConversion(
        _ trashName: String, at url: URL, mode: VaultOperationMode, toEncrypted: Bool
    ) throws -> (map: [String: VaultTrashEntry], staging: URL)? {
        let stored = try trashMap.read(mode: mode)
        guard VaultTrashMap.isItemName(trashName), let storedEntry = stored[trashName] else {
            throw VaultStoreError.notFound
        }
        let staging = Self.stagingURL(for: trashName, in: trashMap.folderURL)
        if FileManager.default.fileExists(atPath: staging.path) { try removeFile(staging) }
        guard Self.isRegularFile(url) else { return nil }
        let map = try correctedTrashMap(stored)
        guard let entry = map[trashName], entry.isEncrypted != toEncrypted else {
            if map[trashName] != storedEntry { try trashMap.write(map, mode: mode) }
            return nil
        }
        return (map, staging)
    }

    /// The hidden staging file for converting trash item `trashName`.
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
            try? trashMap.write(map, mode: mode)
            removeLeftover(staging)
            throw VaultStoreError.from(error)
        }
    }

    // MARK: - Finish

    func finishDecryption() throws {
        let mode = try beginOperation()
        // Judged by each file's header, so an entry's wrong flag neither hides nor invents an encrypted file.
        let map = try correctedTrashMap(trashMap.read(mode: mode))
        var folders: [VaultDirectory] = []
        var remaining = 0
        try forEachListing(trash: map, mode: mode) { folder, items in
            folders.append(folder)
            for item in items where !item.isDirectory {
                if try realForm(of: item) == .encrypted { remaining += 1 }
            }
        }
        remaining += trashItems(map: map).filter { $0.isEncrypted && !$0.isDirectory }.count
        guard remaining == 0 else { throw VaultStoreError.stillEncrypted(count: remaining) }
        // Staging files of interrupted trash conversions: their originals are intact and now plaintext.
        let trashNames = (try? FileManager.default.contentsOfDirectory(atPath: trashMap.folderURL.path)) ?? []
        for name in trashNames where name.hasPrefix(".") && name.hasSuffix(Self.stagingSuffix) {
            try removeFile(trashMap.folderURL.appendingPathComponent(name))
        }
        if trashMap.exists {
            try trashMap.write(map, mode: VaultOperationMode(isEncrypted: false, keyLoaded: mode.keyLoaded))
        }
        for folder in folders {
            let url = folder.diskURL.appendingPathComponent(VaultIndex.fileName)
            if FileManager.default.fileExists(atPath: url.path) { try removeFile(url) }
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
    private func encryptedFile(at url: URL, matches plainURL: URL) throws -> Bool {
        let plain: FileHandle
        do {
            // Opened first so an unreadable file throws instead of counting as different.
            try Self.readFirstByte(of: url)
            plain = try FileHandle(forReadingFrom: plainURL)
        } catch {
            throw VaultStoreError.from(error)
        }
        defer { try? plain.close() }
        guard let info = try streamInfo(of: url), info.totalSize == (try fileSize(of: plainURL)) else {
            return false
        }
        for chunk in 0..<Self.chunkCount(info) {
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
                throw VaultStoreError.from(error)
            }
            guard original == decrypted else { return false }
        }
        // The plaintext must end here too.
        do {
            return try plain.read(upToCount: 1)?.isEmpty ?? true
        } catch {
            throw VaultStoreError.from(error)
        }
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
            throw VaultStoreError.from(error)
        }
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

    static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// `name` as a single file name: "/" replaced, and `fallback` for an empty, "." or ".." name (an index
    /// read from plaintext is unauthenticated).
    private static func safeFileName(_ name: String, fallback: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? fallback : cleaned
    }
}
