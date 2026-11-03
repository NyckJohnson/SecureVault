import Combine
import Foundation

/// What the security settings screen is asking the user.
enum SecuritySettingsPrompt: Sendable, Equatable {
    /// Confirm removing the lock.
    case removeLock
    /// A new password and its confirmation, to add a lock ending in the mode.
    case newPassword(LockMode)
    /// The password of the key already on this device, to add a lock ending in the mode.
    case existingPassword(LockMode)
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

/// The logic of the security settings screen: the Pro row, the lock mode rows, Re-encrypt Everything and
/// Change Password.
///
/// A lock is never added or removed while a migration is under way: `LockMigrating.start` does nothing
/// while a run exists, so the lock would change with no migration to bring the files in line.
@MainActor
final class SecuritySettingsViewModel: ObservableObject {
    /// The title of the prompt that confirms removing the lock.
    static let removeLockTitle = "Remove Lock?"
    /// The message of the prompt that confirms removing the lock.
    static let removeLockMessage = "Your files will be decrypted and no longer protected."
    /// Why an incomplete migration left the vault on Password. It says "Face ID" on every device, as today's app does.
    private static let biometricsNotTurnedOnMessage =
        "Face ID wasn't turned on because some files aren't encrypted yet. "
        + "Use Re-encrypt Everything, then turn on Face ID."

    /// The lock mode in force.
    @Published private(set) var currentMode: LockMode
    /// True when Pro is unlocked.
    @Published private(set) var isProUnlocked: Bool
    /// True when the Re-encrypt Everything row shows: a lock and unencrypted files.
    @Published private(set) var showsReencrypt = false
    /// The question to put to the user, if any.
    @Published private(set) var prompt: SecuritySettingsPrompt?
    /// True while a password is being set or changed.
    @Published private(set) var isBusy = false
    /// The kind of the migration last started; read it in `onShowMigration` to title the screen.
    private(set) var migrationKind: MigrationKind = .encrypt

    private let lock: any VaultLocking
    private let migrator: any LockMigrating
    private let store: any VaultStoring
    private let pro: any ProUnlocking
    private weak var alerts: (any AlertPresenting)?
    private let onShowMigration: @MainActor () -> Void
    /// True from adding Password + biometric until that migration is reported finished. It lives only here:
    /// the migration runs under Password, so after a kill it resumes under Password and the vault stays Password.
    private var turnsOnBiometricsAfterMigration = false

    /// - Parameters:
    ///   - lock: the app's vault lock.
    ///   - migrator: the app's one lock migration.
    ///   - store: the vault store, for the unencrypted-file check.
    ///   - pro: the "Unlock Pro" entitlement.
    ///   - alerts: shows errors and successes (held weakly; usually the view controller that owns this).
    ///   - onShowMigration: shows the migration screen. It must create the screen's `MigrationViewModel`
    ///     before it returns, because the migration starts right afterwards.
    init(
        lock: any VaultLocking, migrator: any LockMigrating, store: any VaultStoring, pro: any ProUnlocking,
        alerts: any AlertPresenting, onShowMigration: @escaping @MainActor () -> Void
    ) {
        self.lock = lock
        self.migrator = migrator
        self.store = store
        self.pro = pro
        self.alerts = alerts
        self.onShowMigration = onShowMigration
        currentMode = lock.lockMode
        isProUnlocked = pro.isUnlocked
    }

    // MARK: - Rows

    /// The Pro row's title.
    var proTitle: String { isProUnlocked ? "Pro Unlocked" : "Upgrade to Pro" }

    /// True when the Change Password row shows.
    var showsChangePassword: Bool { currentMode != .none }

    /// A lock mode row's title.
    func title(for mode: LockMode) -> String {
        switch mode {
        case .none: "No Lock"
        case .password: "Password"
        case .passwordAndBiometrics: "Password + \(lock.biometricKind.settingsDisplayName)"
        }
    }

