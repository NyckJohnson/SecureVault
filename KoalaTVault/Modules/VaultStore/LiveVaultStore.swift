import Foundation

/// The live `VaultStoring`: the vault folder on disk, with per-folder `.vault_map` indexes.
///
/// An actor, so every index read-modify-write runs as one serialized step: its operations do all their
/// work synchronously, without suspending, so concurrent imports, moves and migration steps never
/// interleave and never lose an index entry.
///
/// One store per vault: the root's display name and whether the vault is encrypted are fixed at init
/// (never "a key happens to be loaded"). Each operation checks for the key once at its start; in encrypted
/// mode with no key, operations throw `.locked` before changing anything, and nothing is ever written in
/// plaintext instead.
actor LiveVaultStore: VaultStoring {
    nonisolated let root: VaultDirectory

    nonisolated let isEncrypted: Bool

    let keyStore: any MasterKeyStoring
    let cipher: any FileCipher
    /// The folder the store's own temporary folder is created in (the app's temp folder in the app).
    nonisolated let temporaryRoot: URL
    /// The per-folder index reader and writer.
    let index: VaultIndex

    /// A store over the vault folder `root`, named `name` (the root's display name), encrypted or not
    /// for its whole life as `isEncrypted` says, writing temporary files under `temporaryRoot`.
    init(
        root: URL,
        name: String,
        isEncrypted: Bool,
        keyStore: any MasterKeyStoring,
        cipher: any FileCipher,
        temporaryRoot: URL
    ) {
        let directory = VaultDirectory(name: name, diskURL: root, rootURL: root)
        self.root = directory
        self.isEncrypted = isEncrypted
        self.keyStore = keyStore
        self.cipher = cipher
        self.temporaryRoot = temporaryRoot
        self.index = VaultIndex(cipher: cipher, rootURL: root, rootName: directory.name)
    }

    // MARK: - Operation mode

    /// Checks for the key once, at the start of an operation, with the store's fixed encryption flag.
    /// - Throws: `.locked` in encrypted mode with no key loaded.
    func beginOperation() throws -> VaultOperationMode {
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
            try data.write(to: plaintext, options: .completeFileProtection)
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
}
