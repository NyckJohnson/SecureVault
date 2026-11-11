import Testing
import UIKit

@testable import KoalaTVault

// feature multiple-vaults-duress-password: per-vault Settings, `SecuritySettingsViewController(lock:store:pro:onRestore:)`.
// Identifiers: table `settings.table`; cells `upgradeToProCell`, `settings.changePasswordRow`, `settings.biometricRow`,
// `settings.deleteVaultRow`, `settings.recentlyDeletedRow`; switch `settings.biometricSwitch`; alert fields
// `settings.currentPasswordField`, `settings.newPasswordField`, `settings.confirmNewPasswordField`,
// `settings.deleteVaultPasswordField`; bar button `settingsDoneButton`.
@MainActor
@Suite struct SettingsSecurityViewControllerTests {
    @MainActor private struct Rig {
        let host: SettingsViewHost
        let lock: SettingsScriptedLock
        let store: MockVaultStoring
        let pro: MockProUnlocking

        var mock: MockVaultLocking { lock.inner }
        var navigation: UINavigationController? { host.root.presentedViewController as? UINavigationController }
    }

    private static let table = "settings.table"
    private static let password = "correct horse"

    /// Settings shown (presented, so it can close itself) for the vault open on a fresh mock.
    private func makeRig(
        encrypted: Bool = true,
        biometricKind: BiometricKind = .faceID,
        biometricsAvailable: Bool = true,
        biometricVaultID: String? = nil,
        proUnlocked: Bool = false
    ) async throws -> Rig {
        let mock = MockVaultLocking(
            biometricVaultID: biometricVaultID, biometricKind: biometricKind,
            biometricsAvailable: biometricsAvailable)
        if encrypted { try await mock.open(password: Self.password) }
        let lock = SettingsScriptedLock(inner: mock)
        let store = MockVaultStoring(withSampleContent: false)
        let pro = MockProUnlocking(isUnlocked: proUnlocked)
        let controller = SecuritySettingsViewController(lock: lock, store: store, pro: pro)
        let host = SettingsViewHost.presenting(UINavigationController(rootViewController: controller))
        await SettingsTestSupport.waitUntil { host.element("upgradeToProCell") != nil }
        await SettingsTestSupport.settle()
        return Rig(host: host, lock: lock, store: store, pro: pro)
    }

    private func cell(_ id: String, _ rig: Rig) -> UITableViewCell? { rig.host.element(id) as? UITableViewCell }

    private func title(_ id: String, _ rig: Rig) -> String? {
        cell(id, rig).flatMap { SettingsViewHost.texts(in: $0).first }
    }

    /// The Done bar button item of the screen on top of Settings' navigation stack.
    private func doneItem(_ rig: Rig) -> UIBarButtonItem? {
        rig.navigation?.viewControllers.first?.navigationItem.rightBarButtonItem
    }

    private func tapDone(_ rig: Rig) {
        guard let item = doneItem(rig), let selector = item.action else { return }
        UIApplication.shared.sendAction(selector, to: item.target, from: item, for: nil)
    }

    private func select(_ id: String, _ rig: Rig) { rig.host.selectRow(id, inTable: Self.table) }

    private func tableView(_ rig: Rig) -> UITableView? { rig.host.element(Self.table) as? UITableView }

    private func headers(_ rig: Rig) -> [String?] {
        guard let table = tableView(rig) else { return [] }
        return (0..<table.numberOfSections).map { table.dataSource?.tableView?(table, titleForHeaderInSection: $0) }
    }

    private func indexPath(_ id: String, _ rig: Rig) -> IndexPath? {
        guard let table = tableView(rig), let row = cell(id, rig) else { return nil }
        return table.indexPath(for: row)
    }

    private static let lockModeIDs = [
        "settings.lockMode.noLockRow", "settings.lockMode.passwordRow", "settings.lockMode.biometricRow",
        "settings.lockMode.reEncryptRow",
    ]

    // MARK: - Rows and sections

