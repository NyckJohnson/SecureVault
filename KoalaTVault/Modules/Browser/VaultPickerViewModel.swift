import Combine
import Foundation

/// The logic of the vault picker for Move/Copy to Vault: the unencrypted vault, or a vault opened by its password
/// as the transfer target (feature multiple-vaults-duress-password; built in Browser unit 3).
@MainActor
final class VaultPickerViewModel: ObservableObject {
    private let lock: any VaultLocking

    /// - Parameter lock: the app's vaults.
    init(lock: any VaultLocking) {
        self.lock = lock
    }
}
