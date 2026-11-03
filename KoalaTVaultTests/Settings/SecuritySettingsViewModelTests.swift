import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct SecuritySettingsViewModelTests {
    private struct Rig {
        let viewModel: SecuritySettingsViewModel
        let lock: SettingsScriptedLock
        let migrator: MockLockMigrating
        let store: MockVaultStoring
        let pro: MockProUnlocking
        let alerts: MockAlertPresenting
        let migrationShown: SettingsRecorder<Void>

        var mock: MockVaultLocking { lock.inner }
    }

    private static let blob = "correct horse"

    private func makeRig(
        lockMode: LockMode = .password,
        password: String? = "correct horse",
        biometricKind: BiometricKind = .faceID,
        biometricsAvailable: Bool = true,
        proUnlocked: Bool = false,
        withFiles: Bool = true,
        unlocked: Bool = true
    ) async throws -> Rig {
        let mock = MockVaultLocking(
            lockMode: lockMode, password: password, biometricKind: biometricKind,
            biometricsAvailable: biometricsAvailable)
        if unlocked && lockMode != .none { try await mock.unlock(password: Self.blob) }
        let lock = SettingsScriptedLock(inner: mock)
        let migrator = MockLockMigrating()
        let store = MockVaultStoring(withSampleContent: withFiles)
        let pro = MockProUnlocking(isUnlocked: proUnlocked)
        let alerts = MockAlertPresenting()
        let shown = SettingsRecorder<Void>()
        let viewModel = SecuritySettingsViewModel(
            lock: lock, migrator: migrator, store: store, pro: pro, alerts: alerts,
            onShowMigration: { shown.record(()) })
        return Rig(
            viewModel: viewModel, lock: lock, migrator: migrator, store: store, pro: pro, alerts: alerts,
            migrationShown: shown)
    }

    // MARK: - Pro row

    @Test("The Pro row says Upgrade to Pro while locked and Pro Unlocked when unlocked")
    func proRowTitle() async throws {
        let free = try await makeRig(proUnlocked: false)
        let paid = try await makeRig(proUnlocked: true)
        #expect(free.viewModel.proTitle == "Upgrade to Pro")
        #expect(paid.viewModel.proTitle == "Pro Unlocked")
    }

    @Test("The Pro row follows unlockedUpdates live in both directions")
    func proRowIsLive() async throws {
        let rig = try await makeRig(proUnlocked: false)
        let observing = Task { await rig.viewModel.observeProUpdates() }
        await SettingsTestSupport.waitUntil { rig.pro.calls.contains(.unlockedUpdates) }
        rig.pro.isUnlocked = true
        await SettingsTestSupport.waitUntil { rig.viewModel.proTitle == "Pro Unlocked" }
        #expect(rig.viewModel.proTitle == "Pro Unlocked")
        rig.pro.isUnlocked = false
        await SettingsTestSupport.waitUntil { rig.viewModel.proTitle == "Upgrade to Pro" }
        #expect(rig.viewModel.proTitle == "Upgrade to Pro")
        observing.cancel()
    }

    // MARK: - Rows

    @Test("Lock mode rows are titled No Lock, Password and Password + the biometric name")
    func lockModeTitles() async throws {
        let faceID = try await makeRig(biometricKind: .faceID)
        let touchID = try await makeRig(biometricKind: .touchID)
        #expect(faceID.viewModel.title(for: .none) == "No Lock")
        #expect(faceID.viewModel.title(for: .password) == "Password")
        #expect(faceID.viewModel.title(for: .passwordAndBiometrics) == "Password + Face ID")
        #expect(touchID.viewModel.title(for: .passwordAndBiometrics) == "Password + Touch ID")
    }

    @Test("With no biometric kind the biometric row is titled Password + Biometrics")
    func biometricTitleWithoutKind() async throws {
        let rig = try await makeRig(biometricKind: BiometricKind.none, biometricsAvailable: false)
        #expect(rig.viewModel.title(for: .passwordAndBiometrics) == "Password + Biometrics")
    }

    @Test("The biometric row is disabled without biometrics; the others stay enabled")
    func biometricRowDisabledWithoutBiometrics() async throws {
        let without = try await makeRig(biometricsAvailable: false)
        let with = try await makeRig(biometricsAvailable: true)
        #expect(without.viewModel.isEnabled(.none))
        #expect(without.viewModel.isEnabled(.password))
        #expect(!without.viewModel.isEnabled(.passwordAndBiometrics))
        #expect(with.viewModel.isEnabled(.passwordAndBiometrics))
    }

    @Test("The current lock mode is the lock's mode", arguments: LockMode.allCases)
    func currentModeFollowsLock(mode: LockMode) async throws {
        let rig = try await makeRig(lockMode: mode)
        #expect(rig.viewModel.currentMode == mode)
    }

    @Test("Change Password is shown only with a lock", arguments: LockMode.allCases)
    func changePasswordVisibility(mode: LockMode) async throws {
        let rig = try await makeRig(lockMode: mode)
        #expect(rig.viewModel.showsChangePassword == (mode != .none))
    }

    @Test("Re-encrypt Everything is shown with a lock and unencrypted files")
    func reencryptShownWithLockAndPlaintextFiles() async throws {
        let rig = try await makeRig(lockMode: .password, withFiles: true)
        await rig.viewModel.reload()
        #expect(rig.viewModel.showsReencrypt)
    }

    @Test("Re-encrypt Everything is hidden without a lock even with unencrypted files")
    func reencryptHiddenWithoutLock() async throws {
        let rig = try await makeRig(lockMode: .none, password: nil, withFiles: true)
        await rig.viewModel.reload()
        #expect(!rig.viewModel.showsReencrypt)
    }

    @Test("Re-encrypt Everything is hidden when the vault holds no files")
    func reencryptHiddenWithEmptyVault() async throws {
        let rig = try await makeRig(lockMode: .password, withFiles: false)
        await rig.viewModel.reload()
        #expect(!rig.viewModel.showsReencrypt)
    }

    @Test("Re-encrypt Everything is hidden once every file is encrypted")
    func reencryptHiddenWhenAllEncrypted() async throws {
        let rig = try await makeRig(lockMode: .password, withFiles: true)
        for item in try await rig.store.itemsToMigrate(toEncrypted: true) {
            try await rig.store.migrateToEncrypted(item)
        }
        await rig.viewModel.reload()
        #expect(!rig.viewModel.showsReencrypt)
    }

    @Test("Reloading refreshes the current mode from the lock")
    func reloadRefreshesCurrentMode() async throws {
        let rig = try await makeRig(lockMode: .password)
        try await rig.mock.switchMode(to: .passwordAndBiometrics)
        await rig.viewModel.reload()
        #expect(rig.viewModel.currentMode == .passwordAndBiometrics)
    }

    // MARK: - Choosing the current mode

    @Test("Choosing the current mode does nothing", arguments: LockMode.allCases)
    func choosingCurrentModeDoesNothing(mode: LockMode) async throws {
        let rig = try await makeRig(lockMode: mode, password: mode == .none ? nil : Self.blob)
        await rig.viewModel.select(mode)
        #expect(!SettingsTestSupport.changedLock(rig.mock))
        #expect(rig.migrator.calls.isEmpty)
        #expect(rig.viewModel.prompt == nil)
        #expect(rig.alerts.alerts.isEmpty)
        #expect(rig.migrationShown.values.isEmpty)
        #expect(rig.viewModel.currentMode == mode)
    }

    // MARK: - Remove the lock

    @Test(
        "Choosing No Lock from a lock asks to confirm Remove Lock? and starts nothing yet",
        arguments: [LockMode.password, .passwordAndBiometrics]
    )
    func noLockAsksForConfirmation(mode: LockMode) async throws {
        let rig = try await makeRig(lockMode: mode)
        await rig.viewModel.select(.none)
        #expect(rig.viewModel.prompt == .removeLock)
        #expect(SecuritySettingsViewModel.removeLockTitle == "Remove Lock?")
        #expect(rig.migrator.calls.isEmpty)
        #expect(!SettingsTestSupport.changedLock(rig.mock))
    }

    @Test("Confirming Remove Lock starts a decrypt migration with no target")
    func confirmingRemoveLockStartsDecrypt() async throws {
        let rig = try await makeRig(lockMode: .password)
        await rig.viewModel.select(.none)
        await rig.viewModel.confirmRemoveLock()
        #expect(rig.migrator.calls.contains(.start(.decrypt, target: nil)))
        #expect(rig.migrationShown.values.count == 1)
        #expect(rig.viewModel.prompt == nil)
    }

    @Test("Cancelling Remove Lock starts nothing and keeps the mode")
    func cancellingRemoveLock() async throws {
        let rig = try await makeRig(lockMode: .password)
        await rig.viewModel.select(.none)
        rig.viewModel.cancelPrompt()
        #expect(rig.viewModel.prompt == nil)
        #expect(rig.migrator.calls.isEmpty)
        #expect(rig.migrationShown.values.isEmpty)
        #expect(rig.viewModel.currentMode == .password)
    }

    // MARK: - Add a lock

    @Test(
        "Choosing a lock from No Lock asks for a new password",
        arguments: [LockMode.password, .passwordAndBiometrics]
    )
    func choosingLockAsksForPassword(target: LockMode) async throws {
        let rig = try await makeRig(lockMode: .none, password: nil)
        await rig.viewModel.select(target)
        #expect(rig.viewModel.prompt == .newPassword(target))
        #expect(rig.migrator.calls.isEmpty)
        #expect(!SettingsTestSupport.changedLock(rig.mock))
    }

    @Test(
        "A matching new password prepares the lock and starts an encrypt migration with the target",
        arguments: [LockMode.password, .passwordAndBiometrics]
    )
    func newPasswordStartsEncrypt(target: LockMode) async throws {
        let rig = try await makeRig(lockMode: .none, password: nil)
        await rig.viewModel.select(target)
        await rig.viewModel.submitNewPassword("secret", confirm: "secret")
        #expect(rig.mock.calls.contains(.prepareToAddLock(.password)))
        #expect(rig.migrator.calls.contains(.start(.encrypt, target: target)))
        #expect(rig.migrationShown.values.count == 1)
        #expect(rig.viewModel.prompt == nil)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("An empty new password shows Password cannot be empty and adds no lock")
    func emptyNewPassword() async throws {
        let rig = try await makeRig(lockMode: .none, password: nil)
        await rig.viewModel.select(.password)
        await rig.viewModel.submitNewPassword("", confirm: "")
        #expect(rig.alerts.alerts == [.error("Password cannot be empty")])
        #expect(!SettingsTestSupport.changedLock(rig.mock))
        #expect(rig.migrator.calls.isEmpty)
    }

    @Test("A mismatched confirmation shows Passwords do not match and adds no lock")
    func mismatchedNewPassword() async throws {
        let rig = try await makeRig(lockMode: .none, password: nil)
        await rig.viewModel.select(.password)
        await rig.viewModel.submitNewPassword("secret", confirm: "secrat")
        #expect(rig.alerts.alerts == [.error("Passwords do not match")])
        #expect(!SettingsTestSupport.changedLock(rig.mock))
        #expect(rig.migrator.calls.isEmpty)
    }

    @Test("With an existing password blob the existing password is asked for, then the migration starts")
    func existingBlobAsksForExistingPassword() async throws {
        let rig = try await makeRig(lockMode: .none, password: Self.blob, unlocked: false)
        await rig.viewModel.select(.passwordAndBiometrics)
        await rig.viewModel.submitNewPassword("another", confirm: "another")
        #expect(rig.viewModel.prompt == .existingPassword(.passwordAndBiometrics))
        #expect(rig.migrator.calls.isEmpty)
        await rig.viewModel.submitExistingPassword(Self.blob)
        #expect(rig.migrator.calls.contains(.start(.encrypt, target: .passwordAndBiometrics)))
        #expect(rig.migrationShown.values.count == 1)
        #expect(rig.viewModel.prompt == nil)
    }

    @Test("A wrong existing password starts no migration and shows an error")
    func wrongExistingPassword() async throws {
        let rig = try await makeRig(lockMode: .none, password: Self.blob, unlocked: false)
        await rig.viewModel.select(.password)
        await rig.viewModel.submitNewPassword("another", confirm: "another")
        await rig.viewModel.submitExistingPassword("not the password")
        #expect(rig.migrator.calls.isEmpty)
        #expect(rig.migrationShown.values.isEmpty)
        #expect(rig.alerts.alerts.count == 1)
    }

    @Test("A failure preparing the lock shows its message and starts no migration")
    func prepareToAddLockFailure() async throws {
        let rig = try await makeRig(lockMode: .none, password: nil)
        rig.lock.prepareToAddLockError = SettingsStubFailure()
        await rig.viewModel.select(.password)
        await rig.viewModel.submitNewPassword("secret", confirm: "secret")
        #expect(rig.alerts.alerts == [.error("The disk is full.")])
        #expect(rig.migrator.calls.isEmpty)
        #expect(rig.migrationShown.values.isEmpty)
    }

    @Test("Cancelling the password prompt hides it and starts nothing")
    func cancellingPasswordPrompt() async throws {
        let rig = try await makeRig(lockMode: .none, password: nil)
        await rig.viewModel.select(.password)
        rig.viewModel.cancelPrompt()
        #expect(rig.viewModel.prompt == nil)
        #expect(rig.migrator.calls.isEmpty)
        #expect(rig.viewModel.currentMode == .none)
    }

    // MARK: - Password and biometric

    @Test("Password to Password + biometric switches the mode in place")
    func switchToBiometric() async throws {
        let rig = try await makeRig(lockMode: .password)
        await rig.viewModel.select(.passwordAndBiometrics)
        #expect(rig.mock.calls.contains(.switchMode(.passwordAndBiometrics)))
        #expect(rig.viewModel.currentMode == .passwordAndBiometrics)
        #expect(rig.migrator.calls.isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Password + biometric to Password switches the mode in place")
    func switchToPassword() async throws {
        let rig = try await makeRig(lockMode: .passwordAndBiometrics)
        await rig.viewModel.select(.password)
        #expect(rig.mock.calls.contains(.switchMode(.password)))
        #expect(rig.viewModel.currentMode == .password)
        #expect(rig.migrator.calls.isEmpty)
    }

    @Test("A failed switch shows the error and the row keeps the real mode")
    func failedSwitchShowsErrorAndKeepsMode() async throws {
        let rig = try await makeRig(lockMode: .password, unlocked: false)
        await rig.viewModel.select(.passwordAndBiometrics)
        #expect(rig.alerts.alerts == [.error(VaultLockError.notUnlocked.localizedDescription)])
        #expect(rig.viewModel.currentMode == .password)
        #expect(rig.mock.lockMode == .password)
    }

    // MARK: - Re-encrypt

    @Test("Re-encrypt Everything starts an encrypt migration with no target")
    func reencryptStartsEncryptWithoutTarget() async throws {
        let rig = try await makeRig(lockMode: .passwordAndBiometrics)
        await rig.viewModel.reencryptEverything()
        #expect(rig.migrator.calls.contains(.start(.encrypt, target: nil)))
        #expect(rig.migrationShown.values.count == 1)
        #expect(!SettingsTestSupport.changedLock(rig.mock))
    }

    // MARK: - Change Password

    @Test("An empty new password shows Password cannot be empty")
    func changePasswordEmpty() async throws {
        let rig = try await makeRig()
        await rig.viewModel.changePassword(current: Self.blob, new: "", confirm: "")
        #expect(rig.alerts.alerts == [.error("Password cannot be empty")])
        #expect(!rig.mock.calls.contains(.changePassword))
    }

    @Test("A mismatched confirmation shows Passwords do not match")
    func changePasswordMismatch() async throws {
        let rig = try await makeRig()
        await rig.viewModel.changePassword(current: Self.blob, new: "fresh", confirm: "fresh!")
        #expect(rig.alerts.alerts == [.error("Passwords do not match")])
        #expect(!rig.mock.calls.contains(.changePassword))
    }

    @Test("A wrong current password shows Current password is incorrect and keeps the password")
    func changePasswordWrongCurrent() async throws {
        let rig = try await makeRig()
        await rig.viewModel.changePassword(current: "nope", new: "fresh", confirm: "fresh")
        #expect(rig.alerts.alerts == [.error("Current password is incorrect")])
        #expect(rig.mock.password == Self.blob)
    }

    @Test("A successful change shows Password changed successfully and stores the new password")
    func changePasswordSuccess() async throws {
        let rig = try await makeRig()
        await rig.viewModel.changePassword(current: Self.blob, new: "fresh", confirm: "fresh")
        #expect(rig.alerts.alerts == [.success("Password changed successfully")])
        #expect(rig.mock.password == "fresh")
    }

    @Test("Any other change-password failure shows its own message")
    func changePasswordOtherError() async throws {
        let rig = try await makeRig()
        rig.lock.changePasswordError = SettingsStubFailure()
        await rig.viewModel.changePassword(current: Self.blob, new: "fresh", confirm: "fresh")
        #expect(rig.alerts.alerts == [.error("The disk is full.")])
    }

    @Test("The screen is busy while the password is changing and idle afterwards")
    func changePasswordBusy() async throws {
        let rig = try await makeRig()
        rig.lock.holdsChangePassword = true
        #expect(!rig.viewModel.isBusy)
        let working = Task {
            await rig.viewModel.changePassword(current: Self.blob, new: "fresh", confirm: "fresh")
        }
        await SettingsTestSupport.waitUntil { rig.lock.changePasswordGate.isWaiting }
        #expect(rig.viewModel.isBusy)
        rig.lock.changePasswordGate.release()
        await working.value
        #expect(!rig.viewModel.isBusy)
    }

    @Test("The screen is not busy after a failed change")
    func changePasswordNotBusyAfterFailure() async throws {
        let rig = try await makeRig()
        await rig.viewModel.changePassword(current: "nope", new: "fresh", confirm: "fresh")
        #expect(!rig.viewModel.isBusy)
    }
}
