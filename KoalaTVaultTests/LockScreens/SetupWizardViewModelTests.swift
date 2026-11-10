import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct SetupWizardViewModelTests {
    private func makeViewModel(
        lock: (any VaultLocking)? = nil,
        preferences: MockPreferencesStoring = MockPreferencesStoring()
    ) -> SetupWizardViewModel {
        SetupWizardViewModel(lock: lock ?? MockVaultLocking(lockMode: .none), preferences: preferences)
    }

    @Test("No Lock is selected by default")
    func noLockIsDefault() {
        #expect(makeViewModel().selectedOption == .none)
    }

    @Test("There are three options: none, password, password + biometrics")
    func threeOptions() {
        #expect(SetupWizardOption.allCases == [.none, .password, .passwordAndBiometrics])
    }

    @Test("Option titles name the device's biometric kind")
    func optionTitles() {
        let faceID = makeViewModel(lock: MockVaultLocking(lockMode: .none, biometricKind: .faceID))
        let touchID = makeViewModel(lock: MockVaultLocking(lockMode: .none, biometricKind: .touchID))
        #expect(faceID.title(for: .none) == "No Lock")
        #expect(faceID.title(for: .password) == "Password")
        #expect(faceID.title(for: .passwordAndBiometrics) == "Password + Face ID")
        #expect(touchID.title(for: .passwordAndBiometrics) == "Password + Touch ID")
    }

    @Test("With no biometric kind the biometric option is titled Password + Biometrics")
    func biometricOptionTitleWithoutKind() {
        let viewModel = makeViewModel(
            lock: MockVaultLocking(lockMode: .none, biometricKind: BiometricKind.none, biometricsAvailable: false))
        #expect(viewModel.title(for: .passwordAndBiometrics) == "Password + Biometrics")
    }

    @Test("Cancelling the password prompt hides it")
    func cancelPasswordPromptHidesPrompt() async {
        let viewModel = makeViewModel()
        viewModel.select(.password)
        await viewModel.continueTapped()
        #expect(viewModel.isPasswordPromptVisible)
        viewModel.cancelPasswordPrompt()
        #expect(!viewModel.isPasswordPromptVisible)
    }

    @Test("The biometric option is disabled without biometrics and cannot be selected")
    func biometricOptionDisabledWithoutBiometrics() {
        let viewModel = makeViewModel(lock: MockVaultLocking(lockMode: .none, biometricsAvailable: false))
        #expect(viewModel.isEnabled(.none))
        #expect(viewModel.isEnabled(.password))
        #expect(!viewModel.isEnabled(.passwordAndBiometrics))
        viewModel.select(.passwordAndBiometrics)
        #expect(viewModel.selectedOption == .none)
    }

    @Test("The biometric option is enabled with biometrics and can be selected")
    func biometricOptionEnabledWithBiometrics() {
        let viewModel = makeViewModel()
        #expect(viewModel.isEnabled(.passwordAndBiometrics))
        viewModel.select(.passwordAndBiometrics)
        #expect(viewModel.selectedOption == .passwordAndBiometrics)
    }

    @Test("Continue with No Lock sets up .none, marks setup complete and finishes")
    func continueWithNoLock() async {
        let lock = ScriptedVaultLock()
        let preferences = MockPreferencesStoring()
        let viewModel = makeViewModel(lock: lock, preferences: preferences)
        var finishedCount = 0
        viewModel.onFinished = { finishedCount += 1 }
        await viewModel.continueTapped()
        #expect(lock.setUpModes == [.none])
        #expect(preferences.hasCompletedSetup)
        #expect(viewModel.isFinished)
        #expect(!viewModel.isPasswordPromptVisible)
        #expect(finishedCount == 1)
    }

    @Test(
        "Continue with a password mode asks for a password and sets nothing up yet",
        arguments: [SetupWizardOption.password, .passwordAndBiometrics]
    )
    func continueWithPasswordModeAsksForPassword(option: SetupWizardOption) async {
        let lock = ScriptedVaultLock()
        let preferences = MockPreferencesStoring()
        let viewModel = makeViewModel(lock: lock, preferences: preferences)
        viewModel.select(option)
        await viewModel.continueTapped()
        #expect(viewModel.isPasswordPromptVisible)
        #expect(lock.setUpModes.isEmpty)
        #expect(!preferences.hasCompletedSetup)
        #expect(!viewModel.isFinished)
    }

    @Test("A matching password sets up the password mode and finishes")
    func matchingPasswordSetsUpPassword() async {
        let lock = ScriptedVaultLock()
        let preferences = MockPreferencesStoring()
        let viewModel = makeViewModel(lock: lock, preferences: preferences)
        viewModel.select(.password)
        await viewModel.continueTapped()
        await viewModel.submitPassword("hunter2", confirmation: "hunter2")
        #expect(lock.setUpModes == [.password])
        #expect(lock.setUpPasswords == ["hunter2"])
        #expect(preferences.hasCompletedSetup)
        #expect(viewModel.isFinished)
        #expect(!viewModel.isPasswordPromptVisible)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A matching password sets up password + biometrics when that card is chosen")
    func matchingPasswordSetsUpBiometrics() async {
        let lock = ScriptedVaultLock()
        let viewModel = makeViewModel(lock: lock)
        viewModel.select(.passwordAndBiometrics)
        await viewModel.continueTapped()
        await viewModel.submitPassword("hunter2", confirmation: "hunter2")
        #expect(lock.setUpModes == [.passwordAndBiometrics])
        #expect(viewModel.isFinished)
    }

    @Test("An empty password shows 'Password cannot be empty', closes the prompt and sets nothing up")
    func emptyPasswordIsRejected() async {
        let lock = ScriptedVaultLock()
        let preferences = MockPreferencesStoring()
        let viewModel = makeViewModel(lock: lock, preferences: preferences)
        viewModel.select(.password)
        await viewModel.continueTapped()
        await viewModel.submitPassword("", confirmation: "")
        #expect(viewModel.errorMessage == "Password cannot be empty")
        #expect(!viewModel.isPasswordPromptVisible)
        #expect(lock.setUpModes.isEmpty)
        #expect(!preferences.hasCompletedSetup)
        #expect(!viewModel.isFinished)
    }

    @Test("A mismatched confirmation shows 'Passwords do not match' and sets nothing up")
    func mismatchIsRejected() async {
        let lock = ScriptedVaultLock()
        let preferences = MockPreferencesStoring()
        let viewModel = makeViewModel(lock: lock, preferences: preferences)
        viewModel.select(.password)
        await viewModel.continueTapped()
        await viewModel.submitPassword("hunter2", confirmation: "hunter3")
        #expect(viewModel.errorMessage == "Passwords do not match")
        #expect(!viewModel.isPasswordPromptVisible)
        #expect(lock.setUpModes.isEmpty)
        #expect(!preferences.hasCompletedSetup)
    }

    @Test("A retry after a rejected password can succeed and clears the error")
    func retryAfterRejectionSucceeds() async {
        let lock = ScriptedVaultLock()
        let viewModel = makeViewModel(lock: lock)
        viewModel.select(.password)
        await viewModel.continueTapped()
        await viewModel.submitPassword("hunter2", confirmation: "nope")
        await viewModel.continueTapped()
        await viewModel.submitPassword("hunter2", confirmation: "hunter2")
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isFinished)
    }

    @Test("existingPasswordRequired shows the existing-password message and does not finish")
    func existingPasswordRequiredMessage() async {
        let lock = ScriptedVaultLock()
        lock.setUpError = VaultLockError.existingPasswordRequired
        let preferences = MockPreferencesStoring()
        let viewModel = makeViewModel(lock: lock, preferences: preferences)
        viewModel.select(.password)
        await viewModel.continueTapped()
        await viewModel.submitPassword("hunter2", confirmation: "hunter2")
        #expect(viewModel.errorMessage == "A vault password already exists on this device. Enter that password.")
        #expect(!viewModel.isFinished)
        #expect(!viewModel.isBusy)
        #expect(!preferences.hasCompletedSetup)
    }

    @Test("Another error shows its own message and does not finish")
    func otherErrorShowsItsMessage() async {
        let lock = ScriptedVaultLock()
        lock.setUpError = StubFailure()
        let preferences = MockPreferencesStoring()
        let viewModel = makeViewModel(lock: lock, preferences: preferences)
        viewModel.select(.password)
        await viewModel.continueTapped()
        await viewModel.submitPassword("hunter2", confirmation: "hunter2")
        #expect(viewModel.errorMessage == "The disk is full.")
        #expect(!viewModel.isFinished)
        #expect(!preferences.hasCompletedSetup)
    }

    @Test("A VaultLockError without special handling shows its localized description")
    func lockErrorShowsLocalizedDescription() async {
        let lock = ScriptedVaultLock()
        let error = VaultLockError.keychain(-25300)
        lock.setUpError = error
        let viewModel = makeViewModel(lock: lock)
        viewModel.select(.password)
        await viewModel.continueTapped()
        await viewModel.submitPassword("hunter2", confirmation: "hunter2")
        #expect(viewModel.errorMessage == error.localizedDescription)
    }

    @Test("The view model is busy while setting up and idle afterwards")
    func busyWhileSettingUp() async {
        let lock = ScriptedVaultLock()
        lock.holdsSetUp = true
        let viewModel = makeViewModel(lock: lock)
        viewModel.select(.password)
        await viewModel.continueTapped()
        #expect(!viewModel.isBusy)
        let submission = Task { await viewModel.submitPassword("hunter2", confirmation: "hunter2") }
        #expect(await waitForCondition { lock.isHoldingCall })
        #expect(viewModel.isBusy)
        lock.releaseHeldCall()
        await submission.value
        #expect(!viewModel.isBusy)
        #expect(viewModel.isFinished)
    }

    @Test("The view model is busy while setting up No Lock")
    func busyWhileSettingUpNoLock() async {
        let lock = ScriptedVaultLock()
        lock.holdsSetUp = true
        let viewModel = makeViewModel(lock: lock)
        let continuing = Task { await viewModel.continueTapped() }
        #expect(await waitForCondition { lock.isHoldingCall })
        #expect(viewModel.isBusy)
        lock.releaseHeldCall()
        await continuing.value
        #expect(!viewModel.isBusy)
    }

    @Test("Setup is not marked complete before it succeeds")
    func notCompleteWhileSettingUp() async {
        let lock = ScriptedVaultLock()
        lock.holdsSetUp = true
        let preferences = MockPreferencesStoring()
        let viewModel = makeViewModel(lock: lock, preferences: preferences)
        let continuing = Task { await viewModel.continueTapped() }
        #expect(await waitForCondition { lock.isHoldingCall })
        #expect(!preferences.hasCompletedSetup)
        lock.releaseHeldCall()
        await continuing.value
        #expect(preferences.hasCompletedSetup)
    }
}