    @Test("An encrypted vault's Settings has a Vault section titled with the vault's name")
    func vaultSectionTitled() async throws {
        let rig = try await makeRig()
        #expect(headers(rig).contains { $0 == "My Vault" })
        let path = try #require(indexPath("settings.changePasswordRow", rig))
        #expect(headers(rig)[path.section] == "My Vault")
    }

    @Test("The Vault section holds Change Password, the Face ID row and Delete This Vault, in that order")
    func vaultSectionRows() async throws {
        let rig = try await makeRig()
        let change = try #require(indexPath("settings.changePasswordRow", rig))
        let face = try #require(indexPath("settings.biometricRow", rig))
        let delete = try #require(indexPath("settings.deleteVaultRow", rig))
        #expect(change.section == face.section && face.section == delete.section)
        let rows: [Int] = [change.row, face.row, delete.row]
        #expect(rows == [0, 1, 2])
        #expect(title("settings.changePasswordRow", rig) == "Change Password")
        #expect(title("settings.biometricRow", rig) == "Use Face ID")
        #expect(title("settings.deleteVaultRow", rig) == "Delete This Vault")
    }

    @Test("The unencrypted vault's Settings has no Vault section and none of its rows")
    func unencryptedVaultHasNoVaultRows() async throws {
        let rig = try await makeRig(encrypted: false)
        #expect(cell("settings.changePasswordRow", rig) == nil)
        #expect(cell("settings.biometricRow", rig) == nil)
        #expect(cell("settings.deleteVaultRow", rig) == nil)
        #expect(rig.host.element("settings.biometricSwitch") == nil)
        #expect(!headers(rig).contains { $0 == "My Vault" || $0 == "KoalaTVault" })
        #expect(tableView(rig)?.numberOfSections == 2)
    }

    @Test("The unencrypted vault's Settings still has the Pro row and Recently Deleted")
    func unencryptedVaultKeepsOtherRows() async throws {
        let rig = try await makeRig(encrypted: false)
        #expect(cell("upgradeToProCell", rig) != nil)
        #expect(title("settings.recentlyDeletedRow", rig) == "Recently Deleted")
    }

