import Testing
import UIKit

@testable import KoalaTVault

/// Contract for the view (the code-writer must match it):
/// `SecuritySettingsViewController(lock:migrator:store:pro:onRestore:)` with `onRestore` defaulting to a no-op, shown
/// in a navigation controller. It builds its own `SecuritySettingsViewModel` (as the alerts target) and presents
/// `PaywallViewController`, `MigrationViewController` (full screen) and pushes `RecentlyDeletedViewController`.
/// Identifiers follow the journey tests: table `settings.table`; cells `upgradeToProCell`,
/// `settings.lockMode.noLockRow`, `settings.lockMode.passwordRow`, `settings.lockMode.biometricRow`,
/// `settings.lockMode.reEncryptRow`, `settings.changePasswordRow`, `settings.recentlyDeletedRow`; alert fields
/// `settings.passwordField`, `settings.confirmPasswordField`, `settings.currentPasswordField`,
/// `settings.newPasswordField`, `settings.confirmNewPasswordField`.
@MainActor
@Suite struct SettingsSecurityViewControllerTests {
    private struct Rig {
        let host: SettingsViewHost
        let lock: SettingsScriptedLock
        let migrator: MockLockMigrating
        let store: MockVaultStoring
        let pro: MockProUnlocking

        var mock: MockVaultLocking { lock.inner }
    }

    private static let table = "settings.table"

    private func makeRig(
        lockMode: LockMode = .password,
        biometricKind: BiometricKind = .faceID,
        biometricsAvailable: Bool = true,
        proUnlocked: Bool = false,
        withFiles: Bool = true,
        pending: PendingMigration? = nil,
        oldBlobPassword: String? = nil
    ) async throws -> Rig {
        let mock = MockVaultLocking(
            lockMode: lockMode, password: lockMode == .none ? oldBlobPassword : "correct horse",
            biometricKind: biometricKind,
            biometricsAvailable: biometricsAvailable)
        if lockMode != .none { try await mock.unlock(password: "correct horse") }
        let lock = SettingsScriptedLock(inner: mock)
        let migrator = MockLockMigrating(pending: pending)
        let store = MockVaultStoring(withSampleContent: withFiles)
        let pro = MockProUnlocking(isUnlocked: proUnlocked)
        let controller = SecuritySettingsViewController(lock: lock, migrator: migrator, store: store, pro: pro)
        let host = SettingsViewHost(content: UINavigationController(rootViewController: controller))
        await SettingsTestSupport.waitUntil { host.element("settings.lockMode.noLockRow") != nil }
        await SettingsTestSupport.settle()
        return Rig(host: host, lock: lock, migrator: migrator, store: store, pro: pro)
    }

    private func cell(_ id: String, _ rig: Rig) -> UITableViewCell? { rig.host.element(id) as? UITableViewCell }

    private func title(_ id: String, _ rig: Rig) -> String? {
        cell(id, rig).flatMap { SettingsViewHost.texts(in: $0).first }
    }

    private func select(_ id: String, _ rig: Rig) { rig.host.selectRow(id, inTable: Self.table) }

    // MARK: - Rows

    @Test("The Pro row is Upgrade to Pro for a free user and Pro Unlocked once unlocked")
    func proRowTitles() async throws {
        let free = try await makeRig(proUnlocked: false)
        let paid = try await makeRig(proUnlocked: true)
        #expect(title("upgradeToProCell", free) == "Upgrade to Pro")
        #expect(title("upgradeToProCell", paid) == "Pro Unlocked")
    }

    @Test("The Pro row changes live when the entitlement changes")
    func proRowIsLive() async throws {
        let rig = try await makeRig(proUnlocked: false)
        rig.pro.isUnlocked = true
        await SettingsTestSupport.waitUntil { self.title("upgradeToProCell", rig) == "Pro Unlocked" }
        #expect(title("upgradeToProCell", rig) == "Pro Unlocked")
    }

    @Test("The Pro row shows a disclosure indicator while locked and a checkmark once unlocked")
    func proRowAccessory() async throws {
        let free = try await makeRig(proUnlocked: false)
        let paid = try await makeRig(proUnlocked: true)
        #expect(cell("upgradeToProCell", free)?.accessoryType == .disclosureIndicator)
        #expect(cell("upgradeToProCell", paid)?.accessoryType == .checkmark)
    }

