import Foundation

/// The live `VaultTransferring`: copies each file through the source's `open` (decrypting) and the target's
/// `addFile` (encrypting when the target is encrypted), recreating folders, and removes originals only once their
/// copy exists.
struct LiveVaultTransfer: VaultTransferring {
    /// The Pro entitlement; without it the target's free-tier file limit applies.
    private let pro: any ProUnlocking

    /// - Parameter pro: the Pro entitlement, read through its thread-safe `isUnlockedNow`.
    init(pro: any ProUnlocking) {
        self.pro = pro
    }

    /// Transfers `items` into `target`'s root. Throws `VaultTransferError` before anything is written (see
    /// `TransferPlan.make`), or `CancellationError` when the task is cancelled (checked before each file; what is
    /// done stays done). Failures of single items are counted in the result, not thrown.
    func transfer(
        _ items: [VaultItem],
        from source: any VaultStoring,
        to target: any VaultStoring,
        removingOriginals: Bool,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TransferResult {
        let plan = try await TransferPlan.make(items, from: source, to: target, isPro: pro.isUnlockedNow)
        var run = TransferRun(
            source: source, target: target, total: plan.totalFiles, progress: progress)
        var done = 0
        var failed = 0
        for entry in plan.entries {
            let copied = try await run.copy(entry, into: target.root)
            var succeeded = copied
            if copied && removingOriginals {
                // The whole copy (a file, or a folder with everything in it) exists in the target now.
                do {
                    try await source.remove(entry.item)
                } catch {
                    succeeded = false
                }
            }
            if succeeded { done += 1 } else { failed += 1 }
        }
        return TransferResult(done: done, failed: failed)
    }
}

/// The copying part of one transfer, keeping the count of files processed for `progress`.
private struct TransferRun {
    let source: any VaultStoring
    let target: any VaultStoring
    let total: Int
    let progress: @Sendable (Int, Int) -> Void
    private(set) var processed = 0

    init(
        source: any VaultStoring, target: any VaultStoring, total: Int,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) {
        self.source = source
        self.target = target
        self.total = total
        self.progress = progress
    }

    /// Copies `entry` into `directory` of the target. Returns whether everything in it was copied; a failure inside
    /// a folder doesn't stop its other files.
    /// - Throws: `CancellationError` when the task was cancelled before a file.
    mutating func copy(_ entry: TransferPlan.Entry, into directory: VaultDirectory) async throws -> Bool {
        switch entry {
        case .file(let item):
            try Task.checkCancellation()
            let copied = await copyFile(item, into: directory)
            processed += 1
            progress(processed, total)
            return copied
        case .folder(let item, let children):
            let created: VaultDirectory
            do {
                guard let folder = try await target.createFolder(named: item.name, in: directory).asDirectory else {
                    throw VaultStoreError.io("Created folder is not a directory")
                }
                created = folder
            } catch {
                // None of the folder's files can be copied; count them as processed so progress still completes.
                let skipped = entry.fileCount
                if skipped > 0 {
                    processed += skipped
                    progress(processed, total)
                }
                return false
            }
            var allCopied = true
            for child in children {
                let copied = try await copy(child, into: created)
                allCopied = allCopied && copied
            }
            return allCopied
        }
    }

    /// Opens `item` from the source and adds it to `directory` of the target. A decrypted temporary copy (of an
    /// encrypted item) is removed afterwards, whether the add worked or not.
    private func copyFile(_ item: VaultItem, into directory: VaultDirectory) async -> Bool {
        let url: URL
        do {
            url = try await source.open(item)
        } catch {
            return false
        }
        defer {
            if item.isEncrypted { source.removeTemporary(url) }
        }
        do {
            _ = try await target.addFile(from: url, named: item.name, to: directory)
            return true
        } catch {
            return false
        }
    }
}
