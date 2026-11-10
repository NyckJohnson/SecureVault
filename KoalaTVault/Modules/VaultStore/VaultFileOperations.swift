import Foundation

/// Creating, adding, moving, copying and renaming items.
///
/// Each operation runs without suspending, so its index read-modify-write is one serialized step on the
/// actor. Where a file and an index both change, the order is chosen so a failure part-way leaves the
/// item findable in exactly one place and never leaves an unindexed encrypted file behind.
extension LiveVaultStore {
    // MARK: - Create

    func createFolder(named name: String, in directory: VaultDirectory) throws -> VaultItem {
        try VaultNaming.validateUserName(name)
        let mode = try beginOperation()
        let taken = try takenNames(in: directory.diskURL, mode: mode)
        let folderName = VaultNaming.resolvedName(for: name) { candidate in
            taken.contains(candidate) || exists(candidate, in: directory.diskURL)
        }
        do {
            try FileManager.default.createDirectory(
                at: directory.diskURL.appendingPathComponent(folderName, isDirectory: true),
                withIntermediateDirectories: false)
        } catch {
            throw VaultStoreError.from(error)
        }
        return try makeItem(diskName: folderName, in: directory, displayName: folderName, isEncrypted: false)
    }

    func createDocument(named name: String, in directory: VaultDirectory) throws -> VaultItem {
        try VaultNaming.validateUserName(name)
        let mode = try beginOperation()
        let staging = try makeTempDirectory()
        // Best-effort cleanup of the empty staged file; the outcome of the add is what's reported.
        defer { try? FileManager.default.removeItem(at: staging) }
        let empty = staging.appendingPathComponent("empty")
        do {
            try Data().write(to: empty, options: .completeFileProtection)
        } catch {
            // coverage-exempt-begin: write into a just-created temp folder can't fail
            throw VaultStoreError.from(error)
            // coverage-exempt-end
        }
        return try insertFile(from: empty, named: VaultNaming.documentName(for: name), in: directory, mode: mode)
    }

    func addFile(from source: URL, named name: String, to directory: VaultDirectory) throws -> VaultItem {
        try VaultNaming.validate(name)
        let mode = try beginOperation()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue,
            FileManager.default.isReadableFile(atPath: source.path)
        else {
            throw VaultStoreError.io("The file to add can't be read.")
        }
        return try insertFile(from: source, named: name, in: directory, mode: mode)
    }

    /// Adds a copy of `source` as `name` (numbered on conflict): in encrypted mode encrypted as a new
    /// `<UUID>` and then indexed, removing the file again if the index write fails; otherwise copied.
    private func insertFile(
        from source: URL, named name: String, in directory: VaultDirectory, mode: VaultOperationMode
    ) throws -> VaultItem {
        var entries = try index.read(in: directory.diskURL, mode: mode)
        let taken = try takenNames(in: directory.diskURL, entries: entries)
        guard mode.isEncrypted else {
            let fileName = VaultNaming.resolvedName(for: name) { candidate in
                taken.contains(candidate) || exists(candidate, in: directory.diskURL)
            }
            do {
                try FileManager.default.copyItem(at: source, to: directory.diskURL.appendingPathComponent(fileName))
            } catch {
                throw Self.addError(error)
            }
            return try makeItem(diskName: fileName, in: directory, displayName: fileName, isEncrypted: false)
        }
        let displayName = VaultNaming.resolvedName(for: name) { taken.contains($0) }
        let diskName = freshDiskName(in: directory.diskURL)
        let destination = directory.diskURL.appendingPathComponent(diskName)
        do {
            try cipher.encryptFile(at: source, to: destination)
        } catch {
            removeLeftover(destination)
            throw Self.addError(error)
        }
        entries[diskName] = VaultIndexEntry(originalName: displayName)
        do {
            try index.write(entries, in: directory.diskURL, mode: mode)
        } catch {
            removeLeftover(destination)
            throw error
        }
        return try makeItem(diskName: diskName, in: directory, displayName: displayName, isEncrypted: true)
    }

    /// A read failure of the source is `.io`, never `.notFound` (the item that's missing is outside the vault).
    private static func addError(_ error: any Error) -> VaultStoreError {
        let mapped = VaultStoreError.from(error)
        return mapped == .notFound ? .io(error.localizedDescription) : mapped
    }

    // MARK: - Move

