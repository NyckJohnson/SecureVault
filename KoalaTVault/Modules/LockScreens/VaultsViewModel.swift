import Combine
import Foundation

/// The logic of the Vaults screen: open a vault by password or Face ID, create a vault, close the open vault
/// (feature multiple-vaults-duress-password). Nothing here, or in its texts, depends on how many vaults exist.
@MainActor
final class VaultsViewModel: ObservableObject {
    /// The text the Open button shows while an open runs.
    static let busyMessage = "Opening…"

    /// The password field's text.
    @Published private(set) var password = ""
    /// True while an open runs; every button is disabled.
    @Published private(set) var isBusy = false
    /// The message to show, if the last attempt failed.
    @Published private(set) var errorMessage: String?
    /// True when a vault has Face ID turned on and biometrics are available.
    @Published private(set) var showsBiometricButton: Bool
    /// True only while an encrypted vault is open.
    @Published private(set) var showsCloseVaultButton: Bool

    /// Called when the screen should close: a vault opened, the open vault closed, or Cancel.
    var onDone: (@MainActor () -> Void)?
    /// Called when Create New Vault may go ahead: show the Create Vault screen.
    var onCreateVault: (@MainActor () -> Void)?
    /// Called when Create New Vault needs Pro: show the paywall.
    var onNeedsPro: (@MainActor () -> Void)?

    private let lock: any VaultLocking

    /// - Parameter lock: the app's vaults.
    init(lock: any VaultLocking) {
        self.lock = lock
        showsBiometricButton = lock.hasBiometricVault && lock.biometricsAvailable
        showsCloseVaultButton = lock.current.isEncrypted
    }

    /// The biometric button's title, naming the device's biometric kind.
    var biometricButtonTitle: String {
        "Use \(lock.biometricKind.vaultsScreenName)"
    }

    /// Keeps "Close Vault" in step with the open vault until the calling task is cancelled.
    func observeCurrentVault() async {
        showsCloseVaultButton = lock.current.isEncrypted
        for await vault in lock.currentUpdates() {
            showsCloseVaultButton = vault.isEncrypted
        }
    }

    /// The user changed the password field; any error clears.
    func passwordEdited(_ text: String) {
        password = text
        errorMessage = nil
    }

    /// Opens the vault the field's password belongs to; an empty password is ignored.
    func openTapped() async {
        guard !password.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await lock.open(password: password)
            password = ""
            errorMessage = nil
            onDone?()
        } catch {
            password = ""
            errorMessage = Self.message(for: error)
        }
    }

    /// Opens the vault that uses Face ID. No automatic prompt: only when the user taps the button.
    func biometricTapped() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await lock.openWithBiometrics()
            errorMessage = nil
            onDone?()
        } catch {
            if (error as? VaultLockError) == .biometricChanged {
                showsBiometricButton = false
            }
            errorMessage = biometricMessage(for: error)
        }
    }

    /// Create New Vault: the Create Vault screen when a vault may be created, else the paywall.
    func createTapped() async {
        guard !isBusy else { return }
        if await lock.canCreateVault() {
            onCreateVault?()
        } else {
            onNeedsPro?()
        }
    }

    /// Close Vault: closes the open vault and the screen.
    func closeVaultTapped() {
        guard !isBusy else { return }
        lock.close()
        onDone?()
    }

    /// Cancel: closes the screen.
    func cancelTapped() {
        onDone?()
    }

    private static func message(for error: any Error) -> String {
        if let error = error as? VaultLockError, error == .wrongPassword {
            return "Incorrect password"
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func biometricMessage(for error: any Error) -> String? {
        let name = lock.biometricKind.vaultsScreenName
        switch error as? VaultLockError {
        case .biometricCancelled: return nil
        case .biometryLockedOut: return "Too many attempts. Use your password."
        case .biometryNotEnrolled: return "\(name) is not set up."
        case .passcodeNotSet: return "Set a device passcode to use \(name)."
        case .biometricChanged: return "\(name) changed. Use your password."
        default: return "Biometric authentication failed"
        }
    }
}

extension BiometricKind {
    /// The biometric name the Vaults screen shows; "Biometrics" on a device without biometric hardware.
    fileprivate var vaultsScreenName: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .none: "Biometrics"
        }
    }
}
