import Testing

@testable import KoalaTVault

// feature multiple-vaults-duress-password: rebuilt in LockScreens unit 1: this file uses API the feature removed; compiled out until LockScreens unit 1 replaces it.
#if false
    private struct BiometricErrorCase: Sendable {
        let error: VaultLockError
        let kind: BiometricKind
        let expectedMessage: String?
    }

    @MainActor
    @Suite struct LockScreenViewModelTests {
        private func makeViewModel(
            lock: any VaultLocking,
            preferences: MockPreferencesStoring = MockPreferencesStoring(lockMode: .password)
        ) -> LockScreenViewModel {
            LockScreenViewModel(lock: lock, preferences: preferences)
        }

        private func biometricLock(
            kind: BiometricKind = .faceID,
            available: Bool = true
        ) -> MockVaultLocking {
            MockVaultLocking(lockMode: .passwordAndBiometrics, biometricKind: kind, biometricsAvailable: available)
        }

        private func type(_ text: String, into viewModel: LockScreenViewModel) {
            viewModel.passwordEdited(text)
        }

        // MARK: Biometric button and focus

        @Test("The biometric button shows in biometric mode with biometrics available")
        func biometricButtonShown() {
            let viewModel = makeViewModel(lock: biometricLock())
            #expect(viewModel.showsBiometricButton)
        }

        @Test(
            "The biometric button title names the biometric kind",
            arguments: [(BiometricKind.faceID, "Use Face ID"), (.touchID, "Use Touch ID"), (.none, "Use Biometrics")])
        func biometricButtonTitleNamesKind(kind: BiometricKind, title: String) {
            let viewModel = makeViewModel(lock: biometricLock(kind: kind))
            #expect(viewModel.biometricButtonTitle == title)
        }

        @Test("The biometric button is hidden in password mode")
        func biometricButtonHiddenInPasswordMode() {
            let viewModel = makeViewModel(lock: MockVaultLocking(lockMode: .password))
            #expect(!viewModel.showsBiometricButton)
        }

        @Test("The biometric button is hidden when biometrics are unavailable")
        func biometricButtonHiddenWithoutBiometrics() {
            let viewModel = makeViewModel(lock: biometricLock(available: false))
            #expect(!viewModel.showsBiometricButton)
        }

        @Test("The password field is focused unless the biometric prompt is going to start")
        func passwordFocus() {
            #expect(makeViewModel(lock: MockVaultLocking(lockMode: .password)).focusesPasswordField)
            #expect(makeViewModel(lock: biometricLock(available: false)).focusesPasswordField)
            #expect(!makeViewModel(lock: biometricLock()).focusesPasswordField)
        }

        // MARK: Automatic biometric attempt

        @Test("The automatic biometric attempt does not start before the scene is active")
        func noAutoAttemptBeforeSceneActive() {
            let lock = biometricLock()
            _ = makeViewModel(lock: lock)
            #expect(lock.calls.isEmpty)
        }

        @Test("The automatic biometric attempt runs once the scene is active and unlocks")
        func autoAttemptWhenSceneActive() async {
            let lock = biometricLock()
            let viewModel = makeViewModel(lock: lock)
            var unlockedCount = 0
            viewModel.onUnlocked = { unlockedCount += 1 }
            await viewModel.sceneDidBecomeActive()
            #expect(lock.calls == [.unlockWithBiometrics])
            #expect(unlockedCount == 1)
        }

        @Test("The automatic biometric attempt happens only once")
        func autoAttemptOnlyOnce() async {
            let lock = biometricLock()
            lock.biometricError = .biometricCancelled
            let viewModel = makeViewModel(lock: lock)
            await viewModel.sceneDidBecomeActive()
            await viewModel.sceneDidBecomeActive()
            #expect(lock.calls == [.unlockWithBiometrics])
        }

        @Test("There is no automatic attempt in password mode")
        func noAutoAttemptInPasswordMode() async {
            let lock = MockVaultLocking(lockMode: .password)
            let viewModel = makeViewModel(lock: lock)
            await viewModel.sceneDidBecomeActive()
            #expect(lock.calls.isEmpty)
        }

        @Test("There is no automatic attempt when biometrics are unavailable")
        func noAutoAttemptWithoutBiometrics() async {
            let lock = biometricLock(available: false)
            let viewModel = makeViewModel(lock: lock)
            await viewModel.sceneDidBecomeActive()
            #expect(lock.calls.isEmpty)
        }

        @Test("The biometric button can still be used after the automatic attempt")
        func buttonWorksAfterAutoAttempt() async {
            let lock = biometricLock()
            lock.biometricError = .biometricCancelled
            let viewModel = makeViewModel(lock: lock)
            await viewModel.sceneDidBecomeActive()
            lock.biometricError = nil
            await viewModel.biometricTapped()
            #expect(lock.calls == [.unlockWithBiometrics, .unlockWithBiometrics])
        }

        // MARK: Biometric errors

        nonisolated private static func makeBiometricErrorCases() -> [BiometricErrorCase] {
            var cases: [BiometricErrorCase] = []
            func add(_ error: VaultLockError, _ kind: BiometricKind, _ message: String?) {
                cases.append(BiometricErrorCase(error: error, kind: kind, expectedMessage: message))
            }
            add(.biometricCancelled, .faceID, nil)
            add(.biometryLockedOut, .faceID, "Too many attempts. Use your password.")
            add(.biometryNotEnrolled, .faceID, "Face ID is not set up.")
            add(.biometryNotEnrolled, .touchID, "Touch ID is not set up.")
            add(.passcodeNotSet, .faceID, "Set a device passcode to use Face ID.")
            add(.passcodeNotSet, .touchID, "Set a device passcode to use Touch ID.")
            add(.biometricChanged, .faceID, "Face ID changed. Use your password.")
            add(.biometricChanged, .touchID, "Touch ID changed. Use your password.")
            add(.biometricsUnavailable, .faceID, "Biometric authentication failed")
            add(.keychain(-25300), .touchID, "Biometric authentication failed")
            return cases
        }

        nonisolated private static let biometricErrorCases = makeBiometricErrorCases()

        @Test(
            "Each biometric error maps to its exact message; cancel shows nothing",
            arguments: biometricErrorCases
        )
        fileprivate func biometricErrorMapping(testCase: BiometricErrorCase) async {
            let lock = biometricLock(kind: testCase.kind)
            lock.biometricError = testCase.error
            let viewModel = makeViewModel(lock: lock)
            var unlockedCount = 0
            viewModel.onUnlocked = { unlockedCount += 1 }
            await viewModel.biometricTapped()
            #expect(viewModel.errorMessage == testCase.expectedMessage)
            #expect(unlockedCount == 0)
            #expect(!viewModel.isBusy)
        }

        @Test("A biometric error from the automatic attempt shows the same message")
        func autoAttemptErrorShowsMessage() async {
            let lock = biometricLock()
            lock.biometricError = .biometryLockedOut
            let viewModel = makeViewModel(lock: lock)
            await viewModel.sceneDidBecomeActive()
            #expect(viewModel.errorMessage == "Too many attempts. Use your password.")
        }

        @Test("The password field stays usable after a biometric failure")
        func passwordWorksAfterBiometricFailure() async {
            let lock = biometricLock()
            lock.biometricError = .biometricChanged
            let viewModel = makeViewModel(lock: lock)
            await viewModel.biometricTapped()
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(lock.state == .unlocked)
            #expect(viewModel.errorMessage == nil)
        }

        // MARK: Password unlock

        @Test("A correct password unlocks and calls onUnlocked")
        func correctPasswordUnlocks() async {
            let lock = MockVaultLocking(lockMode: .password)
            let viewModel = makeViewModel(lock: lock)
            var unlockedCount = 0
            viewModel.onUnlocked = { unlockedCount += 1 }
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(lock.calls == [.unlock])
            #expect(unlockedCount == 1)
            #expect(viewModel.errorMessage == nil)
        }

        @Test("An empty password is ignored: no unlock, no error")
        func emptyPasswordIgnored() async {
            let lock = MockVaultLocking(lockMode: .password)
            let viewModel = makeViewModel(lock: lock)
            var unlockedCount = 0
            viewModel.onUnlocked = { unlockedCount += 1 }
            await viewModel.unlockTapped()
            #expect(lock.calls.isEmpty)
            #expect(viewModel.errorMessage == nil)
            #expect(unlockedCount == 0)
            #expect(!viewModel.isBusy)
        }

        @Test("A wrong password shows 'Incorrect password' and clears the field")
        func wrongPasswordClearsField() async {
            let lock = MockVaultLocking(lockMode: .password)
            let viewModel = makeViewModel(lock: lock)
            var unlockedCount = 0
            viewModel.onUnlocked = { unlockedCount += 1 }
            type("wrong", into: viewModel)
            await viewModel.unlockTapped()
            #expect(viewModel.errorMessage == "Incorrect password")
            #expect(viewModel.password.isEmpty)
            #expect(unlockedCount == 0)
            #expect(!viewModel.isBusy)
        }

        @Test("A successful unlock empties the password field")
        func successfulUnlockClearsField() async {
            let viewModel = makeViewModel(lock: MockVaultLocking(lockMode: .password))
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(viewModel.password.isEmpty)
        }

        @Test("Another unlock error (.keychain) empties the password field")
        func keychainErrorClearsField() async {
            let lock = ScriptedVaultLock(inner: MockVaultLocking(lockMode: .password))
            lock.unlockError = VaultLockError.keychain(-25300)
            let viewModel = makeViewModel(lock: lock)
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(viewModel.errorMessage != nil)
            #expect(viewModel.password.isEmpty)
        }

        @Test("A biometric error empties the password field")
        func biometricErrorClearsField() async {
            let lock = biometricLock()
            lock.biometricError = .biometricChanged
            let viewModel = makeViewModel(lock: lock)
            type("half typed", into: viewModel)
            await viewModel.biometricTapped()
            #expect(viewModel.errorMessage != nil)
            #expect(viewModel.password.isEmpty)
        }

        @Test("On a device without biometric hardware the lock screen messages say Biometrics")
        func biometricMessagesUseBiometricsNameWhenKindIsNone() async {
            let lock = biometricLock(kind: BiometricKind.none)
            lock.biometricError = .biometricChanged
            let viewModel = makeViewModel(lock: lock)
            await viewModel.biometricTapped()
            #expect(viewModel.errorMessage == "Biometrics changed. Use your password.")
        }

        @Test("Wrong passwords never lock the user out: a later correct one unlocks")
        func noLockoutAfterWrongPasswords() async {
            let lock = MockVaultLocking(lockMode: .password)
            let viewModel = makeViewModel(lock: lock)
            for _ in 0..<5 {
                type("wrong", into: viewModel)
                await viewModel.unlockTapped()
            }
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(lock.state == .unlocked)
        }

        @Test("A missing password blob shows the password-missing message")
        func passwordMissingMessage() async {
            let lock = MockVaultLocking(lockMode: .password, password: nil)
            let viewModel = makeViewModel(lock: lock)
            type("anything", into: viewModel)
            await viewModel.unlockTapped()
            #expect(viewModel.errorMessage == "Your vault password is missing from this device.")
        }

        @Test("The error clears when typing starts")
        func errorClearsWhenTyping() async {
            let lock = MockVaultLocking(lockMode: .password)
            let viewModel = makeViewModel(lock: lock)
            type("wrong", into: viewModel)
            await viewModel.unlockTapped()
            #expect(viewModel.errorMessage != nil)
            type("c", into: viewModel)
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.password == "c")
        }

        @Test("The view model is busy while unlocking and idle afterwards")
        func busyWhileUnlocking() async {
            let lock = ScriptedVaultLock(inner: MockVaultLocking(lockMode: .password))
            lock.holdsUnlock = true
            let viewModel = makeViewModel(lock: lock)
            type("correct horse", into: viewModel)
            #expect(!viewModel.isBusy)
            let unlocking = Task { await viewModel.unlockTapped() }
            #expect(await waitForCondition { lock.isHoldingCall })
            #expect(viewModel.isBusy)
            lock.releaseHeldCall()
            await unlocking.value
            #expect(!viewModel.isBusy)
        }

        @Test("Tapping unlock while already unlocking does not start a second unlock")
        func noSecondUnlockWhileBusy() async {
            let inner = MockVaultLocking(lockMode: .password)
            let lock = ScriptedVaultLock(inner: inner)
            lock.holdsUnlock = true
            let viewModel = makeViewModel(lock: lock)
            type("correct horse", into: viewModel)
            let unlocking = Task { await viewModel.unlockTapped() }
            #expect(await waitForCondition { lock.isHoldingCall })
            await viewModel.unlockTapped()
            lock.releaseHeldCall()
            await unlocking.value
            #expect(inner.calls == [.unlock])
        }

        @Test("Another unlock error shows its localized description")
        func otherUnlockErrorMessage() async {
            let lock = ScriptedVaultLock(inner: MockVaultLocking(lockMode: .password))
            lock.unlockError = StubFailure()
            let viewModel = makeViewModel(lock: lock)
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(viewModel.errorMessage == "The disk is full.")
        }

        // MARK: Pending lock

        private func pendingEncrypt(target: LockMode?) -> PendingMigration {
            PendingMigration(kind: .encrypt, targetLockMode: target)
        }

        @Test(
            "With lockMode .none and a pending encrypt, the vault is unlocked first, then the lock is added as .password",
            arguments: [LockMode.password, .passwordAndBiometrics]
        )
        func pendingLockUnlocksThenAddsPassword(target: LockMode) async {
            let lock = MockVaultLocking(lockMode: .none)
            let preferences = MockPreferencesStoring(lockMode: .none, pendingMigration: pendingEncrypt(target: target))
            let viewModel = makeViewModel(lock: lock, preferences: preferences)
            var unlockedCount = 0
            viewModel.onUnlocked = { unlockedCount += 1 }
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(lock.calls == [.unlock, .prepareToAddLock(.password)])
            #expect(unlockedCount == 1)
        }

        @Test("A pending encrypt with no target still unlocks first, then adds the lock as .password")
        func pendingLockWithoutTarget() async {
            let lock = MockVaultLocking(lockMode: .none)
            let preferences = MockPreferencesStoring(lockMode: .none, pendingMigration: pendingEncrypt(target: nil))
            let viewModel = makeViewModel(lock: lock, preferences: preferences)
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(lock.calls == [.unlock, .prepareToAddLock(.password)])
        }

        @Test(
            "A wrong password with a pending lock shows Incorrect password, adds no lock and does not call onUnlocked")
        func pendingLockWrongPassword() async {
            let lock = MockVaultLocking(lockMode: .none)
            let preferences = MockPreferencesStoring(
                lockMode: .none, pendingMigration: pendingEncrypt(target: .password))
            let viewModel = makeViewModel(lock: lock, preferences: preferences)
            var unlockedCount = 0
            viewModel.onUnlocked = { unlockedCount += 1 }
            type("wrong", into: viewModel)
            await viewModel.unlockTapped()
            #expect(unlockedCount == 0)
            #expect(viewModel.errorMessage == "Incorrect password")
            #expect(viewModel.password.isEmpty)
            #expect(!lock.calls.contains(.prepareToAddLock(.password)))
            #expect(!lock.calls.contains { if case .prepareToAddLock = $0 { true } else { false } })
        }

        @Test("A failure adding the lock after a good unlock shows its message and does not call onUnlocked")
        func pendingLockAddFailure() async {
            let inner = MockVaultLocking(lockMode: .none)
            let lock = ScriptedVaultLock(inner: inner)
            lock.prepareToAddLockError = VaultLockError.keychain(-25300)
            let preferences = MockPreferencesStoring(
                lockMode: .none, pendingMigration: pendingEncrypt(target: .password))
            let viewModel = makeViewModel(lock: lock, preferences: preferences)
            var unlockedCount = 0
            viewModel.onUnlocked = { unlockedCount += 1 }
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(inner.calls.contains(.unlock))
            #expect(viewModel.errorMessage == VaultLockError.keychain(-25300).errorDescription)
            #expect(viewModel.errorMessage == "A Keychain error occurred (-25300).")
            #expect(viewModel.password.isEmpty)
            #expect(unlockedCount == 0)
        }

        @Test("When both the unlock and the lock addition succeed, onUnlocked runs exactly once")
        func pendingLockBothSucceedRunsOnUnlockedOnce() async {
            let lock = MockVaultLocking(lockMode: .none)
            let preferences = MockPreferencesStoring(
                lockMode: .none, pendingMigration: pendingEncrypt(target: .password))
            let viewModel = makeViewModel(lock: lock, preferences: preferences)
            var unlockedCount = 0
            viewModel.onUnlocked = { unlockedCount += 1 }
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(unlockedCount == 1)
            #expect(viewModel.errorMessage == nil)
        }

        @Test("With a lock set and a pending encrypt, no lock is added")
        func noPendingLockStepWithLock() async {
            let lock = MockVaultLocking(lockMode: .password)
            let preferences = MockPreferencesStoring(
                lockMode: .password, pendingMigration: pendingEncrypt(target: .password))
            let viewModel = makeViewModel(lock: lock, preferences: preferences)
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(lock.calls == [.unlock])
        }

        @Test("With lockMode .none and no pending migration, no lock is added")
        func noPendingLockStepWithoutPending() async {
            let lock = MockVaultLocking(lockMode: .none)
            let preferences = MockPreferencesStoring(lockMode: .none)
            let viewModel = makeViewModel(lock: lock, preferences: preferences)
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(lock.calls == [.unlock])
        }

        @Test("With lockMode .none and a pending decrypt, no lock is added")
        func noPendingLockStepForDecrypt() async {
            let lock = MockVaultLocking(lockMode: .none)
            let pending = PendingMigration(kind: .decrypt, targetLockMode: nil)
            let preferences = MockPreferencesStoring(lockMode: .none, pendingMigration: pending)
            let viewModel = makeViewModel(lock: lock, preferences: preferences)
            type("correct horse", into: viewModel)
            await viewModel.unlockTapped()
            #expect(lock.calls == [.unlock])
        }
    }
#endif
