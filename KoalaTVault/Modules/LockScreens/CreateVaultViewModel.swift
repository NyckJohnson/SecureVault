import Combine
import Foundation

/// The logic of the Create Vault screen: name, password and confirmation, then `createVault`
/// (feature multiple-vaults-duress-password; built in LockScreens unit 3).
@MainActor
final class CreateVaultViewModel: ObservableObject {
    /// The text the Create button shows while a creation runs.
    static let busyMessage = "Creating Vault…"

    /// The name field's text.
    @Published private(set) var name = ""
    /// The password field's text.
    @Published private(set) var password = ""
    /// The confirm field's text.
    @Published private(set) var confirmation = ""
    /// True while a creation runs; input and buttons are disabled.
    @Published private(set) var isBusy = false
    /// The message to show, if the last attempt failed.
    @Published private(set) var errorMessage: String?

    /// Called when the vault was created: both the Create Vault and the Vaults screens close.
    var onDone: (@MainActor () -> Void)?
    /// Called when creating a vault needs Pro: show the paywall.
    var onNeedsPro: (@MainActor () -> Void)?

    private let lock: any VaultLocking

    /// - Parameter lock: the app's vaults.
    init(lock: any VaultLocking) {
        self.lock = lock
    }

    /// The user changed the name field.
    func nameEdited(_ text: String) {
        name = text
    }

    /// The user changed the password field.
    func passwordEdited(_ text: String) {
        password = text
    }

    /// The user changed the confirm field.
    func confirmationEdited(_ text: String) {
        confirmation = text
    }

    /// Create: checks the fields, then creates and opens the vault.
    func createTapped() async {
        guard !isBusy else { return }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail("Enter a name for the vault")
            return
        }
        if password.isEmpty {
            fail("Password cannot be empty")
            return
        }
        if password != confirmation {
            fail("Passwords do not match")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await lock.createVault(name: name, password: password)
            errorMessage = nil
            onDone?()
        } catch VaultLockError.vaultLimitReached {
            clearPasswords()
            errorMessage = nil
            onNeedsPro?()
        } catch VaultLockError.passwordInUse {
            fail("Choose a different password.")
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        clearPasswords()
        errorMessage = message
    }

    private func clearPasswords() {
        password = ""
        confirmation = ""
    }
}
