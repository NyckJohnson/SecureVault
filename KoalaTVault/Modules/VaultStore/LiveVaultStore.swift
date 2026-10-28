import Foundation

/// The live `VaultStoring`: the vault folder on disk, with per-folder `.vault_map` indexes.
///
/// An actor, so every index read-modify-write runs as one serialized step: its operations do all their
/// work synchronously, without suspending, so concurrent imports, moves and migration steps never
/// interleave and never lose an index entry.
///
/// Encrypted mode is `lockMode != .none`, read from preferences at the start of each operation (never
/// "a key happens to be loaded"). In encrypted mode with no key, operations throw `.locked` before
/// changing anything, and nothing is ever written in plaintext instead.
actor LiveVaultStore: VaultStoring {
    nonisolated let root: VaultDirectory

    let keyStore: any MasterKeyStoring
    let cipher: any FileCipher
    let preferences: any PreferencesStoring
    /// The folder temporary files are created under (the app's temp folder in the app).
    nonisolated let temporaryRoot: URL
    /// The per-folder index reader and writer.
    let index: VaultIndex

    /// A store over the vault folder `root`, writing temporary files under `temporaryRoot`.
    init(
        root: URL,
        keyStore: any MasterKeyStoring,
        cipher: any FileCipher,
        preferences: any PreferencesStoring,
        temporaryRoot: URL
    ) {
        let directory = VaultDirectory(name: "KoalaTVault", diskURL: root, rootURL: root)
        self.root = directory
        self.keyStore = keyStore
        self.cipher = cipher
        self.preferences = preferences
        self.temporaryRoot = temporaryRoot
        self.index = VaultIndex(cipher: cipher, rootURL: root, rootName: directory.name)
    }

    // MARK: - Operation mode

    /// Reads the lock mode and checks for the key once, at the start of an operation.
    /// - Throws: `.locked` in encrypted mode with no key loaded.
    func beginOperation() throws -> VaultOperationMode {
        let isEncrypted = preferences.lockMode != .none
        let keyLoaded = keyStore.isKeyLoaded
        if isEncrypted, !keyLoaded { throw VaultStoreError.locked }
        return VaultOperationMode(isEncrypted: isEncrypted, keyLoaded: keyLoaded)
    }

    // MARK: - Browse

    func contents(
        of directory: VaultDirectory,
        sortedBy option: SortOption,
        _ direction: SortDirection
    ) throws -> [VaultItem] {
        let mode = try beginOperation()
        let items = try listing(of: directory, mode: mode)
        return items.sorted { lhs, rhs in Self.precedes(lhs, rhs, by: option, direction) }
    }

    func findItem(named name: String, in directory: VaultDirectory) throws -> VaultItem? {
        let mode = try beginOperation()
        return try listing(of: directory, mode: mode).first { $0.name == name }
    }

    /// The folder's non-hidden entries, unsorted: mapped files under their original name with
    /// `isEncrypted` true, everything else under its disk name.
    func listing(of directory: VaultDirectory, mode: VaultOperationMode) throws -> [VaultItem] {
        let diskNames = try visibleDiskNames(in: directory.diskURL)
        let entries = try index.read(in: directory.diskURL, mode: mode)
        // An entry that vanishes between the directory read and its stat is not listed.
        return diskNames.compactMap { diskName in
            let entry = entries[diskName]
            return try? makeItem(
                diskName: diskName, in: directory, displayName: entry?.originalName ?? diskName,
                isEncrypted: entry != nil)
        }
    }

    /// Every name already used in `folder`: every disk name (hidden ones included) and every display
    /// name in its index. `excluding` names an item's disk name to leave out (with its display name).
    func takenNames(in folder: URL, mode: VaultOperationMode, excluding diskName: String? = nil) throws -> Set<String> {
        try takenNames(in: folder, entries: index.read(in: folder, mode: mode), excluding: diskName)
    }

    /// `takenNames(in:mode:excluding:)` with the folder's index already read.
    func takenNames(
        in folder: URL, entries: [String: VaultIndexEntry], excluding diskName: String? = nil
    ) throws -> Set<String> {
        var entries = entries
        var names = Set(try diskNamesThrowing(in: folder))
        if let diskName {
            names.remove(diskName)
            entries.removeValue(forKey: diskName)
        }
        names.formUnion(entries.values.map(\.originalName))
        return names
    }

    /// The item for `diskName` in `directory`, with its size and date from disk.
    func makeItem(
        diskName: String, in directory: VaultDirectory, displayName: String, isEncrypted: Bool
    ) throws -> VaultItem {
        let url = directory.diskURL.appendingPathComponent(diskName)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        } catch {
            throw VaultStoreError.from(error)
        }
        let isDirectory = values.isDirectory ?? false
        let folderPath = index.relativePath(of: directory.diskURL)
        return VaultItem(
            id: folderPath.isEmpty ? diskName : folderPath + "/" + diskName,
            name: displayName,
            isDirectory: isDirectory,
            dateModified: values.contentModificationDate ?? Date(),
            fileSize: isDirectory ? nil : (values.fileSize ?? 0),
            deletedAt: nil,
            diskURL: isDirectory ? directory.diskURL.appendingPathComponent(diskName, isDirectory: true) : url,
            rootURL: directory.rootURL,
            isEncrypted: isEncrypted)
    }

    /// Throws `.notFound` unless something exists at `url`.
    func requireExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw VaultStoreError.notFound }
    }

    private func visibleDiskNames(in folder: URL) throws -> [String] {
        try diskNamesThrowing(in: folder).filter { !$0.hasPrefix(".") }
    }

    private func diskNamesThrowing(in folder: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw VaultStoreError.from(error)
        }
    }

    /// Folders first; then by `option` (name: case-insensitive, numbers in order; type: extension then
    /// name; date modified), reversed for descending. Ties fall back to the id so the order is stable.
    private static func precedes(
        _ lhs: VaultItem, _ rhs: VaultItem, by option: SortOption, _ direction: SortDirection
    ) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        var order: ComparisonResult
        switch option {
        case .name:
            order = lhs.name.localizedStandardCompare(rhs.name)
        case .type:
            let lhsExtension = (lhs.name as NSString).pathExtension.lowercased()
            let rhsExtension = (rhs.name as NSString).pathExtension.lowercased()
            order = lhsExtension.localizedStandardCompare(rhsExtension)
            if order == .orderedSame { order = lhs.name.localizedStandardCompare(rhs.name) }
        case .dateModified:
            if lhs.dateModified == rhs.dateModified {
                order = .orderedSame
            } else {
                order = lhs.dateModified < rhs.dateModified ? .orderedAscending : .orderedDescending
            }
        }
        if order == .orderedSame { order = lhs.id.compare(rhs.id) }
        return direction == .ascending ? order == .orderedAscending : order == .orderedDescending
    }

    // MARK: - Open and write

    func open(_ item: VaultItem) throws -> URL {
        let mode = try beginOperation()
        try requireExists(item.diskURL)
        guard item.isEncrypted else { return item.diskURL }
        guard mode.keyLoaded else { throw VaultStoreError.locked }
        let folder = try makeTempDirectory()
        let destination = folder.appendingPathComponent(Self.temporaryFileName(for: item.name))
        do {
            try cipher.decryptFile(at: item.diskURL, to: destination)
        } catch {
            // Remove any partial plaintext; the decryption error is the one reported.
            try? FileManager.default.removeItem(at: folder)
            throw VaultStoreError.from(error)
        }
        return destination
    }

    func write(_ data: Data, to item: VaultItem) throws {
        let mode = try beginOperation()
        try requireExists(item.diskURL)
        guard !item.isDirectory else { throw VaultStoreError.io("A folder has no content to write.") }
        guard item.isEncrypted else {
            do {
                try data.write(to: item.diskURL, options: .atomic)
            } catch {
                throw VaultStoreError.from(error)
            }
            return
        }
        guard mode.keyLoaded else { throw VaultStoreError.locked }
        let staging = try makeTempDirectory()
        // Best-effort cleanup of the staged plaintext; the outcome of the write is what's reported.
        defer { try? FileManager.default.removeItem(at: staging) }
        let plaintext = staging.appendingPathComponent("plain")
        let sealed = staging.appendingPathComponent("sealed")
        do {
            try data.write(to: plaintext)
            try cipher.encryptFile(at: plaintext, to: sealed)
            _ = try FileManager.default.replaceItemAt(item.diskURL, withItemAt: sealed)
        } catch {
            throw VaultStoreError.from(error)
        }
    }

    /// A file name safe to use in a temp folder: the display name, or "file" if it can't be one.
    private static func temporaryFileName(for name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    // MARK: - Temp files

    nonisolated func makeTempDirectory() throws -> URL {
        let url = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw VaultStoreError.from(error)
        }
        return url
    }

    // MARK: - Unit 2 (stubs until VaultTrash / VaultMigrationSteps / OrphanSweep / VaultTempFiles)

    private static func notImplemented(_ name: String) -> VaultStoreError {
        .io("Not implemented: \(name) (VaultStore unit 2)")
    }

    func moveToTrash(_ item: VaultItem) throws { throw Self.notImplemented("moveToTrash") }
    func trashContents() throws -> [VaultItem] { throw Self.notImplemented("trashContents") }
    func restore(_ trashed: VaultItem) throws -> VaultItem { throw Self.notImplemented("restore") }
    func deletePermanently(_ trashed: VaultItem) throws { throw Self.notImplemented("deletePermanently") }
    func emptyTrash() {}  // Not implemented: emptyTrash (VaultStore unit 2)
    func purgeExpiredTrash(now: Date) throws -> Int { throw Self.notImplemented("purgeExpiredTrash") }
    func countFiles() throws -> Int { throw Self.notImplemented("countFiles") }
    func itemsToMigrate(toEncrypted: Bool) throws -> [VaultItem] { throw Self.notImplemented("itemsToMigrate") }
    func migrateToEncrypted(_ item: VaultItem) throws { throw Self.notImplemented("migrateToEncrypted") }
    func migrateToDecrypted(_ item: VaultItem) throws { throw Self.notImplemented("migrateToDecrypted") }
    func finishDecryption() throws { throw Self.notImplemented("finishDecryption") }
    func hasUnencryptedFiles() throws -> Bool { throw Self.notImplemented("hasUnencryptedFiles") }
    func keyMatchesVault() -> Bool { false }  // Not implemented: keyMatchesVault (VaultStore unit 2)
    func sweepOrphans() {}  // Not implemented: sweepOrphans (VaultStore unit 2)
    nonisolated func removeTemporary(_ url: URL) {}  // Not implemented: removeTemporary (VaultStore unit 2)
    nonisolated func removeAllTemporaryFiles() {}  // Not implemented: removeAllTemporaryFiles (VaultStore unit 2)
}
