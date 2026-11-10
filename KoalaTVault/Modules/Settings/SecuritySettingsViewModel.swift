import Combine
import Foundation

/// What the security settings screen is asking the user.
enum SecuritySettingsPrompt: Sendable, Equatable {
    /// Confirm deleting the open vault by typing its password.
    case deleteVault
}

extension BiometricKind {
    /// The biometric name the settings rows show; "Biometrics" on a device without biometric hardware.
    fileprivate var settingsDisplayName: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .none: "Biometrics"
        }
    }
}

/// The logic of the security settings screen for the open vault: the Pro row, the Vault section (Change
/// Password, the biometric switch, Delete This Vault; only for an encrypted vault) and Storage.
///
/// Settings is built for one open vault: the vault is read once, when this is made.
@MainActor
final class SecuritySettingsViewModel: ObservableObject {
    /// The title of the prompt that confirms deleting the vault.
    static let deleteVaultTitle = "Delete This Vault?"

    /// True when Pro is unlocked.
    @Published private(set) var isProUnlocked: Bool
    /// True when the open vault uses biometrics (the switch's state).
    @Published private(set) var usesBiometrics: Bool
    /// The question to put to the user, if any.
    @Published private(set) var prompt: SecuritySettingsPrompt?
    /// True while a password change, a biometric change or a deletion is in progress.
    @Published private(set) var isBusy = false

    private let lock: any VaultLocking
    private let pro: any ProUnlocking
    private let vault: OpenVault
    private weak var alerts: (any AlertPresenting)?
    private let onVaultDeleted: @MainActor () -> Void

    /// - Parameters:
    ///   - lock: the vaults; `current` is the vault these settings are for.
    ///   - pro: the "Unlock Pro" entitlement.
    ///   - alerts: shows errors and successes (held weakly; usually the view controller that owns this).
    ///   - onVaultDeleted: called once the open vault has been deleted, so Settings can report it is done.
    init(
        lock: any VaultLocking, pro: any ProUnlocking, alerts: any AlertPresenting,
        onVaultDeleted: @escaping @MainActor () -> Void
    ) {
        self.lock = lock
        self.pro = pro
        self.alerts = alerts
        self.onVaultDeleted = onVaultDeleted
        vault = lock.current
        isProUnlocked = pro.isUnlocked
        usesBiometrics = lock.currentUsesBiometrics
    }

    // MARK: - Rows

    /// The Pro row's title.
    var proTitle: String { isProUnlocked ? "Pro Unlocked" : "Upgrade to Pro" }

    /// True when the Vault section shows: the open vault is encrypted.
    var showsVaultSection: Bool { vault.isEncrypted }

    /// The Vault section's title: the vault's name.
    var vaultSectionTitle: String { vault.name }

    /// True when the biometric switch shows.
    var showsBiometricSwitch: Bool { vault.isEncrypted && lock.biometricsAvailable }

    /// The biometric switch's title, e.g. "Use Face ID".
    var biometricTitle: String { "Use \(lock.biometricKind.settingsDisplayName)" }

    /// The message of the prompt that confirms deleting the vault.
    var deleteVaultMessage: String {
        "Everything in \"\(vault.name)\" will be erased. This can't be undone. Enter the vault's password to confirm."
    }

    /// Follows the Pro entitlement until the calling task is cancelled.
    func observeProUpdates() async {
        let updates = pro.unlockedUpdates()
        // The stream yields changes only, so catch one made before subscribing.
        isProUnlocked = pro.isUnlocked
        for await unlocked in updates {
            isProUnlocked = unlocked
        }
    }

    /// Re-reads the biometric state. Call on appearing.
    func reload() {
        usesBiometrics = lock.currentUsesBiometrics
    }

    // MARK: - Biometrics

    /// The user flipped the biometric switch. An error is shown, and the switch shows the real state afterwards.
    func setUsesBiometrics(_ enabled: Bool) async {
        isBusy = true
        defer {
            usesBiometrics = lock.currentUsesBiometrics
            isBusy = false
        }
        do {
            try await lock.setUsesBiometrics(enabled)
        } catch {
            alerts?.showError(error)
        }
    }

    // MARK: - Change Password

    /// The user asked to change the password.
    func changePassword(current: String, new: String, confirm: String) async {
        guard !new.isEmpty else {
            alerts?.showError("Password cannot be empty")
            return
        }
        guard new == confirm else {
            alerts?.showError("Passwords do not match")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await lock.changePassword(current: current, new: new)
            alerts?.showSuccess("Password changed successfully")
        } catch VaultLockError.wrongPassword {
            alerts?.showError("Current password is incorrect")
        } catch VaultLockError.passwordInUse {
            alerts?.showError("Choose a different password.")
        } catch {
            alerts?.showError(error)
        }
    }

    // MARK: - Delete This Vault

    /// The user chose Delete This Vault: ask for the vault's password.
    func requestDeleteVault() {
        guard vault.isEncrypted else { return }
        prompt = .deleteVault
    }

    /// The user dismissed the current prompt.
    func cancelPrompt() {
        prompt = nil
    }

    /// The user confirmed deleting the vault with `password`. An empty password is ignored.
    func confirmDeleteVault(password: String) async {
        guard prompt == .deleteVault else { return }
        prompt = nil
        guard !password.isEmpty else { return }
        isBusy = true
        do {
            try await lock.deleteCurrentVault(password: password)
            isBusy = false
            onVaultDeleted()
        } catch VaultLockError.wrongPassword {
            isBusy = false
            alerts?.showError("Incorrect password")
        } catch {
            isBusy = false
            alerts?.showError(error)
        }
    }
}