    @Test("No lock-mode or re-encrypt rows exist, for an encrypted or the unencrypted vault", arguments: [true, false])
    func noLockModeRows(encrypted: Bool) async throws {
        let rig = try await makeRig(encrypted: encrypted)
        for id in Self.lockModeIDs { #expect(cell(id, rig) == nil) }
    }

    @Test("The Storage section has a Recently Deleted row")
    func recentlyDeletedRow() async throws {
        let rig = try await makeRig()
        #expect(title("settings.recentlyDeletedRow", rig) == "Recently Deleted")
        let path = try #require(indexPath("settings.recentlyDeletedRow", rig))
        #expect(headers(rig)[path.section] == "Storage")
    }

    // MARK: - Pro row

    @Test("The Pro row is Upgrade to Pro for a free user and Pro Unlocked once unlocked")
    func proRowTitles() async throws {
        let free = try await makeRig(proUnlocked: false)
        let paid = try await makeRig(proUnlocked: true)
        #expect(title("upgradeToProCell", free) == "Upgrade to Pro")
        #expect(title("upgradeToProCell", paid) == "Pro Unlocked")
        #expect(cell("upgradeToProCell", free)?.accessoryType == .disclosureIndicator)
        #expect(cell("upgradeToProCell", paid)?.accessoryType == .checkmark)
    }

    @Test("The Pro row changes live when the entitlement changes")
    func proRowIsLive() async throws {
        let rig = try await makeRig(proUnlocked: false)
        rig.pro.isUnlocked = true
        await SettingsTestSupport.waitUntil { self.title("upgradeToProCell", rig) == "Pro Unlocked" }
        #expect(title("upgradeToProCell", rig) == "Pro Unlocked")
        #expect(cell("upgradeToProCell", rig)?.accessoryType == .checkmark)
    }

    @Test("Tapping Pro Unlocked presents nothing")
    func unlockedProRowDoesNothing() async throws {
        let rig = try await makeRig(proUnlocked: true)
        select("upgradeToProCell", rig)
        await SettingsTestSupport.settle()
        #expect(rig.host.element("paywallUnlockButton") == nil)
        #expect(await rig.host.noAlert())
    }

    // MARK: - Navigation

    @Test("Tapping Recently Deleted pushes the Recently Deleted screen")
    func pushesRecentlyDeleted() async throws {
        let rig = try await makeRig()
        select("settings.recentlyDeletedRow", rig)
        await SettingsTestSupport.waitUntil { rig.navigation?.topViewController is RecentlyDeletedViewController }
        #expect(rig.navigation?.topViewController is RecentlyDeletedViewController)
    }

    @Test("Tapping Upgrade to Pro presents the paywall")
    func presentsPaywall() async throws {
        let rig = try await makeRig(proUnlocked: false)
        select("upgradeToProCell", rig)
        await SettingsTestSupport.waitUntil { rig.host.element("paywallUnlockButton") != nil }
        #expect(rig.host.element("paywallUnlockButton") != nil)
    }

    // MARK: - Face ID switch

    @Test("The Face ID switch is off when the open vault does not use Face ID")
    func switchOff() async throws {
        let rig = try await makeRig()
        let toggle = try #require(rig.host.element("settings.biometricSwitch") as? UISwitch)
        #expect(!toggle.isOn)
    }

    @Test("The Face ID switch is on when the open vault uses Face ID")
    func switchOn() async throws {
        let rig = try await makeRig(biometricVaultID: "primary")
        let toggle = try #require(rig.host.element("settings.biometricSwitch") as? UISwitch)
        #expect(toggle.isOn)
    }

    @Test("The Face ID switch is off when another vault holds Face ID")
    func switchOffForOtherVault() async throws {
        let rig = try await makeRig(biometricVaultID: "someone-else")
        let toggle = try #require(rig.host.element("settings.biometricSwitch") as? UISwitch)
        #expect(!toggle.isOn)
    }

    @Test("The biometric row is titled with Touch ID on a Touch ID device")
    func touchIDTitle() async throws {
        let rig = try await makeRig(biometricKind: .touchID)
        #expect(title("settings.biometricRow", rig) == "Use Touch ID")
    }

    @Test("Without biometrics the Face ID row and switch are hidden, and the other rows stay")
    func switchHiddenWithoutBiometrics() async throws {
        let rig = try await makeRig(biometricKind: BiometricKind.none, biometricsAvailable: false)
        #expect(cell("settings.biometricRow", rig) == nil)
        #expect(rig.host.element("settings.biometricSwitch") == nil)
        #expect(cell("settings.changePasswordRow", rig) != nil)
        #expect(cell("settings.deleteVaultRow", rig) != nil)
    }

    @Test("Turning the switch on asks the lock to use biometrics for the open vault")
    func switchTurnsOn() async throws {
        let rig = try await makeRig()
        let toggle = try #require(rig.host.element("settings.biometricSwitch") as? UISwitch)
        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)
        await SettingsTestSupport.waitUntil { rig.mock.calls.contains(.setUsesBiometrics(true)) }
        #expect(rig.mock.calls.contains(.setUsesBiometrics(true)))
        #expect(rig.mock.currentUsesBiometrics)
    }

