import Foundation

/// Opens and closes access to a picked URL; separated out so tests can see the calls.
protocol ScopedResourceAccessing: Sendable {
    /// Asks for access to `url`; returns whether it was granted and so must be stopped later.
    func start(_ url: URL) -> Bool
    /// Gives up access that `start` granted.
    func stop(_ url: URL)
}

/// Security-scoped access through the system.
struct LiveScopedResourceAccess: ScopedResourceAccessing {
    func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Brings files, folders and photos into the vault, through `VaultStoring`.
struct LiveVaultImporter: VaultImporting {
    private let store: any VaultStoring
    private let scopedAccess: any ScopedResourceAccessing
    private let limit: ImportLimit
    private let duplicateCheck: DuplicateCheck

    init(
        store: any VaultStoring,
        proUnlock: any ProUnlocking,
        scopedAccess: any ScopedResourceAccessing = LiveScopedResourceAccess()
    ) {
        self.store = store
        self.scopedAccess = scopedAccess
        limit = ImportLimit(store: store, proUnlock: proUnlock)
        duplicateCheck = DuplicateCheck(store: store)
    }

    func checkAllowed(adding count: Int) async throws {
        try await limit.checkAllowed(adding: count)
    }

    /// Checks the limit for the whole selection, then imports it. Throws `ImportError.fileLimitReached`
    /// before anything is imported, or the first error part-way (earlier files stay imported):
    /// `ImportError.unreadableSource` for a folder that can't be listed, otherwise the store's error.
    @concurrent
    func importItems(
        _ urls: [URL],
        into directory: VaultDirectory,
        progress: @Sendable (Double) -> Void
    ) async throws -> ImportResult {
        // Access is held for the whole import, since counting and importing both read the picked items.
        // A refused URL is still attempted: a file that isn't scoped needs no access to be read.
        let opened = urls.filter { scopedAccess.start($0) }
        defer { opened.forEach { scopedAccess.stop($0) } }

        let total = urls.reduce(0) { $0 + Self.importableFileCount(in: $1) }
        try await checkAllowed(adding: total)

        var run = ImportRun(total: total)
        progress(0)
        // The picked loose files share the destination, so they share its listing and its batches.
        var destination = Destination(directory: directory)
        for url in urls {
            guard let name = Self.storedName(for: url.lastPathComponent) else {
                run.failed += 1
                continue
            }
            if Self.isFolder(url) {
                try await importSubfolder(from: url, named: name, into: &destination, run: &run, progress: progress)
            } else {
                try await importFile(from: url, named: name, into: &destination, run: &run, progress: progress)
            }
        }
        try await flush(&destination, run: &run, progress: progress)
        progress(1)
        return ImportResult(imported: run.imported, skippedDuplicates: run.skippedDuplicates, failed: run.failed)
    }

    /// Checks the limit for all the photos, then imports them one at a time. A photo that fails counts in
    /// `failed` and the others carry on; a photo's temp copy is removed whatever happens to it.
    @concurrent
    func importPhotos(_ assets: [PhotoImportSource], into directory: VaultDirectory) async throws -> PhotoImportResult {
        try await checkAllowed(adding: assets.count)

        var importedAssetIDs: [String] = []
        var failed = 0
        for asset in assets {
            do {
                guard let name = Self.storedName(for: asset.suggestedName) else {
                    failed += 1
                    continue
                }
                try await importPhoto(asset, named: name, into: directory)
                if let assetID = asset.assetID { importedAssetIDs.append(assetID) }
            } catch {
                failed += 1
            }
        }
        return PhotoImportResult(importedAssetIDs: importedAssetIDs, failed: failed)
    }

    // MARK: - Files and folders

    /// Files are sent to the store in batches of at most this many, each batch one store step.
    private static let batchSize = 64

    /// The running totals of one `importItems` call.
    private struct ImportRun {
        let total: Int
        var completed = 0
        var imported = 0
        var skippedDuplicates = 0
        var failed = 0

        /// Share of the selection done so far; counted files can differ from what is found later on, so it's capped.
        mutating func complete(_ count: Int) -> Double {
            completed += count
            return min(1, Double(completed) / Double(max(total, 1)))
        }
    }

