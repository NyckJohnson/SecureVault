import Foundation
import Testing

@testable import KoalaTVault

// feature multiple-vaults-duress-password: per-vault Settings (Vault section, Face ID per vault, Delete This Vault).
@MainActor
@Suite struct SecuritySettingsViewModelTests {
    private struct Rig {
        let viewModel: SecuritySettingsViewModel
        let lock: SettingsScriptedLock
        let pro: MockProUnlocking
        let alerts: MockAlertPresenting
        let deleted: SettingsRecorder<Void>

        var mock: MockVaultLocking { lock.inner }
    }

    private static let password = "correct horse"

    private func makeRig(
        encrypted: Bool = true,
        extraVault: Bool = false,
        biometricVaultID: String? = nil,
        biometricKind: BiometricKind = .faceID,
        biometricsAvailable: Bool = true,
        proUnlocked: Bool = false
    ) async throws -> Rig {
        var vaults = [MockVaultLocking.Vault(id: "primary", name: "My Vault", password: Self.password)]
        if extraVault {
            vaults.append(MockVaultLocking.Vault(id: "other", name: "Other Vault", password: "battery staple"))
        }
        let mock = MockVaultLocking(
            vaults: vaults, biometricVaultID: biometricVaultID, isPro: extraVault,
            biometricKind: biometricKind, biometricsAvailable: biometricsAvailable)
        if encrypted { try await mock.open(password: Self.password) }
        let lock = SettingsScriptedLock(inner: mock)
        let pro = MockProUnlocking(isUnlocked: proUnlocked)
        let alerts = MockAlertPresenting()
        let deleted = SettingsRecorder<Void>()
        let viewModel = SecuritySettingsViewModel(
            lock: lock, pro: pro, alerts: alerts, onVaultDeleted: { deleted.record(()) })
        return Rig(viewModel: viewModel, lock: lock, pro: pro, alerts: alerts, deleted: deleted)
    }

    // MARK: - Rows

    @Test("The Vault section shows for an encrypted open vault, titled with its name")
    func vaultSectionForEncryptedVault() async throws {
        let rig = try await makeRig()
        #expect(rig.viewModel.showsVaultSection)
        #expect(rig.viewModel.vaultSectionTitle == "My Vault")
    }

    @Test("The unencrypted vault has no Vault section, biometric switch or delete")
    func noVaultSectionForUnencryptedVault() async throws {
        let rig = try await makeRig(encrypted: false)
        #expect(!rig.viewModel.showsVaultSection)
        #expect(!rig.viewModel.showsBiometricSwitch)
    }

    @Test("The Vault section is titled with the name of whichever vault is open")
    func vaultSectionFollowsOpenVault() async throws {
        let rig = try await makeRig(extraVault: true)
        try await rig.mock.open(password: "battery staple")
        let other = SecuritySettingsViewModel(
            lock: rig.lock, pro: rig.pro, alerts: rig.alerts, onVaultDeleted: {})
        #expect(other.vaultSectionTitle == "Other Vault")
    }

    @Test("The biometric row shows when biometrics are available")
    func biometricRowShown() async throws {
        let rig = try await makeRig(biometricsAvailable: true)
        #expect(rig.viewModel.showsBiometricSwitch)
    }

    @Test("The biometric row is hidden when biometrics are not available")
    func biometricRowHidden() async throws {
        let rig = try await makeRig(biometricsAvailable: false)
        #expect(!rig.viewModel.showsBiometricSwitch)
    }

    @Test(
        "The biometric row is titled with the biometric name",
        arguments: [(BiometricKind.faceID, "Use Face ID"), (.touchID, "Use Touch ID")]
    )
    func biometricTitle(kind: BiometricKind, expected: String) async throws {
        let rig = try await makeRig(biometricKind: kind)
        #expect(rig.viewModel.biometricTitle == expected)
    }

    @Test("The switch is on when the open vault uses biometrics")
    func switchOnWhenVaultUsesBiometrics() async throws {
        let rig = try await makeRig(biometricVaultID: "primary")
        #expect(rig.viewModel.usesBiometrics)
    }

    @Test("The switch is off when another vault holds Face ID")
    func switchOffWhenOtherVaultHoldsBiometrics() async throws {
        let rig = try await makeRig(extraVault: true, biometricVaultID: "other")
        #expect(!rig.viewModel.usesBiometrics)
    }

