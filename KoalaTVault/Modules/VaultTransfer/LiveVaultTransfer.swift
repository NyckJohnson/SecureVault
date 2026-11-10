import Foundation

/// The live `VaultTransferring` (feature multiple-vaults-duress-password; built in VaultTransfer unit 1).
struct LiveVaultTransfer: VaultTransferring {
    func transfer(
        _ items: [VaultItem],
        from source: any VaultStoring,
        to target: any VaultStoring,
        removingOriginals: Bool,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TransferResult {
        fatalError("Not implemented: LiveVaultTransfer.transfer")
    }
}
