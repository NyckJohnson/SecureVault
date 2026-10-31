import Foundation

/// Prepares vault items for sharing and saves them to the photo library, through the vault store.
struct LiveVaultExporter: VaultExporting {
    private let store: any VaultStoring
    private let photoSaver: PhotoLibrarySaver

    init(store: any VaultStoring, photoSaver: PhotoLibrarySaver) {
        self.store = store
        self.photoSaver = photoSaver
    }

    @concurrent
    func prepareForSharing(_ items: [VaultItem]) async throws -> ExportBundle {
        guard !items.isEmpty else { throw ExportError.nothingToExport }

        var urls: [URL] = []
        var tempFolder: URL?
        do {
            for item in items {
                try Task.checkCancellation()
                if try await needsDecryptedCopy(item) {
                    let folder = try tempFolder ?? store.makeTempDirectory()
                    tempFolder = folder
                    urls.append(try await writeDecryptedCopy(of: item, into: folder))
                } else {
                    urls.append(item.diskURL)
                }
            }
            // Inside the `do`, so cancellation arriving after the last item still removes the copies.
            try Task.checkCancellation()
        } catch {
            if let tempFolder { store.removeTemporary(tempFolder) }
            throw error
        }

        // Only the store temp folder is ever removed; plaintext disk URLs are not touched.
        return ExportBundle(urls: urls) { [store, tempFolder] in
            if let tempFolder { store.removeTemporary(tempFolder) }
        }
    }

    func saveToPhotos(_ items: [VaultItem]) async throws -> PhotoSaveResult {
        try await photoSaver.save(items)
    }

    func canSaveToPhotos(_ items: [VaultItem]) -> Bool {
        items.contains(where: PhotoLibrarySaver.isSavable)
    }

    /// True for an encrypted item, or a folder with an encrypted item anywhere inside it.
    private func needsDecryptedCopy(_ item: VaultItem) async throws -> Bool {
        if item.isEncrypted { return true }
        guard let directory = item.asDirectory else { return false }
        for child in try await store.contents(of: directory, sortedBy: .name, .ascending) {
            try Task.checkCancellation()
            let childNeedsCopy = try await needsDecryptedCopy(child)
            if childNeedsCopy { return true }
        }
        return false
    }

    /// Writes the item's plaintext under its safe display name into `folder`, recursing through folders.
    /// Each folder `open` makes is removed as soon as its copy has moved out, so `folder` is the only
    /// temp folder left to clean up. Thrown errors leave partial output in `folder` for the caller to remove.
    /// - Throws: `VaultStoreError.invalidName` if the name would still land outside `folder`.
    private func writeDecryptedCopy(of item: VaultItem, into folder: URL) async throws -> URL {
        let target = folder.appendingPathComponent(Self.freeName(for: Self.safeName(item.name), in: folder))
        // A second check on top of `safeName`: nothing may be written anywhere but directly in `folder`.
        let parent = target.standardizedFileURL.deletingLastPathComponent()
        guard parent.path == folder.standardizedFileURL.path else { throw VaultStoreError.invalidName }
        if let directory = item.asDirectory {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for child in try await store.contents(of: directory, sortedBy: .name, .ascending) {
                try Task.checkCancellation()
                _ = try await writeDecryptedCopy(of: child, into: target)
            }
        } else if item.isEncrypted {
            let opened = try await store.open(item)
            defer { store.removeTemporary(opened.deletingLastPathComponent()) }
            try FileManager.default.moveItem(at: opened, to: target)
        } else {
            try FileManager.default.copyItem(at: item.diskURL, to: target)
        }
        return target
    }

    /// `name` made safe to use as one path component, since it comes from an index that may be crafted
    /// or corrupted: "/" becomes "-", leading dots are removed, and an empty result becomes "file".
    private static func safeName(_ name: String) -> String {
        let slashless = name.replacingOccurrences(of: "/", with: "-")
        let trimmed = String(slashless.drop { $0 == "." })
        return trimmed.isEmpty ? "file" : trimmed
    }

    /// `name`, or `name` with " 1", " 2"... before the extension if `folder` already has it, so two
    /// items with the same name in one export both survive.
    private static func freeName(for name: String, in folder: URL) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = name
        var counter = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }
}