    @Test("The switch is off when no vault uses biometrics")
    func switchOffWhenNoBiometricVault() async throws {
        let rig = try await makeRig()
        #expect(!rig.viewModel.usesBiometrics)
    }

    // MARK: - Sections (design tweaks: Delete This Vault in its own last section)
    // Names the view model must expose: `sections: [SecuritySettingsSection]` (cases `.pro`, `.vault`,
    // `.storage`, `.deleteVault`), `vaultRows: [SecuritySettingsVaultRow]` (cases `.changePassword`,
    // `.biometricSwitch`) and `biometricNote: String?`.

    @Test("An encrypted vault's sections are Pro, Vault, Storage, then Delete last")
    func sectionOrderEncrypted() async throws {
        let rig = try await makeRig()
        #expect(rig.viewModel.sections == [.pro, .vault, .storage, .deleteVault])
    }

    @Test("The unencrypted vault has only the Pro and Storage sections")
    func sectionsUnencrypted() async throws {
        let rig = try await makeRig(encrypted: false)
        #expect(rig.viewModel.sections == [.pro, .storage])
    }

    @Test("The Vault section holds Change Password and the biometric switch, and no delete row")
    func vaultRowsWithBiometrics() async throws {
        let rig = try await makeRig(biometricsAvailable: true)
        #expect(rig.viewModel.vaultRows == [.changePassword, .biometricSwitch])
    }

    @Test("The Vault section holds only Change Password when biometrics are not available")
    func vaultRowsWithoutBiometrics() async throws {
        let rig = try await makeRig(biometricsAvailable: false)
        #expect(rig.viewModel.vaultRows == [.changePassword])
    }

    @Test("The unencrypted vault has no Vault rows")
    func vaultRowsUnencrypted() async throws {
        let rig = try await makeRig(encrypted: false)
        #expect(rig.viewModel.vaultRows.isEmpty)
    }

    // MARK: - Biometric note

    @Test(
        "The note under the biometric switch names the biometric",
        arguments: [
            (BiometricKind.faceID, "Note: only one vault can use Face ID."),
            (.touchID, "Note: only one vault can use Touch ID."),
        ]
    )
    func biometricNote(kind: BiometricKind, expected: String) async throws {
        let rig = try await makeRig(biometricKind: kind)
        #expect(rig.viewModel.biometricNote == expected)
    }

    @Test("There is no note when biometrics are not available")
    func noBiometricNoteWhenUnavailable() async throws {
        let rig = try await makeRig(biometricsAvailable: false)
        #expect(rig.viewModel.biometricNote == nil)
    }

    @Test("There is no note for the unencrypted vault")
    func noBiometricNoteWhenUnencrypted() async throws {
        let rig = try await makeRig(encrypted: false)
        #expect(rig.viewModel.biometricNote == nil)
    }

    // MARK: - Pro row

    @Test("The Pro row says Upgrade to Pro while locked and Pro Unlocked once unlocked")
    func proTitle() async throws {
        let locked = try await makeRig(proUnlocked: false)
        #expect(locked.viewModel.proTitle == "Upgrade to Pro")
        #expect(!locked.viewModel.isProUnlocked)
        let unlocked = try await makeRig(proUnlocked: true)
        #expect(unlocked.viewModel.proTitle == "Pro Unlocked")
        #expect(unlocked.viewModel.isProUnlocked)
    }

    @Test("The Pro row updates live from unlockedUpdates")
    func proRowLive() async throws {
        let rig = try await makeRig(proUnlocked: false)
        let viewModel = rig.viewModel
        let task = Task { await viewModel.observeProUpdates() }
        await SettingsTestSupport.waitUntil { rig.pro.calls.contains(.unlockedUpdates) }
        rig.pro.isUnlocked = true
        await SettingsTestSupport.waitUntil { viewModel.isProUnlocked }
        #expect(viewModel.isProUnlocked)
        #expect(viewModel.proTitle == "Pro Unlocked")
        task.cancel()
    }

    // MARK: - Face ID switch