    func move(_ item: VaultItem, to directory: VaultDirectory) throws {
        let mode = try beginOperation()
        try requireExists(item.diskURL)
        let sourceFolder = item.diskURL.deletingLastPathComponent()
        if Self.samePath(sourceFolder, directory.diskURL) { return }
        if item.isDirectory, Self.isSameOrInside(directory.diskURL, item.diskURL) {
            throw VaultStoreError.moveIntoItself
        }
        let diskName = item.diskURL.lastPathComponent
        guard item.isEncrypted else {
            let taken = try takenNames(in: directory.diskURL, mode: mode)
            let name = VaultNaming.resolvedName(for: diskName) { candidate in
                taken.contains(candidate) || exists(candidate, in: directory.diskURL)
            }
            do {
                try FileManager.default.moveItem(at: item.diskURL, to: directory.diskURL.appendingPathComponent(name))
            } catch {
                throw VaultStoreError.from(error)
            }
            return
        }
        try moveEncrypted(item, diskName: diskName, from: sourceFolder, to: directory, mode: mode)
    }

    /// Target index first, then the file, then the source index: until the file moves the item is listed
    /// only in its source; after, only in the target (a stale source entry for a missing file isn't listed).
    /// If that last source-index write fails, this throws although the move took effect: the item is
    /// already listed in the target (and only there), and the stale source entry names no file.
    private func moveEncrypted(
        _ item: VaultItem, diskName: String, from sourceFolder: URL, to directory: VaultDirectory,
        mode: VaultOperationMode
    ) throws {
        var sourceEntries = try index.read(in: sourceFolder, mode: mode)
        let targetEntries = try index.read(in: directory.diskURL, mode: mode)
        let taken = try takenNames(in: directory.diskURL, entries: targetEntries)
        // Without a source entry (the index changed since listing) keep the listed name, so the file is
        // never left unindexed for the orphan sweep.
        let originalName = sourceEntries[diskName]?.originalName ?? item.name
        let displayName = VaultNaming.resolvedName(for: originalName) { taken.contains($0) }
        let targetDiskName = exists(diskName, in: directory.diskURL) ? freshDiskName(in: directory.diskURL) : diskName
        var newTargetEntries = targetEntries
        newTargetEntries[targetDiskName] = VaultIndexEntry(originalName: displayName)
        try index.write(newTargetEntries, in: directory.diskURL, mode: mode)
        do {
            try FileManager.default.moveItem(
                at: item.diskURL, to: directory.diskURL.appendingPathComponent(targetDiskName))
        } catch {
            // Undo the target entry; if that fails too, the stale entry names a file that isn't there and
            // is not listed, so the item is still only in its source folder.
            try? index.write(targetEntries, in: directory.diskURL, mode: mode)
            throw VaultStoreError.from(error)
        }
        sourceEntries.removeValue(forKey: diskName)
        try index.write(sourceEntries, in: sourceFolder, mode: mode)
    }

    // MARK: - Copy

    func copy(_ item: VaultItem, to directory: VaultDirectory) throws -> VaultItem {
        let mode = try beginOperation()
        try requireExists(item.diskURL)
        if item.isDirectory, Self.isSameOrInside(directory.diskURL, item.diskURL) {
            throw VaultStoreError.moveIntoItself
        }
        var entries = try index.read(in: directory.diskURL, mode: mode)
        let taken = try takenNames(in: directory.diskURL, entries: entries)
        guard item.isEncrypted else {
            let name = VaultNaming.resolvedName(for: item.diskURL.lastPathComponent) { candidate in
                taken.contains(candidate) || exists(candidate, in: directory.diskURL)
            }
            do {
                try FileManager.default.copyItem(at: item.diskURL, to: directory.diskURL.appendingPathComponent(name))
            } catch {
                throw VaultStoreError.from(error)
            }
            return try makeItem(diskName: name, in: directory, displayName: name, isEncrypted: false)
        }
        // The ciphertext is copied as it is: an SVC5 file carries its own file ID, so the copy decrypts
        // with the same master key to the same content.
        let displayName = VaultNaming.resolvedName(for: item.name) { taken.contains($0) }
        let diskName = freshDiskName(in: directory.diskURL)
        let destination = directory.diskURL.appendingPathComponent(diskName)
        do {
            try FileManager.default.copyItem(at: item.diskURL, to: destination)
        } catch {
            removeLeftover(destination)
            throw VaultStoreError.from(error)
        }
        entries[diskName] = VaultIndexEntry(originalName: displayName)
        do {
            try index.write(entries, in: directory.diskURL, mode: mode)
        } catch {
            removeLeftover(destination)
            throw error
        }
        return try makeItem(diskName: diskName, in: directory, displayName: displayName, isEncrypted: true)
    }

