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
        for url in urls {
            guard let name = Self.storedName(for: url.lastPathComponent) else {
                run.failed += 1
                continue
            }
            if Self.isFolder(url) {
                try await importFolder(from: url, named: name, into: directory, run: &run, progress: progress)
            } else {
                try await importFile(from: url, named: name, into: directory, run: &run, progress: progress)
            }
        }
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

    /// The running totals of one `importItems` call.
    private struct ImportRun {
        let total: Int
        var completed = 0
        var imported = 0
        var skippedDuplicates = 0
        var failed = 0

        /// Share of the selection done so far; counted files can differ from what is found later on, so it's capped.
        mutating func completeOne() -> Double {
            completed += 1
            return min(1, Double(completed) / Double(max(total, 1)))
        }
    }

    private func importFile(
        from url: URL,
        named name: String,
        into directory: VaultDirectory,
        run: inout ImportRun,
        progress: @Sendable (Double) -> Void
    ) async throws {
        if try await addUnlessDuplicate(url, named: name, to: directory) {
            run.imported += 1
        } else {
            run.skippedDuplicates += 1
        }
        progress(run.completeOne())
    }

    private func importFolder(
        from url: URL,
        named name: String,
        into directory: VaultDirectory,
        run: inout ImportRun,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let destination = try await destinationFolder(named: name, in: directory)
        let children: [URL]
        do {
            children = try Self.visibleChildren(of: url)
        } catch {
            throw ImportError.unreadableSource(name)
        }
        for child in children {
            if Self.isFolder(child) {
                try await importFolder(
                    from: child, named: child.lastPathComponent, into: destination, run: &run, progress: progress)
            } else {
                try await importFile(
                    from: child, named: child.lastPathComponent, into: destination, run: &run, progress: progress)
            }
        }
    }

    /// The existing folder of that name to merge into, or a new one; the store finds a free name if the
    /// name belongs to a file.
    private func destinationFolder(named name: String, in directory: VaultDirectory) async throws -> VaultDirectory {
        if let existing = try await store.findItem(named: name, in: directory)?.asDirectory {
            return existing
        }
        guard let created = try await store.createFolder(named: name, in: directory).asDirectory else {
            // Unreachable: createFolder always returns a folder.
            throw VaultStoreError.notFound
        }
        return created
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
            for child in (try? visibleChildren(of: folder)) ?? [] {
                if isFolder(child) {
                    queue.append(child)
                } else {
                    count += 1
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