    @Test("Turning the switch on calls setUsesBiometrics(true) and the switch shows on")
    func switchOn() async throws {
        let rig = try await makeRig()
        await rig.viewModel.setUsesBiometrics(true)
        #expect(rig.mock.calls.contains(.setUsesBiometrics(true)))
        #expect(rig.viewModel.usesBiometrics)
        #expect(rig.mock.currentUsesBiometrics)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Turning the switch off calls setUsesBiometrics(false) and the switch shows off")
    func switchOff() async throws {
        let rig = try await makeRig(biometricVaultID: "primary")
        await rig.viewModel.setUsesBiometrics(false)
        #expect(rig.mock.calls.contains(.setUsesBiometrics(false)))
        #expect(!rig.viewModel.usesBiometrics)
        #expect(!rig.mock.currentUsesBiometrics)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Turning Face ID on moves it from the other vault, silently")
    func switchOnMovesFromOtherVault() async throws {
        let rig = try await makeRig(extraVault: true, biometricVaultID: "other")
        await rig.viewModel.setUsesBiometrics(true)
        #expect(rig.mock.biometricVaultID == "primary")
        #expect(rig.viewModel.usesBiometrics)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A failed switch-on shows the error and the switch shows the real state (off)")
    func switchOnFailureReverts() async throws {
        let rig = try await makeRig()
        rig.lock.setUsesBiometricsError = SettingsStubFailure()
        await rig.viewModel.setUsesBiometrics(true)
        #expect(rig.alerts.alerts == [.error("The disk is full.")])
        #expect(!rig.viewModel.usesBiometrics)
    }

    @Test("A failed switch-off shows the error and the switch shows the real state (on)")
    func switchOffFailureReverts() async throws {
        let rig = try await makeRig(biometricVaultID: "primary")
        rig.lock.setUsesBiometricsError = SettingsStubFailure()
        await rig.viewModel.setUsesBiometrics(false)
        #expect(rig.alerts.alerts == [.error("The disk is full.")])
        #expect(rig.viewModel.usesBiometrics)
    }

    @Test("A lock error from the switch shows the lock error's own message")
    func switchLockErrorMessage() async throws {
        let rig = try await makeRig()
        rig.mock.errorToThrow = .biometricsUnavailable
        await rig.viewModel.setUsesBiometrics(true)
        #expect(rig.alerts.alerts == [.error(VaultLockError.biometricsUnavailable.localizedDescription)])
        #expect(!rig.viewModel.usesBiometrics)
    }

    @Test("The model is busy while the switch change is working")
    func switchBusy() async throws {
        let rig = try await makeRig()
        rig.lock.holdsCalls = true
        let viewModel = rig.viewModel
        let task = Task { await viewModel.setUsesBiometrics(true) }
        await SettingsTestSupport.waitUntil { rig.lock.gate.isWaiting }
        #expect(viewModel.isBusy)
        rig.lock.gate.release()
        await task.value
        #expect(!viewModel.isBusy)
    }

    // MARK: - Change Password

    @Test("An empty new password shows Password cannot be empty")
    func changePasswordEmpty() async throws {
        let rig = try await makeRig()
        await rig.viewModel.changePassword(current: Self.password, new: "", confirm: "")
        #expect(rig.alerts.alerts == [.error("Password cannot be empty")])
        #expect(!rig.mock.calls.contains(.changePassword))
    }

    @Test("A mismatched confirmation shows Passwords do not match")
    func changePasswordMismatch() async throws {
        let rig = try await makeRig()
        await rig.viewModel.changePassword(current: Self.password, new: "new one", confirm: "new two")
        #expect(rig.alerts.alerts == [.error("Passwords do not match")])
        #expect(!rig.mock.calls.contains(.changePassword))
    }

    @Test("A wrong current password shows Current password is incorrect")
    func changePasswordWrongCurrent() async throws {
        let rig = try await makeRig()
        await rig.viewModel.changePassword(current: "nope", new: "new one", confirm: "new one")
        #expect(rig.alerts.alerts == [.error("Current password is incorrect")])
    }

    @Test("A new password another vault uses shows Choose a different password.")
    func changePasswordInUse() async throws {
        let rig = try await makeRig(extraVault: true)
        await rig.viewModel.changePassword(current: Self.password, new: "battery staple", confirm: "battery staple")
        #expect(rig.alerts.alerts == [.error("Choose a different password.")])
    }

    @Test("A successful change shows Password changed successfully and changes the password")
    func changePasswordSuccess() async throws {
        let rig = try await makeRig()
        await rig.viewModel.changePassword(current: Self.password, new: "new one", confirm: "new one")
        #expect(rig.alerts.alerts == [.success("Password changed successfully")])
        #expect(rig.mock.calls.contains(.changePassword))
        #expect(rig.mock.vaults.first { $0.id == "primary" }?.password == "new one")
    }

    @Test("Another change-password error shows its own message")
    func changePasswordOtherError() async throws {
        let rig = try await makeRig()
        rig.lock.changePasswordError = SettingsStubFailure()
        await rig.viewModel.changePassword(current: Self.password, new: "new one", confirm: "new one")
        #expect(rig.alerts.alerts == [.error("The disk is full.")])
    }

    @Test("The model is busy while the password is changing")
    func changePasswordBusy() async throws {
        let rig = try await makeRig()
        rig.lock.holdsCalls = true
        let viewModel = rig.viewModel
        let task = Task { await viewModel.changePassword(current: Self.password, new: "new one", confirm: "new one") }
        await SettingsTestSupport.waitUntil { rig.lock.gate.isWaiting }
        #expect(viewModel.isBusy)
        rig.lock.gate.release()
        await task.value
        #expect(!viewModel.isBusy)
    }

    // MARK: - Delete This Vault

    @Test("The delete prompt has the title Delete This Vault?")
    func deleteTitle() {
        #expect(SecuritySettingsViewModel.deleteVaultTitle == "Delete This Vault?")
    }

    @Test("The delete prompt message names the vault and asks for its password")
    func deleteMessage() async throws {
        let rig = try await makeRig()
        #expect(
            rig.viewModel.deleteVaultMessage
                == "Everything in \"My Vault\" will be erased. This can't be undone. "
                + "Enter the vault's password to confirm.")
    }

    @Test("Requesting a delete shows the prompt and cancelling clears it")
    func deletePromptLifecycle() async throws {
        let rig = try await makeRig()
        #expect(rig.viewModel.prompt == nil)
        rig.viewModel.requestDeleteVault()
        #expect(rig.viewModel.prompt == .deleteVault)
        rig.viewModel.cancelPrompt()
        #expect(rig.viewModel.prompt == nil)
        #expect(!rig.mock.calls.contains(.deleteCurrentVault))
    }

    @Test("An empty password is ignored")
    func deleteEmptyIgnored() async throws {
        let rig = try await makeRig()
        rig.viewModel.requestDeleteVault()
        await rig.viewModel.confirmDeleteVault(password: "")
        #expect(!rig.mock.calls.contains(.deleteCurrentVault))
        #expect(rig.alerts.alerts.isEmpty)
        #expect(rig.deleted.values.isEmpty)
    }

    @Test("A correct password deletes the open vault and reports Settings is done")
    func deleteSuccess() async throws {
        let rig = try await makeRig()
        rig.viewModel.requestDeleteVault()
        await rig.viewModel.confirmDeleteVault(password: Self.password)
        #expect(rig.mock.calls.contains(.deleteCurrentVault))
        #expect(rig.lock.deletedPasswords == [Self.password])
        #expect(rig.mock.vaults.isEmpty)
        #expect(rig.deleted.values.count == 1)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A wrong password shows Incorrect password and does not report done")
    func deleteWrongPassword() async throws {
        let rig = try await makeRig()
        rig.viewModel.requestDeleteVault()
        await rig.viewModel.confirmDeleteVault(password: "nope")
        #expect(rig.alerts.alerts == [.error("Incorrect password")])
        #expect(rig.deleted.values.isEmpty)
        #expect(rig.mock.vaults.count == 1)
    }

    @Test("Another delete error shows its own message and does not report done")
    func deleteOtherError() async throws {
        let rig = try await makeRig()
        rig.lock.deleteError = SettingsStubFailure()
        rig.viewModel.requestDeleteVault()
        await rig.viewModel.confirmDeleteVault(password: Self.password)
        #expect(rig.alerts.alerts == [.error("The disk is full.")])
        #expect(rig.deleted.values.isEmpty)
    }

    @Test("The model is busy while the vault is being deleted")
    func deleteBusy() async throws {
        let rig = try await makeRig()
        rig.lock.holdsCalls = true
        let viewModel = rig.viewModel
        viewModel.requestDeleteVault()
        let task = Task { await viewModel.confirmDeleteVault(password: Self.password) }
        await SettingsTestSupport.waitUntil { rig.lock.gate.isWaiting }
        #expect(viewModel.isBusy)
        rig.lock.gate.release()
        await task.value
        #expect(!viewModel.isBusy)
    }
}