    /// One folder files are being imported into: what it held when its import started, what this import has
    /// added to it, and the files waiting to be sent to the store.
    ///
    /// The folder is listed at most once (on first need), so the work per file doesn't grow with the folder:
    /// only a name found in the listing, or one this import added, can be a duplicate and needs a store lookup.
    private struct Destination {
        let directory: VaultDirectory
        /// Lowercased names of the folder's items when it was listed; nil until it is listed. Names are
        /// compared without case, so a name that may clash on disk is still looked up (a lookup never
        /// changes the outcome, only skipping one could).
        var existingNames: Set<String>?
        /// The folder's subfolders when it was listed, by exact name: a picked folder of that name merges in.
        var existingFolders: [String: VaultDirectory] = [:]
        /// Lowercased names this import has sent (or will send) to this folder.
        var addedNames: Set<String> = []
        /// Lowercased names of the files in `pending`.
        var pendingNames: Set<String> = []
        /// Folders this import created here, by exact name, so a second pick of the same name merges into it.
        var createdFolders: [String: VaultDirectory] = [:]
        var pending: [VaultFileToAdd] = []

        init(directory: VaultDirectory, isNew: Bool = false) {
            self.directory = directory
            existingNames = isNew ? [] : nil
        }
    }

    /// Lists the destination unless it has been listed already.
    private func loadListing(_ destination: inout Destination) async throws {
        guard destination.existingNames == nil else { return }
        let items = try await store.contents(of: destination.directory, sortedBy: .name, .ascending)
        var names = Set<String>(minimumCapacity: items.count)
        for item in items {
            names.insert(item.name.lowercased())
            if let folder = item.asDirectory { destination.existingFolders[item.name] = folder }
        }
        destination.existingNames = names
    }

    /// Sends the pending files of `destination` to the store in one `addFiles` call and reports progress.
    /// A failure keeps the files the store added before it and rethrows.
    private func flush(
        _ destination: inout Destination,
        run: inout ImportRun,
        progress: @Sendable (Double) -> Void
    ) async throws {
        guard !destination.pending.isEmpty else { return }
        let batch = destination.pending
        destination.pending = []
        destination.pendingNames = []
        _ = try await store.addFiles(batch, to: destination.directory)
        run.imported += batch.count
        progress(run.complete(batch.count))
    }

    /// Queues the file for `destination`, unless the folder already has it (counted as a skipped duplicate).
    private func importFile(
        from url: URL,
        named name: String,
        into destination: inout Destination,
        run: inout ImportRun,
        progress: @Sendable (Double) -> Void
    ) async throws {
        try await loadListing(&destination)
        let key = name.lowercased()
        let mayBeDuplicate = destination.existingNames?.contains(key) == true || destination.addedNames.contains(key)
        if mayBeDuplicate {
            // The hash check must see a same-name file this import is still holding back.
            if destination.pendingNames.contains(key) {
                try await flush(&destination, run: &run, progress: progress)
            }
            if try await duplicateCheck.isDuplicate(source: url, named: name, in: destination.directory) {
                run.skippedDuplicates += 1
                progress(run.complete(1))
                return
            }
        }
        // The store resolves a clash with " 1" when the batch is added.
        destination.pending.append(autoreleasepool { VaultFileToAdd(source: url, name: name) })
        destination.pendingNames.insert(key)
        destination.addedNames.insert(key)
        if destination.pending.count >= Self.batchSize {
            try await flush(&destination, run: &run, progress: progress)
        }
    }

    /// Imports a folder into `parent`. The parent keeps its pending files (each destination has its own
    /// batches), except that a pending file of the folder's name is sent first, so the names come out as if
    /// each item were added in turn. If the folder fails, the parent's pending files are still sent, as files
    /// picked before it, and the folder's error is rethrown.
    private func importSubfolder(
        from url: URL,
        named name: String,
        into parent: inout Destination,
        run: inout ImportRun,
        progress: @Sendable (Double) -> Void
    ) async throws {
        if parent.pendingNames.contains(name.lowercased()) {
            try await flush(&parent, run: &run, progress: progress)
        }
        do {
            try await importFolder(from: url, named: name, into: &parent, run: &run, progress: progress)
        } catch {
            // The folder's error is the one to report; if sending the earlier files fails too, the store
            // keeps what it added before that failure, and the folder's error is still thrown.
            try? await flush(&parent, run: &run, progress: progress)
            throw error
        }
    }

