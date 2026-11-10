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

    func sweepOrphans() {
        guard let mode = try? beginOperation(), mode.isEncrypted, mode.keyLoaded else { return }
        var pending = [root.diskURL]
        while let folder = pending.popLast() {
            guard
                let urls = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { continue }
            // Subfolders have their own index and are judged on their own, whatever this folder's index is.
            let entries = sweepableEntries(in: folder, mode: mode)
            for url in urls {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    pending.append(url)
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
        }
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
