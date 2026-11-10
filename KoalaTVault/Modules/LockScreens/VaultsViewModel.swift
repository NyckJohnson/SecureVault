import Combine
import Foundation

/// The logic of the Vaults screen: open a vault by password or Face ID, create a vault, close the open vault
/// (feature multiple-vaults-duress-password; built in LockScreens unit 3).
@MainActor
final class VaultsViewModel: ObservableObject {
    private let lock: any VaultLocking

    /// - Parameter lock: the app's vaults.
    init(lock: any VaultLocking) {
        self.lock = lock
    }
}
