import Foundation

/// What a transfer will do, worked out before anything is written: every item's tree (read through the source's
/// `contents`) and the number of files it holds. Building a plan checks that source and target differ and, without
/// Pro, that the target stays within the free-tier file limit.
struct TransferPlan: Sendable {
    /// One item of the transfer: a file, or a folder with everything inside it.
    indirect enum Entry: Sendable {
        case file(VaultItem)
        case folder(VaultItem, children: [Entry])

        /// The vault item this entry stands for.
        var item: VaultItem {
            switch self {
            case .file(let item), .folder(let item, _): item
            }
        }

        /// The files in this entry: 1 for a file, every file in the tree for a folder.
        var fileCount: Int {
            switch self {
            case .file: 1
            case .folder(_, let children): children.reduce(0) { $0 + $1.fileCount }
            }
        }
    }

    /// The top-level items, in the order given.
    let entries: [Entry]

    /// The files every item holds together; the `total` reported through `progress`.
    var totalFiles: Int { entries.reduce(0) { $0 + $1.fileCount } }

    /// Builds the plan for transferring `items` from `source` to `target`.
    /// - Throws: `VaultTransferError.sameVault` when both stores have the same root;
    ///   `VaultTransferError.limitReached` when, without Pro, the target's files plus the items' files would pass
    ///   `ProUnlock.freeFileLimit` (reaching it exactly is allowed); any error from listing a folder of the source or
    ///   counting the target's files. Nothing is written in either store.
    static func make(
        _ items: [VaultItem], from source: any VaultStoring, to target: any VaultStoring, isPro: Bool
    ) async throws -> TransferPlan {
        if source.root == target.root { throw VaultTransferError.sameVault }
        var entries: [Entry] = []
        for item in items {
            entries.append(try await entry(for: item, in: source))
        }
        let plan = TransferPlan(entries: entries)
        if !isPro {
            let existing = try await target.countFiles()
            if existing + plan.totalFiles > ProUnlock.freeFileLimit { throw VaultTransferError.limitReached }
        }
        return plan
    }

    /// The entry for `item`, listing a folder's tree recursively.
    private static func entry(for item: VaultItem, in source: any VaultStoring) async throws -> Entry {
        guard let directory = item.asDirectory else { return .file(item) }
        let contents = try await source.contents(of: directory, sortedBy: .name, .ascending)
        var children: [Entry] = []
        for child in contents {
            children.append(try await entry(for: child, in: source))
        }
        return .folder(item, children: children)
    }
}