    @Test("Turning the switch off asks the lock to stop using biometrics")
    func switchTurnsOff() async throws {
        let rig = try await makeRig(biometricVaultID: "primary")
        let toggle = try #require(rig.host.element("settings.biometricSwitch") as? UISwitch)
        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)
        await SettingsTestSupport.waitUntil { rig.mock.calls.contains(.setUsesBiometrics(false)) }
        #expect(rig.mock.calls.contains(.setUsesBiometrics(false)))
        #expect(!rig.mock.currentUsesBiometrics)
    }

    @Test("A failed switch change shows the error and the switch shows the real state")
    func switchFailureReverts() async throws {
        let rig = try await makeRig()
        rig.lock.setUsesBiometricsError = SettingsStubFailure()
        let toggle = try #require(rig.host.element("settings.biometricSwitch") as? UISwitch)
        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)
        let alert = try #require(await rig.host.alert())
        #expect(alert.message == "The disk is full.")
        await SettingsTestSupport.waitUntil {
            (rig.host.element("settings.biometricSwitch") as? UISwitch)?.isOn == false
        }
        #expect((rig.host.element("settings.biometricSwitch") as? UISwitch)?.isOn == false)
    }

    // MARK: - Settings is for the vault current when it was made

    @Test("Settings keeps showing the vault it was made for after the lock's current vault changes")
    func readsCurrentOnce() async throws {
        let rig = try await makeRig()
        rig.mock.close()
        await SettingsTestSupport.settle()
        #expect(headers(rig).contains { $0 == "My Vault" })
        #expect(cell("settings.deleteVaultRow", rig) != nil)
    }

    // MARK: - Change Password

    @Test("Change Password asks for the current, new and confirmed passwords")
    func changePasswordPrompt() async throws {
        let rig = try await makeRig()
        select("settings.changePasswordRow", rig)
        let alert = try #require(await rig.host.alert())
        #expect(alert.title == "Change Password")
        #expect(alert.field("settings.currentPasswordField") != nil)
        #expect(alert.field("settings.newPasswordField") != nil)
        #expect(alert.field("settings.confirmNewPasswordField") != nil)
        #expect(alert.actionTitles == ["Cancel", "Change"])
    }

    @Test("Cancelling Change Password changes nothing")
    func changePasswordCancelled() async throws {
        let rig = try await makeRig()
        select("settings.changePasswordRow", rig)
        try #require(await rig.host.alert()).fire("Cancel")
        #expect(await rig.host.noAlert())
        #expect(!rig.mock.calls.contains(.changePassword))
    }

    private func submitChange(
        _ rig: Rig, current: String, new: String, confirm: String
    ) async throws -> UIAlertController {
        select("settings.changePasswordRow", rig)
        let prompt = try #require(await rig.host.alert())
        prompt.field("settings.currentPasswordField")?.text = current
        prompt.field("settings.newPasswordField")?.text = new
        prompt.field("settings.confirmNewPasswordField")?.text = confirm
        prompt.fire("Change")
        await SettingsTestSupport.waitUntil { rig.host.topmost !== prompt && rig.host.topmost is UIAlertController }
        return try #require(rig.host.topmost as? UIAlertController)
    }

    @Test("Changing the password with the right current one shows Password changed successfully")
    func changePasswordSucceeds() async throws {
        let rig = try await makeRig()
        let result = try await submitChange(rig, current: Self.password, new: "new one", confirm: "new one")
        #expect(result.message == "Password changed successfully")
        #expect(rig.mock.vaults.first { $0.id == "primary" }?.password == "new one")
    }

    @Test("A wrong current password shows Current password is incorrect")
    func changePasswordWrongCurrent() async throws {
        let rig = try await makeRig()
        let result = try await submitChange(rig, current: "nope", new: "new one", confirm: "new one")
        #expect(result.message == "Current password is incorrect")
    }

    @Test("A mismatched new password shows Passwords do not match")
    func changePasswordMismatch() async throws {
        let rig = try await makeRig()
        let result = try await submitChange(rig, current: Self.password, new: "a", confirm: "b")
        #expect(result.message == "Passwords do not match")
        #expect(!rig.mock.calls.contains(.changePassword))
    }

    @Test("An empty new password shows Password cannot be empty")
    func changePasswordEmpty() async throws {
        let rig = try await makeRig()
        let result = try await submitChange(rig, current: Self.password, new: "", confirm: "")
        #expect(result.message == "Password cannot be empty")
        #expect(!rig.mock.calls.contains(.changePassword))
    }

    // MARK: - Delete This Vault

    @Test("Delete This Vault asks with the title, the vault's name, a password field, Cancel and Delete")
    func deletePrompt() async throws {
        let rig = try await makeRig()
        select("settings.deleteVaultRow", rig)
        let alert = try #require(await rig.host.alert())
        #expect(alert.title == "Delete This Vault?")
        #expect(
            alert.message
                == "Everything in \"My Vault\" will be erased. This can't be undone. "
                + "Enter the vault's password to confirm.")
        #expect(alert.field("settings.deleteVaultPasswordField")?.isSecureTextEntry == true)
        #expect(alert.actionTitles == ["Cancel", "Delete"])
        #expect(alert.actions.first { $0.title == "Delete" }?.style == .destructive)
        #expect(alert.actions.first { $0.title == "Cancel" }?.style == .cancel)
    }

    @Test("Cancelling the delete prompt deletes nothing and keeps Settings open")
    func deleteCancelled() async throws {
        let rig = try await makeRig()
        select("settings.deleteVaultRow", rig)
        try #require(await rig.host.alert()).fire("Cancel")
        #expect(await rig.host.noAlert())
        #expect(!rig.mock.calls.contains(.deleteCurrentVault))
        #expect(rig.navigation != nil)
    }

    @Test("Delete with an empty password deletes nothing")
    func deleteEmptyPassword() async throws {
        let rig = try await makeRig()
        select("settings.deleteVaultRow", rig)
        try #require(await rig.host.alert()).fire("Delete")
        await SettingsTestSupport.settle()
        #expect(!rig.mock.calls.contains(.deleteCurrentVault))
        #expect(rig.navigation != nil)
    }

    @Test("Delete with the right password deletes the vault and closes Settings")
    func deleteSucceedsAndCloses() async throws {
        let rig = try await makeRig()
        select("settings.deleteVaultRow", rig)
        let prompt = try #require(await rig.host.alert())
        prompt.field("settings.deleteVaultPasswordField")?.text = Self.password
        prompt.fire("Delete")
        await SettingsTestSupport.waitUntil { rig.host.root.presentedViewController == nil }
        #expect(rig.lock.deletedPasswords == [Self.password])
        #expect(rig.mock.vaults.isEmpty)
        #expect(rig.host.root.presentedViewController == nil)
    }

    @Test("Delete with a wrong password shows Incorrect password and keeps Settings open")
    func deleteWrongPassword() async throws {
        let rig = try await makeRig()
        select("settings.deleteVaultRow", rig)
        let prompt = try #require(await rig.host.alert())
        prompt.field("settings.deleteVaultPasswordField")?.text = "nope"
        prompt.fire("Delete")
        await SettingsTestSupport.waitUntil { rig.host.topmost !== prompt && rig.host.topmost is UIAlertController }
        let error = try #require(rig.host.topmost as? UIAlertController)
        #expect(error.message == "Incorrect password")
        #expect(rig.mock.vaults.count == 1)
    }

    // MARK: - Done button

    @Test("The root screen has a Done button at the top right")
    func doneButtonExists() async throws {
        let rig = try await makeRig()
        let item = try #require(doneItem(rig))
        #expect(item.title == "Done")
        #expect(item.accessibilityIdentifier == "settingsDoneButton")
    }

    @Test("Tapping Done dismisses the presented Settings")
    func doneDismissesSettings() async throws {
        let rig = try await makeRig()
        #expect(rig.navigation != nil)
        tapDone(rig)
        await SettingsTestSupport.waitUntil { rig.host.root.presentedViewController == nil }
        #expect(rig.host.root.presentedViewController == nil)
    }

    @Test("Done is disabled while a password change is running and enabled again afterwards")
    func doneIsDisabledWhileBusy() async throws {
        let rig = try await makeRig()
        #expect(doneItem(rig)?.isEnabled == true)
        rig.lock.holdsCalls = true
        select("settings.changePasswordRow", rig)
        let prompt = try #require(await rig.host.alert())
        prompt.field("settings.currentPasswordField")?.text = Self.password
        prompt.field("settings.newPasswordField")?.text = "new one"
        prompt.field("settings.confirmNewPasswordField")?.text = "new one"
        prompt.fire("Change")
        await SettingsTestSupport.waitUntil { rig.lock.gate.isWaiting }
        #expect(rig.lock.gate.isWaiting)
        await SettingsTestSupport.waitUntil { doneItem(rig)?.isEnabled == false }
        #expect(doneItem(rig)?.isEnabled == false)
        rig.lock.gate.release()
        await SettingsTestSupport.waitUntil { doneItem(rig)?.isEnabled == true }
        #expect(doneItem(rig)?.isEnabled == true)
    }
}
