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

    @Test("A store read error hides Re-encrypt Everything and shows no error")
    func reencryptHiddenWhenStoreReadFails() async throws {
        let rig = try await makeRig(lockMode: .password, withFiles: true)
        await rig.viewModel.reload()
        #expect(rig.viewModel.showsReencrypt)
        rig.store.errorToThrow = .locked
        await rig.viewModel.reload()
        #expect(!rig.viewModel.showsReencrypt)
        #expect(rig.alerts.alerts.isEmpty)
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

    @Test("Confirming Remove Lock records a decrypt migration kind")
    func confirmingRemoveLockRecordsDecrypt() async throws {
        let rig = try await makeRig(lockMode: .password)
        await rig.viewModel.select(.none)
        await rig.viewModel.confirmRemoveLock()
        #expect(rig.viewModel.migrationKind == .decrypt)
    }

    @Test(
        "Adding a lock records an encrypt migration kind",
        arguments: [LockMode.password, .passwordAndBiometrics]
    )
    func addingLockRecordsEncrypt(target: LockMode) async throws {
        let rig = try await makeRig(lockMode: .none, password: nil)
        await rig.viewModel.select(target)
        await rig.viewModel.submitNewPassword("secret", confirm: "secret")
        #expect(rig.viewModel.migrationKind == .encrypt)
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
        "A matching new password prepares the lock and starts an encrypt migration under Password alone",
        arguments: [LockMode.password, .passwordAndBiometrics]
    )
    func newPasswordStartsEncrypt(target: LockMode) async throws {
        let rig = try await makeRig(lockMode: .none, password: nil)
        await rig.viewModel.select(target)
        await rig.viewModel.submitNewPassword("secret", confirm: "secret")
        #expect(rig.mock.calls.contains(.prepareToAddLock(.password)))
        #expect(rig.migrator.calls.contains(.start(.encrypt, target: .password)))
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
        #expect(rig.migrator.calls.contains(.start(.encrypt, target: .password)))
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

    @Test("Re-encrypt Everything records an encrypt migration kind")
    func reencryptRecordsEncrypt() async throws {
        let rig = try await makeRig(lockMode: .password)
        await rig.viewModel.reencryptEverything()
        #expect(rig.viewModel.migrationKind == .encrypt)
    }

    // MARK: - Scripted migrator rig

    private struct ScriptedRig {
        let viewModel: SecuritySettingsViewModel
        let lock: MockVaultLocking
        let migrator: SettingsScriptedMigrator
        let alerts: MockAlertPresenting
        let migrationShown: SettingsRecorder<Void>
    }

    private static let refusal = "A migration is still in progress. Let it finish, then try again."
    private static let faceIDNotTurnedOn =
        "Face ID wasn't turned on because some files aren't encrypted yet. "
        + "Use Re-encrypt Everything, then turn on Face ID."

    private func makeScriptedRig(
        lockMode: LockMode = .password,
        password: String? = "correct horse",
        biometricsAvailable: Bool = true,
        unlocked: Bool = true,
        withFiles: Bool = true
    ) async throws -> ScriptedRig {
        let lock = MockVaultLocking(
            lockMode: lockMode, password: password, biometricKind: .faceID,
            biometricsAvailable: biometricsAvailable)
        if unlocked && lockMode != .none { try await lock.unlock(password: Self.blob) }
        let migrator = SettingsScriptedMigrator()
        let alerts = MockAlertPresenting()
        let shown = SettingsRecorder<Void>()
        let viewModel = SecuritySettingsViewModel(
            lock: lock, migrator: migrator, store: MockVaultStoring(withSampleContent: withFiles),
            pro: MockProUnlocking(isUnlocked: false), alerts: alerts, onShowMigration: { shown.record(()) })
        return ScriptedRig(
            viewModel: viewModel, lock: lock, migrator: migrator, alerts: alerts, migrationShown: shown)
    }

    private func started(_ rig: ScriptedRig) -> [SettingsScriptedMigrator.Call] {
        rig.migrator.calls.filter { call in
            if case .start = call { return true }
            return false
        }
    }

    private func prepareCalls(_ rig: ScriptedRig) -> [MockVaultLocking.Call] {
        rig.lock.calls.filter { call in
            if case .prepareToAddLock = call { return true }
            return false
        }
    }

    private func switchCalls(_ rig: ScriptedRig) -> [MockVaultLocking.Call] {
        rig.lock.calls.filter { call in
            if case .switchMode = call { return true }
            return false
        }
    }

    private func expectRefused(_ rig: ScriptedRig) {
        #expect(rig.alerts.alerts == [.error(Self.refusal)])
        #expect(started(rig).isEmpty)
        #expect(rig.migrationShown.values.isEmpty)
        #expect(switchCalls(rig).isEmpty)
        #expect(prepareCalls(rig).isEmpty)
        #expect(rig.viewModel.prompt == nil)
    }

    // MARK: - Biometric row without biometrics

    @Test("Choosing Password + biometric without biometrics is ignored", arguments: [LockMode.password, .none])
    func biometricRowIgnoredWithoutBiometrics(from: LockMode) async throws {
        let rig = try await makeScriptedRig(
            lockMode: from, password: from == .none ? nil : Self.blob, biometricsAvailable: false)
        await rig.viewModel.select(.passwordAndBiometrics)
        #expect(rig.viewModel.prompt == nil)
        #expect(switchCalls(rig).isEmpty)
        #expect(started(rig).isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
        #expect(rig.migrationShown.values.isEmpty)
        #expect(rig.viewModel.currentMode == from)
    }

    // MARK: - Re-encrypt

    @Test(
        "Re-encrypt Everything keeps the target of a pending encrypt",
        arguments: [LockMode.password, .passwordAndBiometrics]
    )
    func reencryptKeepsPendingTarget(target: LockMode) async throws {
        let rig = try await makeScriptedRig()
        rig.migrator.pending = PendingMigration(kind: .encrypt, targetLockMode: target)
        await rig.viewModel.reencryptEverything()
        #expect(rig.migrator.calls.contains(.start(.encrypt, target)))
        #expect(rig.migrationShown.values.count == 1)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Re-encrypt Everything with no pending migration has no target")
    func reencryptWithoutPendingHasNoTarget() async throws {
        let rig = try await makeScriptedRig()
        await rig.viewModel.reencryptEverything()
        #expect(rig.migrator.calls.contains(.start(.encrypt, nil)))
    }

    @Test("Re-encrypt Everything with no lock does nothing")
    func reencryptWithoutLockDoesNothing() async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: nil)
        await rig.viewModel.reencryptEverything()
        #expect(started(rig).isEmpty)
        #expect(rig.migrationShown.values.isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
    }

    // MARK: - Refused during a migration

    enum MigrationUnderWay: CaseIterable, Sendable {
        case running
        case paused
        case failed
        case unreadableTrash
        case pending

        @MainActor
        func apply(to migrator: SettingsScriptedMigrator) {
            switch self {
            case .running: migrator.send(.running(done: 1, total: 4))
            case .paused: migrator.send(.paused(done: 1, total: 4))
            case .failed: migrator.send(.failed(names: ["a.jpg"]))
            case .unreadableTrash: migrator.send(.unreadableTrash)
            case .pending: migrator.pending = PendingMigration(kind: .decrypt, targetLockMode: nil)
            }
        }
    }

    enum LockModeChange: CaseIterable, Sendable {
        case removeLock
        case passwordToBiometric
        case biometricToPassword
        case addLock

        var from: LockMode {
            switch self {
            case .removeLock, .passwordToBiometric: .password
            case .biometricToPassword: .passwordAndBiometrics
            case .addLock: .none
            }
        }

        var target: LockMode {
            switch self {
            case .removeLock: .none
            case .passwordToBiometric: .passwordAndBiometrics
            case .biometricToPassword, .addLock: .password
            }
        }
    }

    @Test(
        "Changing the lock mode is refused while a migration is under way",
        arguments: MigrationUnderWay.allCases, LockModeChange.allCases
    )
    func lockModeChangeRefused(underWay: MigrationUnderWay, change: LockModeChange) async throws {
        let rig = try await makeScriptedRig(lockMode: change.from, password: change.from == .none ? nil : Self.blob)
        underWay.apply(to: rig.migrator)
        await rig.viewModel.select(change.target)
        expectRefused(rig)
        #expect(rig.viewModel.currentMode == change.from)
    }

    @Test(
        "Confirming Remove Lock is refused when a migration has started since the prompt",
        arguments: MigrationUnderWay.allCases
    )
    func confirmRemoveLockRefused(underWay: MigrationUnderWay) async throws {
        let rig = try await makeScriptedRig()
        await rig.viewModel.select(.none)
        #expect(rig.viewModel.prompt == .removeLock)
        underWay.apply(to: rig.migrator)
        await rig.viewModel.confirmRemoveLock()
        expectRefused(rig)
    }

    @Test(
        "Submitting a new password is refused when a migration has started since the prompt",
        arguments: MigrationUnderWay.allCases
    )
    func newPasswordRefused(underWay: MigrationUnderWay) async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: nil)
        await rig.viewModel.select(.password)
        underWay.apply(to: rig.migrator)
        await rig.viewModel.submitNewPassword("secret", confirm: "secret")
        expectRefused(rig)
    }

    @Test(
        "Submitting the existing password is refused when a migration has started since the prompt",
        arguments: MigrationUnderWay.allCases
    )
    func existingPasswordRefused(underWay: MigrationUnderWay) async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: Self.blob, unlocked: false)
        await rig.viewModel.select(.password)
        await rig.viewModel.submitNewPassword("another", confirm: "another")
        #expect(rig.viewModel.prompt == .existingPassword(.password))
        let preparedBefore = prepareCalls(rig).count
        underWay.apply(to: rig.migrator)
        await rig.viewModel.submitExistingPassword(Self.blob)
        #expect(rig.alerts.alerts == [.error(Self.refusal)])
        #expect(prepareCalls(rig).count == preparedBefore)
        #expect(started(rig).isEmpty)
        #expect(rig.migrationShown.values.isEmpty)
        #expect(rig.viewModel.prompt == nil)
    }

    @Test(
        "Re-encrypt Everything is refused while a migration is under way",
        arguments: MigrationUnderWay.allCases
    )
    func reencryptRefused(underWay: MigrationUnderWay) async throws {
        let rig = try await makeScriptedRig()
        underWay.apply(to: rig.migrator)
        await rig.viewModel.reencryptEverything()
        expectRefused(rig)
    }

    // MARK: - Keychain error while adding a lock

    @Test("A Keychain error preparing the lock stops: no existing-password prompt and no migration")
    func keychainErrorStopsAddingLock() async throws {
        let rig = try await makeRig(lockMode: .none, password: nil)
        rig.lock.prepareToAddLockError = VaultLockError.keychain(-25300)
        await rig.viewModel.select(.password)
        await rig.viewModel.submitNewPassword("secret", confirm: "secret")
        #expect(rig.alerts.alerts == [.error("A Keychain error occurred (-25300).")])
        #expect(rig.viewModel.prompt == nil)
        #expect(rig.migrator.calls.isEmpty)
        #expect(rig.migrationShown.values.isEmpty)
        #expect(!rig.viewModel.isBusy)
    }

    // MARK: - Migration finished

    private func addBiometricLock(_ rig: ScriptedRig) async {
        await rig.viewModel.select(.passwordAndBiometrics)
        await rig.viewModel.submitNewPassword("secret", confirm: "secret")
    }

    @Test("After a full Password + biometric migration the lock switches to Password + biometric")
    func fullMigrationTurnsBiometricsOn() async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: nil)
        await addBiometricLock(rig)
        await rig.viewModel.migrationFinished(completedFully: true)
        #expect(rig.lock.calls.contains(.switchMode(.passwordAndBiometrics)))
        #expect(rig.viewModel.currentMode == .passwordAndBiometrics)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A full migration after the existing password was entered also turns biometrics on")
    func fullMigrationAfterExistingPasswordTurnsBiometricsOn() async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: Self.blob, unlocked: false)
        await rig.viewModel.select(.passwordAndBiometrics)
        await rig.viewModel.submitNewPassword("another", confirm: "another")
        await rig.viewModel.submitExistingPassword(Self.blob)
        await rig.viewModel.migrationFinished(completedFully: true)
        #expect(rig.lock.calls.contains(.switchMode(.passwordAndBiometrics)))
        #expect(rig.viewModel.currentMode == .passwordAndBiometrics)
    }

    @Test("When switching to Password + biometric fails the error shows and the mode stays Password")
    func failedSwitchAfterMigrationKeepsPassword() async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: nil)
        await addBiometricLock(rig)
        rig.lock.appDidEnterBackground()
        await rig.viewModel.migrationFinished(completedFully: true)
        #expect(rig.alerts.alerts == [.error(VaultLockError.notUnlocked.localizedDescription)])
        #expect(rig.viewModel.currentMode == .password)
        #expect(rig.lock.lockMode == .password)
    }

    @Test("An incomplete Password + biometric migration explains why Face ID wasn't turned on")
    func incompleteMigrationExplainsFaceID() async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: nil)
        await addBiometricLock(rig)
        await rig.viewModel.migrationFinished(completedFully: false)
        #expect(rig.alerts.alerts == [.error(Self.faceIDNotTurnedOn)])
        #expect(switchCalls(rig).isEmpty)
        #expect(rig.viewModel.currentMode == .password)
    }

    @Test("After Password alone a finished migration switches nothing and shows nothing", arguments: [true, false])
    func passwordAloneFinishesQuietly(completedFully: Bool) async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: nil)
        await rig.viewModel.select(.password)
        await rig.viewModel.submitNewPassword("secret", confirm: "secret")
        await rig.viewModel.migrationFinished(completedFully: completedFully)
        #expect(switchCalls(rig).isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
        #expect(rig.viewModel.currentMode == .password)
    }

    @Test("After a decrypt a finished migration switches nothing and shows nothing", arguments: [true, false])
    func decryptFinishesQuietly(completedFully: Bool) async throws {
        let rig = try await makeScriptedRig(lockMode: .passwordAndBiometrics)
        await rig.viewModel.select(.none)
        await rig.viewModel.confirmRemoveLock()
        await rig.viewModel.migrationFinished(completedFully: completedFully)
        #expect(switchCalls(rig).isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("After a re-encrypt a finished migration switches nothing and shows nothing", arguments: [true, false])
    func reencryptFinishesQuietly(completedFully: Bool) async throws {
        let rig = try await makeScriptedRig(lockMode: .password)
        await rig.viewModel.reencryptEverything()
        await rig.viewModel.migrationFinished(completedFully: completedFully)
        #expect(switchCalls(rig).isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A finished migration refreshes Re-encrypt Everything: still shown when files are unencrypted")
    func finishedShowsReencryptWhenFilesRemain() async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: nil, withFiles: true)
        await rig.viewModel.select(.password)
        await rig.viewModel.submitNewPassword("secret", confirm: "secret")
        #expect(!rig.viewModel.showsReencrypt)
        await rig.viewModel.migrationFinished(completedFully: false)
        #expect(rig.viewModel.showsReencrypt)
        #expect(rig.viewModel.currentMode == .password)
    }

    @Test("A finished migration refreshes Re-encrypt Everything: hidden when the vault is empty")
    func finishedHidesReencryptWhenNoFiles() async throws {
        let rig = try await makeScriptedRig(lockMode: .password, withFiles: false)
        await rig.viewModel.reencryptEverything()
        await rig.viewModel.migrationFinished(completedFully: true)
        #expect(!rig.viewModel.showsReencrypt)
    }

    @Test("A finished migration refreshes the current mode from the lock")
    func finishedRefreshesCurrentMode() async throws {
        let rig = try await makeScriptedRig(lockMode: .passwordAndBiometrics)
        await rig.viewModel.select(.none)
        await rig.viewModel.confirmRemoveLock()
        try await rig.lock.removeKeysAfterDecryption()
        await rig.viewModel.migrationFinished(completedFully: true)
        #expect(rig.viewModel.currentMode == .none)
    }

    @Test("A second migrationFinished does nothing after a full migration")
    func secondFinishAfterFullMigrationDoesNothing() async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: nil)
        await addBiometricLock(rig)
        await rig.viewModel.migrationFinished(completedFully: true)
        await rig.viewModel.migrationFinished(completedFully: true)
        #expect(switchCalls(rig) == [.switchMode(.passwordAndBiometrics)])
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A second migrationFinished does nothing after an incomplete migration")
    func secondFinishAfterIncompleteMigrationDoesNothing() async throws {
        let rig = try await makeScriptedRig(lockMode: .none, password: nil)
        await addBiometricLock(rig)
        await rig.viewModel.migrationFinished(completedFully: false)
        await rig.viewModel.migrationFinished(completedFully: true)
        #expect(rig.alerts.alerts == [.error(Self.faceIDNotTurnedOn)])
        #expect(switchCalls(rig).isEmpty)
    }
}
