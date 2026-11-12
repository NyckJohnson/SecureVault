import Foundation

/// Deletes encrypted files no index lists: copies left by a process kill between encrypting a file and
/// saving its index entry. Only files that really are SVC5 files (judged by their header) are deleted; a
/// plaintext or empty file with a UUID name is kept.
///
/// Runs only in encrypted mode with the key loaded, and deletes only in folders whose index exists and reads:
/// a folder with no index holds plaintext files, and with an unreadable index orphans can't be told from live
/// files. The trash and other hidden folders are never swept. Best-effort: it never throws.
extension LiveVaultStore {
    /// An extensionless UUID disk name, any case.
    private static let orphanNamePattern = #"^[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}$"#

    /// Sweeps one folder at a time, so housekeeping never holds up browsing: each folder (its listing, index
    /// read and deletions) is one serialized step with no suspension inside it, and the sweep suspends only
    /// between folders, where other store operations (a listing, an import, a move) may run. Each step checks
    /// the mode again and stops once the store is locked; a folder removed in between is skipped, and one
    /// changed is judged as it is when its step runs. A cancelled task stops between steps.
    func sweepOrphans() async {
        var pending = [root.diskURL]
        var isFirstStep = true
        while let folder = pending.popLast() {
            if !isFirstStep {
                await Task.yield()
                // A cancelled task (the shell cancels it on lock or a vault switch) stops between steps.
                guard !Task.isCancelled else { return }
            }
            isFirstStep = false
            guard let mode = try? beginOperation(), mode.isEncrypted, mode.keyLoaded else { return }
            pending += sweepFolder(folder, mode: mode)
        }
    }

    /// One sweep step: deletes the orphans directly in `folder` and returns its subfolders (none when the
    /// folder can't be listed, e.g. it was removed since it was queued). Never suspends.
    private func sweepFolder(_ folder: URL, mode: VaultOperationMode) -> [URL] {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        // Subfolders have their own index and are judged on their own, whatever this folder's index is.
        let entries = sweepableEntries(in: folder, mode: mode)
        var subfolders: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                subfolders.append(url)
                continue
            }
            guard let entries else { continue }
            let name = url.lastPathComponent
            guard entries[name] == nil,
                name.range(of: Self.orphanNamePattern, options: [.regularExpression, .caseInsensitive]) != nil,
                (try? fileForm(at: url)) == .encrypted
            else { continue }
            // Best-effort: an orphan that can't be removed now is removed by the next sweep.
            try? FileManager.default.removeItem(at: url)
        }
        return subfolders
    }

    /// The folder's index entries, or nil when the folder has no index or it can't be read (nothing there is
    /// swept).
    private func sweepableEntries(in folder: URL, mode: VaultOperationMode) -> [String: VaultIndexEntry]? {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(VaultIndex.fileName).path) else {
            return nil
        }
        return try? index.read(in: folder, mode: mode)
    }
}
