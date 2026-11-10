import Foundation

/// How many top-level items a transfer moved or copied, and how many failed.
struct TransferResult: Sendable, Equatable, Hashable {
    let done: Int
    let failed: Int
}

/// Errors that stop a transfer before anything is written.
enum VaultTransferError: Error, Equatable, Sendable {
    case limitReached, sameVault
}

/// User-facing text for each error, shown in alerts through `localizedDescription`.
extension VaultTransferError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .limitReached: "The other vault would have more than 100 files."
        case .sameVault: "These items are already in this vault."
        }
    }
}

/// Moves or copies items from one vault to another, decrypting or encrypting on the way.
protocol VaultTransferring: Sendable {
    /// Transfers `items` from `source` into `target`'s root; with `removingOriginals`, each original is removed
    /// once its copy is complete. `progress(done, total)` is called after each file.
    func transfer(
        _ items: [VaultItem],
        from source: any VaultStoring,
        to target: any VaultStoring,
        removingOriginals: Bool,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TransferResult
}