    /// Imports a folder into `parent`, merging into a folder of the same name. The folder's own files are
    /// all sent before this returns.
    private func importFolder(
        from url: URL,
        named name: String,
        into parent: inout Destination,
        run: inout ImportRun,
        progress: @Sendable (Double) -> Void
    ) async throws {
        var destination = try await destinationFolder(named: name, in: &parent)
        let children: [URL]
        do {
            children = try autoreleasepool { try Self.visibleChildren(of: url) }
        } catch {
            throw ImportError.unreadableSource(name)
        }
        for child in children {
            let (childName, isFolder) = autoreleasepool { (child.lastPathComponent, Self.isFolder(child)) }
            if isFolder {
                try await importSubfolder(
                    from: child, named: childName, into: &destination, run: &run, progress: progress)
            } else {
                try await importFile(
                    from: child, named: childName, into: &destination, run: &run, progress: progress)
            }
        }
        try await flush(&destination, run: &run, progress: progress)
    }

    /// The existing folder of that name to merge into (from the parent's listing, or one this import made),
    /// or a new one; the store finds a free name if the name belongs to a file.
    private func destinationFolder(named name: String, in parent: inout Destination) async throws -> Destination {
        if let made = parent.createdFolders[name] {
            return Destination(directory: made)
        }
        try await loadListing(&parent)
        if let folder = parent.existingFolders[name] {
            return Destination(directory: folder)
        }
        guard let created = try await store.createFolder(named: name, in: parent.directory).asDirectory else {
            // Unreachable: createFolder always returns a folder.
            throw VaultStoreError.notFound
        }
        parent.createdFolders[name] = created
        parent.addedNames.insert(created.name.lowercased())
        return Destination(directory: created, isNew: true)
    }

    // MARK: - Photos

    private func importPhoto(
        _ asset: PhotoImportSource,
        named name: String,
        into directory: VaultDirectory
    ) async throws {
        let file = try await asset.loadFile()
        // A loader puts each photo in a temp folder of its own, so the folder goes with it.
        defer { store.removeTemporary(file.deletingLastPathComponent()) }
        _ = try await addUnlessDuplicate(file, named: name, to: directory)
    }

    // MARK: - Shared

    /// Adds the file unless the folder already has it; returns whether it was added.
    private func addUnlessDuplicate(
        _ source: URL,
        named name: String,
        to directory: VaultDirectory
    ) async throws -> Bool {
        if try await duplicateCheck.isDuplicate(source: source, named: name, in: directory) {
            return false
        }
        // The store encrypts and indexes in encrypted mode, and resolves name conflicts with " 1".
        _ = try await store.addFile(from: source, named: name, to: directory)
        return true
    }

    /// The name a picked item is stored under: its leading dots removed, since a dot-named item would be
    /// hidden from a no-lock vault's listings (and a root ".trash" would clash with the trash). Nil for a
    /// name with nothing left, which can't be stored.
    private static func storedName(for name: String) -> String? {
        let trimmed = name.drop { $0 == "." }
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    /// How many files importing this picked item will add. A name that can't be stored adds none, and a
    /// folder that can't be read counts as empty: importing it throws the real error when it is reached.
    private static func importableFileCount(in url: URL) -> Int {
        guard storedName(for: url.lastPathComponent) != nil else { return 0 }
        guard isFolder(url) else { return 1 }
        var count = 0
        var queue = [url]
        while let folder = queue.popLast() {
            // A large folder's listing is released before the next folder is read.
            autoreleasepool {
                for child in (try? visibleChildren(of: folder)) ?? [] {
                    if isFolder(child) {
                        queue.append(child)
                    } else {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    /// A folder's items, leaving out hidden ones (these are never imported, counted or reported).
    private static func visibleChildren(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
    }
}