    /// Whether a lock mode row can be chosen.
    func isEnabled(_ mode: LockMode) -> Bool {
        mode != .passwordAndBiometrics || lock.biometricsAvailable
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

    /// Re-reads the lock mode and whether any file is unencrypted. Call on appearing.
    func reload() async {
        // Locked or unreadable counts as "nothing to re-encrypt", as the screen has always done.
        let hasUnencryptedFiles = (try? await store.hasUnencryptedFiles()) ?? false
        currentMode = lock.lockMode
        showsReencrypt = currentMode != .none && hasUnencryptedFiles
    }

    // MARK: - Choosing a lock mode

    /// The user chose a lock mode row.
    func select(_ mode: LockMode) async {
        currentMode = lock.lockMode
        guard mode != currentMode, isEnabled(mode), !refusedForMigrationUnderWay() else { return }
        if mode == .none {
            prompt = .removeLock
        } else if currentMode == .none {
            prompt = .newPassword(mode)
        } else {
            await switchMode(to: mode)
        }
    }

    /// The user dismissed the current prompt.
    func cancelPrompt() {
        prompt = nil
    }

    /// The user confirmed removing the lock.
    func confirmRemoveLock() async {
        guard prompt == .removeLock else { return }
        prompt = nil
        guard !refusedForMigrationUnderWay() else { return }
        await beginMigration(.decrypt, target: nil)
    }

    /// The user entered a new password for the lock being added.
    func submitNewPassword(_ password: String, confirm: String) async {
        guard case .newPassword(let target) = prompt else { return }
        prompt = nil
        guard !password.isEmpty else {
            alerts?.showError("Password cannot be empty")
            return
        }
        guard password == confirm else {
            alerts?.showError("Passwords do not match")
            return
        }
        await addLock(ending: target, password: password, asksForExistingPassword: true)
    }

    /// The user entered the password of the key already on this device.
    func submitExistingPassword(_ password: String) async {
        guard case .existingPassword(let target) = prompt else { return }
        prompt = nil
        await addLock(ending: target, password: password, asksForExistingPassword: false)
    }

    /// The user chose Re-encrypt Everything. The lock is already on; a pending encrypt's target is kept.
    func reencryptEverything() async {
        let pending = migrator.pending
        guard lock.lockMode != .none else { return }
        guard !hasRunUnderWay, pending?.kind != .decrypt else {
            showMigrationUnderWay()
            return
        }
        await beginMigration(.encrypt, target: pending?.kind == .encrypt ? pending?.targetLockMode : nil)
    }

    /// The migration screen reported its end. After adding Password + biometric, a full migration turns
    /// biometrics on (a failure shows the error and keeps Password) and an incomplete one says why it didn't.
    /// Every call refreshes the rows; only the first after adding the lock acts on the choice.
    func migrationFinished(completedFully: Bool) async {
        let turnsOnBiometrics = turnsOnBiometricsAfterMigration
        turnsOnBiometricsAfterMigration = false
        if turnsOnBiometrics {
            if completedFully {
                await switchMode(to: .passwordAndBiometrics)
            } else {
                alerts?.showError(Self.biometricsNotTurnedOnMessage)
            }
        }
        await reload()
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
        } catch {
            alerts?.showError(error)
        }
    }

    // MARK: - Private

    /// A run exists when the migrator would ignore a new `start`.
    private var hasRunUnderWay: Bool {
        switch migrator.phase {
        case .running, .paused, .failed: true
        case .idle, .completed: false
        }
    }

    /// Shows why the lock can't change if a migration is under way or waiting to resume.
    private func refusedForMigrationUnderWay() -> Bool {
        guard hasRunUnderWay || migrator.pending != nil else { return false }
        showMigrationUnderWay()
        return true
    }

    private func showMigrationUnderWay() {
        alerts?.showError("A migration is still in progress. Let it finish, then try again.")
    }

    private func switchMode(to mode: LockMode) async {
        do {
            try await lock.switchMode(to: mode)
        } catch {
            alerts?.showError(error)
        }
        currentMode = lock.lockMode
    }

    /// Adds the lock under the password alone, then encrypts under it. `migrationFinished` moves it to `target`
    /// if that is Password + biometric and every file was encrypted.
    private func addLock(ending target: LockMode, password: String, asksForExistingPassword: Bool) async {
        guard !refusedForMigrationUnderWay() else { return }
        isBusy = true
        do {
            try await lock.prepareToAddLock(mode: .password, password: password)
        } catch VaultLockError.existingPasswordRequired where asksForExistingPassword {
            isBusy = false
            prompt = .existingPassword(target)
            return
        } catch {
            isBusy = false
            alerts?.showError(error)
            return
        }
        isBusy = false
        await beginMigration(.encrypt, target: .password, turnsOnBiometrics: target == .passwordAndBiometrics)
    }

    /// Shows the screen first: `start` may not return until the migration ends, so `migrationFinished` can
    /// arrive before this returns.
    private func beginMigration(_ kind: MigrationKind, target: LockMode?, turnsOnBiometrics: Bool = false) async {
        migrationKind = kind
        turnsOnBiometricsAfterMigration = turnsOnBiometrics
        onShowMigration()
        await migrator.start(kind, target: target)
        currentMode = lock.lockMode
    }
}
