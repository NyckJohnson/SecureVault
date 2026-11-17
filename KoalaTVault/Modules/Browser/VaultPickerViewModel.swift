import Combine
import Foundation

/// The logic of the vault picker for Move/Copy to Vault: the unencrypted vault, or a vault opened by its password
/// as the transfer target (feature multiple-vaults-duress-password; built in Browser unit 3). Nothing here, or in
/// its texts, depends on how many vaults exist.
@MainActor
final class VaultPickerViewModel: ObservableObject {
    /// The text the Use Vault button shows while a vault opens.
    static let busyMessage = "Opening…"
    /// The message for a password that opens no vault.
    static let wrongPasswordMessage = "Incorrect password"
    /// The message for the open vault's own password.
    static let sameVaultMessage = "These items are already in this vault."

    /// The password field's text.
    @Published private(set) var password = ""
    /// True while a vault opens; every input is disabled.
    @Published private(set) var isBusy = false
    /// The message to show, if the last attempt failed.
    @Published private(set) var errorMessage: String?

    /// True when the open vault is encrypted, so the unencrypted vault is offered as a target.
    let showsUnencryptedRow: Bool
    /// True for Move to Vault (the originals are removed), false for Copy to Vault.
    let isMove: Bool

    /// Called once with the chosen target, or nil for Cancel. Whoever presented the picker dismisses it.
    var onFinish: (@MainActor (OpenVault?) -> Void)?

    private let lock: any VaultLocking
    /// Set by the first report, so a double tap can't report twice.
    private var didFinish = false

    /// - Parameters:
    ///   - lock: the app's vaults.
    ///   - isMove: true for Move to Vault, false for Copy to Vault.
    init(lock: any VaultLocking, isMove: Bool) {
        self.lock = lock
        self.isMove = isMove
        showsUnencryptedRow = lock.current.isEncrypted
    }

    /// The screen's title: "Move to Vault" or "Copy to Vault".
    var title: String {
        isMove ? "Move to Vault" : "Copy to Vault"
    }

    /// The user changed the password field; any error clears.
    func passwordEdited(_ text: String) {
        password = text
        errorMessage = nil
    }

    /// "Unencrypted Vault": the unencrypted vault is the target. Only offered from an encrypted vault.
    func unencryptedTapped() {
        guard showsUnencryptedRow, !isBusy else { return }
        finish(with: lock.unencryptedVault)
    }

    /// "Use Vault": opens the vault the field's password belongs to as the target; an empty password is ignored.
    func useTapped() async {
        guard !password.isEmpty, !isBusy, !didFinish else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let target = try await lock.openTransferTarget(password: password)
            password = ""
            errorMessage = nil
            finish(with: target)
        } catch {
            password = ""
            errorMessage = Self.message(for: error)
        }
    }

    /// Cancel: no target. Ignored while a vault opens, so an opened target is never left unreported.
    func cancelTapped() {
        guard !isBusy else { return }
        finish(with: nil)
    }

    private func finish(with target: OpenVault?) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?(target)
    }

    private static func message(for error: any Error) -> String {
        switch error as? VaultLockError {
        case .wrongPassword: return wrongPasswordMessage
        case .sameVault: return sameVaultMessage
        default: return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