    @Test("The Pro row accessory changes live from disclosure indicator to checkmark")
    func proRowAccessoryIsLive() async throws {
        let rig = try await makeRig(proUnlocked: false)
        #expect(cell("upgradeToProCell", rig)?.accessoryType == .disclosureIndicator)
        rig.pro.isUnlocked = true
        await SettingsTestSupport.waitUntil { self.cell("upgradeToProCell", rig)?.accessoryType == .checkmark }
        #expect(cell("upgradeToProCell", rig)?.accessoryType == .checkmark)
    }

    @Test("Tapping Pro Unlocked presents nothing and changes nothing")
    func unlockedProRowDoesNothing() async throws {
        let rig = try await makeRig(proUnlocked: true)
        select("upgradeToProCell", rig)
        await SettingsTestSupport.settle()
        #expect(rig.host.topmost === rig.host.root)
        #expect(rig.host.element("paywallUnlockButton") == nil)
        #expect(await rig.host.noAlert())
        #expect(rig.host.navigationTop is SecuritySettingsViewController)
        #expect(rig.pro.isUnlocked)
        #expect(title("upgradeToProCell", rig) == "Pro Unlocked")
        #expect(!SettingsTestSupport.changedLock(rig.mock))
    }

    @Test("The lock mode rows are titled No Lock, Password and Password + Face ID")
    func lockModeTitles() async throws {
        let rig = try await makeRig()
        #expect(title("settings.lockMode.noLockRow", rig) == "No Lock")
        #expect(title("settings.lockMode.passwordRow", rig) == "Password")
        #expect(title("settings.lockMode.biometricRow", rig) == "Password + Face ID")
    }

    @Test("The biometric row uses the Touch ID name on a Touch ID device")
    func touchIDTitle() async throws {
        let rig = try await makeRig(biometricKind: .touchID)
        #expect(title("settings.lockMode.biometricRow", rig) == "Password + Touch ID")
    }

    @Test("Only the row of the current lock mode carries a checkmark")
    func currentModeChecked() async throws {
        let rig = try await makeRig(lockMode: .password)
        #expect(cell("settings.lockMode.passwordRow", rig)?.accessoryType == .checkmark)
        #expect(cell("settings.lockMode.noLockRow", rig)?.accessoryType == UITableViewCell.AccessoryType.none)
        #expect(cell("settings.lockMode.biometricRow", rig)?.accessoryType == UITableViewCell.AccessoryType.none)
    }

    @Test("Without biometrics the biometric row is disabled and choosing it changes nothing")
    func biometricRowDisabled() async throws {
        let rig = try await makeRig(biometricsAvailable: false)
        let row = try #require(cell("settings.lockMode.biometricRow", rig))
        #expect(!row.isUserInteractionEnabled || row.accessibilityTraits.contains(.notEnabled))
        select("settings.lockMode.biometricRow", rig)
        #expect(await rig.host.noAlert())
        #expect(!SettingsTestSupport.changedLock(rig.mock))
    }

    @Test("Re-encrypt Everything shows with a lock and unencrypted files")
    func reencryptShown() async throws {
        let rig = try await makeRig(lockMode: .password, withFiles: true)
        #expect(cell("settings.lockMode.reEncryptRow", rig) != nil)
        #expect(title("settings.lockMode.reEncryptRow", rig) == "Re-encrypt Everything")
    }

    @Test("Re-encrypt Everything is hidden with no lock")
    func reencryptHiddenWithoutLock() async throws {
        let rig = try await makeRig(lockMode: .none, withFiles: true)
        #expect(cell("settings.lockMode.reEncryptRow", rig) == nil)
    }

    @Test("Re-encrypt Everything is hidden when every file is already encrypted")
    func reencryptHiddenWithoutFiles() async throws {
        let rig = try await makeRig(lockMode: .password, withFiles: false)
        #expect(cell("settings.lockMode.reEncryptRow", rig) == nil)
    }

    @Test("Re-encrypt Everything is hidden, without an error, when the store cannot be read")
    func reencryptHiddenOnStoreError() async throws {
        let mock = MockVaultLocking(lockMode: .password, password: "correct horse")
        try await mock.unlock(password: "correct horse")
        let store = MockVaultStoring(withSampleContent: true)
        store.errorToThrow = .locked
        let controller = SecuritySettingsViewController(
            lock: mock, migrator: MockLockMigrating(), store: store, pro: MockProUnlocking())
        let host = SettingsViewHost(content: UINavigationController(rootViewController: controller))
        await SettingsTestSupport.waitUntil { host.element("settings.lockMode.noLockRow") != nil }
        await SettingsTestSupport.settle()
        #expect(host.element("settings.lockMode.reEncryptRow") == nil)
        #expect(await host.noAlert())
    }