    // MARK: - Remove

    /// Deletes the item for good, never into the trash. An encrypted file's index entry is removed and the
    /// index written before the file is deleted, so a failed index write deletes nothing and a failed delete
    /// restores the entry (best-effort). A folder is deleted with its whole tree, its indexes included.
    /// - Throws: `.notFound` for an unknown item or anything in the trash (that is `deletePermanently`);
    ///   `.locked` in encrypted mode without the key, before anything is deleted; `.io` when a deletion
    ///   fails part-way (what it hasn't reached is left).
    func remove(_ item: VaultItem) throws {
        let mode = try beginOperation()
        if item.deletedAt != nil || Self.isSameOrInside(item.diskURL, trashMap.folderURL) {
            throw VaultStoreError.notFound
        }
        try requireExists(item.diskURL)
        guard item.isEncrypted, !item.isDirectory else {
            try deleteFromDisk(item.diskURL)
            return
        }
        let folder = item.diskURL.deletingLastPathComponent()
        let diskName = item.diskURL.lastPathComponent
        let entries = try index.read(in: folder, mode: mode)
        guard entries[diskName] != nil else {
            try deleteFromDisk(item.diskURL)
            return
        }
        var remaining = entries
        remaining.removeValue(forKey: diskName)
        try index.write(remaining, in: folder, mode: mode)
        do {
            try deleteFromDisk(item.diskURL)
        } catch {
            // Put the entry back so the file that's still there stays listed; the delete failure is reported.
            try? index.write(entries, in: folder, mode: mode)
            throw error
        }
    }

    /// Deletes the file or folder tree at `url`; any failure is `.io` (the item existed when checked).
    private func deleteFromDisk(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let mapped = VaultStoreError.from(error)
            throw mapped == .notFound ? VaultStoreError.io(error.localizedDescription) : mapped
        }
    }

    // MARK: - Rename

    func rename(_ item: VaultItem, to name: String) throws -> VaultItem {
        try VaultNaming.validateUserName(name)
        let mode = try beginOperation()
        try requireExists(item.diskURL)
        let folderURL = item.diskURL.deletingLastPathComponent()
        let folder = VaultDirectory(name: folderURL.lastPathComponent, diskURL: folderURL, rootURL: item.rootURL)
        let diskName = item.diskURL.lastPathComponent
        var entries = try index.read(in: folderURL, mode: mode)
        let taken = try takenNames(in: folderURL, entries: entries, excluding: diskName)
        if item.isEncrypted {
            let displayName = VaultNaming.resolvedName(for: name) { taken.contains($0) }
            entries[diskName] = VaultIndexEntry(originalName: displayName)
            try index.write(entries, in: folderURL, mode: mode)
            return try makeItem(diskName: diskName, in: folder, displayName: displayName, isEncrypted: true)
        }
        let newName = VaultNaming.resolvedName(for: name) { candidate in
            candidate != diskName && (taken.contains(candidate) || exists(candidate, in: folderURL))
        }
        if newName != diskName {
            do {
                try FileManager.default.moveItem(at: item.diskURL, to: folderURL.appendingPathComponent(newName))
            } catch {
                throw VaultStoreError.from(error)
            }
        }
        return try makeItem(diskName: newName, in: folder, displayName: newName, isEncrypted: false)
    }

    // MARK: - Helpers

    /// Whether something named `name` exists in `folder`.
    func exists(_ name: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// A new `<UUID>` disk name not used in `folder`.
    func freshDiskName(in folder: URL) -> String {
        var name = UUID().uuidString
        while exists(name, in: folder) { name = UUID().uuidString }
        return name
    }

    /// Removes a file this operation created before it failed; the original failure is what's reported.
    func removeLeftover(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The path of `url`, standardized and with symlinks resolved.
    static func standardPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether both URLs name the same path.
    static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        standardPath(lhs) == standardPath(rhs)
    }

    /// Whether `url` is `folder` or somewhere inside it.
    static func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        let path = standardPath(url)
        let folderPath = standardPath(folder)
        return path == folderPath || path.hasPrefix(folderPath + "/")
    }
}
