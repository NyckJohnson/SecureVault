import Combine
import Foundation

/// The logic of the Create Vault screen: name, password and confirmation, then `createVault`
/// (feature multiple-vaults-duress-password; built in LockScreens unit 3).
@MainActor
final class CreateVaultViewModel: ObservableObject {
    private let lock: any VaultLocking

    /// - Parameter lock: the app's vaults.
    init(lock: any VaultLocking) {
        self.lock = lock
    }
}