    @Test("Change Password shows with a lock and is hidden without one")
    func changePasswordVisibility() async throws {
        let locked = try await makeRig(lockMode: .password)
        let open = try await makeRig(lockMode: .none)
        #expect(title("settings.changePasswordRow", locked) == "Change Password")
        #expect(cell("settings.changePasswordRow", open) == nil)
    }

    @Test("The Storage section has a Recently Deleted row")
    func recentlyDeletedRow() async throws {
        let rig = try await makeRig()
        #expect(title("settings.recentlyDeletedRow", rig) == "Recently Deleted")
    }

    // MARK: - Navigation

    @Test("Tapping Recently Deleted pushes the Recently Deleted screen")
    func pushesRecentlyDeleted() async throws {
        let rig = try await makeRig()
        select("settings.recentlyDeletedRow", rig)
        await SettingsTestSupport.waitUntil { rig.host.navigationTop is RecentlyDeletedViewController }
        #expect(rig.host.navigationTop is RecentlyDeletedViewController)
    }

    @Test("Tapping Upgrade to Pro presents the paywall")
    func presentsPaywall() async throws {
        let rig = try await makeRig(proUnlocked: false)
        select("upgradeToProCell", rig)
        await SettingsTestSupport.waitUntil { rig.host.element("paywallUnlockButton") != nil }
        #expect(rig.host.element("paywallUnlockButton") != nil)
    }

    // MARK: - Changing the lock mode

    @Test("Choosing the current mode does nothing")
    func currentModeIgnored() async throws {
        let rig = try await makeRig(lockMode: .password)
        select("settings.lockMode.passwordRow", rig)
        #expect(await rig.host.noAlert())
        #expect(!SettingsTestSupport.changedLock(rig.mock))
        #expect(rig.migrator.calls.isEmpty)
    }

    @Test("No Lock from a lock asks Remove Lock? and starts nothing until confirmed")
    func removeLockAsks() async throws {
        let rig = try await makeRig(lockMode: .password)
        select("settings.lockMode.noLockRow", rig)
        let alert = try #require(await rig.host.alert())
        #expect(alert.title == "Remove Lock?")
        #expect(alert.message == "Your files will be decrypted and no longer protected.")
        #expect(rig.migrator.calls.isEmpty)
    }

    @Test("Cancelling Remove Lock? starts no migration")
    func removeLockCancelled() async throws {
        let rig = try await makeRig(lockMode: .password)
        select("settings.lockMode.noLockRow", rig)
        try #require(await rig.host.alert()).fire("Cancel")
        await SettingsTestSupport.waitUntil { !(rig.host.topmost is UIAlertController) }
        #expect(rig.migrator.calls.isEmpty)
        #expect(rig.host.topmost is UINavigationController)
    }

    @Test("Confirming Remove Lock? shows the decrypt migration and starts it")
    func removeLockConfirmed() async throws {
        let rig = try await makeRig(lockMode: .password)
        select("settings.lockMode.noLockRow", rig)
        let alert = try #require(await rig.host.alert())
        let remove = try #require(alert.actions.first { $0.style == .destructive })
        remove.fire()
        await SettingsTestSupport.waitUntil { rig.host.topmost is MigrationViewController }
        #expect(rig.host.topmost is MigrationViewController)
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.start(.decrypt, target: nil)) }
        #expect(rig.migrator.calls.contains(.start(.decrypt, target: nil)))
        #expect((rig.host.element("migration.titleLabel") as? UILabel)?.text == "Decrypting Files")
    }

    @Test("Password from No Lock asks for a password and its confirmation")
    func addLockAsksForPassword() async throws {
        let rig = try await makeRig(lockMode: .none)
        select("settings.lockMode.passwordRow", rig)
        let alert = try #require(await rig.host.alert())
        #expect(alert.field("settings.passwordField") != nil)
        #expect(alert.field("settings.confirmPasswordField") != nil)
    }

    @Test("A mismatched confirmation shows Passwords do not match and adds no lock")
    func addLockMismatch() async throws {
        let rig = try await makeRig(lockMode: .none)
        select("settings.lockMode.passwordRow", rig)
        let prompt = try #require(await rig.host.alert())
        prompt.field("settings.passwordField")?.text = "abc"
        prompt.field("settings.confirmPasswordField")?.text = "abd"
        prompt.actions.first { $0.style != .cancel }?.fire()
        await SettingsTestSupport.waitUntil { rig.host.topmost !== prompt && rig.host.topmost is UIAlertController }
        let error = try #require(rig.host.topmost as? UIAlertController)
        #expect(error.message == "Passwords do not match")
        #expect(rig.migrator.calls.isEmpty)
    }

    @Test("An empty password shows Password cannot be empty")
    func addLockEmpty() async throws {
        let rig = try await makeRig(lockMode: .none)
        select("settings.lockMode.passwordRow", rig)
        let prompt = try #require(await rig.host.alert())
        prompt.actions.first { $0.style != .cancel }?.fire()
        await SettingsTestSupport.waitUntil { rig.host.topmost !== prompt && rig.host.topmost is UIAlertController }
        let error = try #require(rig.host.topmost as? UIAlertController)
        #expect(error.message == "Password cannot be empty")
    }

    @Test("A matching password adds the lock and shows and starts the encrypt migration under Password")
    func addLockStartsEncrypt() async throws {
        let rig = try await makeRig(lockMode: .none)
        select("settings.lockMode.passwordRow", rig)
        let prompt = try #require(await rig.host.alert())
        prompt.field("settings.passwordField")?.text = "abc"
        prompt.field("settings.confirmPasswordField")?.text = "abc"
        prompt.actions.first { $0.style != .cancel }?.fire()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.start(.encrypt, target: .password)) }
        #expect(rig.mock.calls.contains(.prepareToAddLock(.password)))
        #expect(rig.migrator.calls.contains(.start(.encrypt, target: .password)))
        #expect(rig.host.topmost is MigrationViewController)
    }

    @Test("With an existing password blob, adding a lock asks for the existing password and then starts the encrypt")
    func addLockWithExistingBlobAsksForExistingPassword() async throws {
        let rig = try await makeRig(lockMode: .none, oldBlobPassword: "old blob")
        select("settings.lockMode.passwordRow", rig)
        let prompt = try #require(await rig.host.alert())
        prompt.field("settings.passwordField")?.text = "another"
        prompt.field("settings.confirmPasswordField")?.text = "another"
        prompt.actions.first { $0.style != .cancel }?.fire()
        await SettingsTestSupport.waitUntil { rig.host.topmost !== prompt && rig.host.topmost is UIAlertController }
        let existing = try #require(rig.host.topmost as? UIAlertController)
        #expect(existing.field("settings.existingPasswordField") != nil)
        #expect(rig.migrator.calls.isEmpty)
        existing.field("settings.existingPasswordField")?.text = "old blob"
        existing.actions.first { $0.style != .cancel }?.fire()
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.start(.encrypt, target: .password)) }
        #expect(rig.mock.calls.contains(.prepareToAddLock(.password)))
        #expect(rig.migrator.calls.contains(.start(.encrypt, target: .password)))
        #expect(rig.host.topmost is MigrationViewController)
    }

    @Test("A wrong existing password shows an error and starts no migration")
    func addLockWithWrongExistingPassword() async throws {
        let rig = try await makeRig(lockMode: .none, oldBlobPassword: "old blob")
        select("settings.lockMode.passwordRow", rig)
        let prompt = try #require(await rig.host.alert())
        prompt.field("settings.passwordField")?.text = "another"
        prompt.field("settings.confirmPasswordField")?.text = "another"
        prompt.actions.first { $0.style != .cancel }?.fire()
        await SettingsTestSupport.waitUntil { rig.host.topmost !== prompt && rig.host.topmost is UIAlertController }
        let existing = try #require(rig.host.topmost as? UIAlertController)
        existing.field("settings.existingPasswordField")?.text = "not it"
        existing.actions.first { $0.style != .cancel }?.fire()
        await SettingsTestSupport.waitUntil { rig.host.topmost !== existing && rig.host.topmost is UIAlertController }
        let error = try #require(rig.host.topmost as? UIAlertController)
        #expect(error.field("settings.existingPasswordField") == nil)
        #expect(rig.migrator.calls.isEmpty)
        #expect(!(rig.host.topmost is MigrationViewController))
    }

    @Test("Switching Password to Password + biometric switches the mode with no prompt")
    func switchToBiometric() async throws {
        let rig = try await makeRig(lockMode: .password)
        select("settings.lockMode.biometricRow", rig)
        await SettingsTestSupport.waitUntil { rig.mock.calls.contains(.switchMode(.passwordAndBiometrics)) }
        #expect(rig.mock.calls.contains(.switchMode(.passwordAndBiometrics)))
        await SettingsTestSupport.waitUntil {
            self.cell("settings.lockMode.biometricRow", rig)?.accessoryType == .checkmark
        }
        #expect(cell("settings.lockMode.biometricRow", rig)?.accessoryType == .checkmark)
        #expect(cell("settings.lockMode.passwordRow", rig)?.accessoryType == UITableViewCell.AccessoryType.none)
    }

    @Test("A mode change during a migration is refused with the in-progress message")
    func refusedDuringMigration() async throws {
        let pending = PendingMigration(kind: .encrypt, targetLockMode: .password)
        let rig = try await makeRig(lockMode: .password, pending: pending)
        select("settings.lockMode.noLockRow", rig)
        let alert = try #require(await rig.host.alert())
        #expect(alert.message == "A migration is still in progress. Let it finish, then try again.")
        #expect(rig.migrator.calls.allSatisfy { if case .start = $0 { false } else { true } })
    }

    @Test("Re-encrypt Everything shows the migration screen and starts an encrypt with no target")
    func reencryptStartsEncrypt() async throws {
        let rig = try await makeRig(lockMode: .password, withFiles: true)
        select("settings.lockMode.reEncryptRow", rig)
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.start(.encrypt, target: nil)) }
        #expect(rig.migrator.calls.contains(.start(.encrypt, target: nil)))
        #expect(rig.host.topmost is MigrationViewController)
    }

    // MARK: - Change Password

    @Test("Change Password asks for the current, new and confirmed passwords")
    func changePasswordPrompt() async throws {
        let rig = try await makeRig(lockMode: .password)
        select("settings.changePasswordRow", rig)
        let alert = try #require(await rig.host.alert())
        #expect(alert.field("settings.currentPasswordField") != nil)
        #expect(alert.field("settings.newPasswordField") != nil)
        #expect(alert.field("settings.confirmNewPasswordField") != nil)
    }

    private func submitChange(
        _ rig: Rig, current: String, new: String, confirm: String
    ) async throws -> UIAlertController {
        select("settings.changePasswordRow", rig)
        let prompt = try #require(await rig.host.alert())
        prompt.field("settings.currentPasswordField")?.text = current
        prompt.field("settings.newPasswordField")?.text = new
        prompt.field("settings.confirmNewPasswordField")?.text = confirm
        prompt.actions.first { $0.style != .cancel }?.fire()
        await SettingsTestSupport.waitUntil { rig.host.topmost !== prompt && rig.host.topmost is UIAlertController }
        return try #require(rig.host.topmost as? UIAlertController)
    }

    @Test("Changing the password with the right current one shows Password changed successfully")
    func changePasswordSucceeds() async throws {
        let rig = try await makeRig(lockMode: .password)
        let result = try await submitChange(rig, current: "correct horse", new: "new one", confirm: "new one")
        #expect(result.message == "Password changed successfully")
    }

    @Test("A wrong current password shows Current password is incorrect")
    func changePasswordWrongCurrent() async throws {
        let rig = try await makeRig(lockMode: .password)
        let result = try await submitChange(rig, current: "nope", new: "new one", confirm: "new one")
        #expect(result.message == "Current password is incorrect")
    }

    @Test("A mismatched new password shows Passwords do not match")
    func changePasswordMismatch() async throws {
        let rig = try await makeRig(lockMode: .password)
        let result = try await submitChange(rig, current: "correct horse", new: "a", confirm: "b")
        #expect(result.message == "Passwords do not match")
    }

    @Test("An empty new password shows Password cannot be empty")
    func changePasswordEmpty() async throws {
        let rig = try await makeRig(lockMode: .password)
        let result = try await submitChange(rig, current: "correct horse", new: "", confirm: "")
        #expect(result.message == "Password cannot be empty")
    }
}
