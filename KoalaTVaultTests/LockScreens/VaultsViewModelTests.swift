import Testing

@testable import KoalaTVault

@MainActor
@Suite struct VaultsViewModelTests {
    private func makeModel(
        biometricVaultID: String? = nil, isPro: Bool = false, kind: BiometricKind = .faceID,
        available: Bool = true
    ) -> (VaultsViewModel, MockVaultLocking) {
        let mock = MockVaultLocking(
            biometricVaultID: biometricVaultID, isPro: isPro, biometricKind: kind, biometricsAvailable: available)
        return (VaultsViewModel(lock: mock), mock)
    }

    private final class Counter { var done = 0; var pro = 0; var create = 0 }

    private func wire(_ model: VaultsViewModel) -> Counter {
        let counter = Counter()
        model.onDone = { counter.done += 1 }
        model.onNeedsPro = { counter.pro += 1 }
        model.onCreateVault = { counter.create += 1 }
        return counter
    }

    // MARK: Open

    @Test("Open with an empty password is ignored")
    func openEmptyIgnored() async {
        let (model, mock) = makeModel()
        let counter = wire(model)
        await model.openTapped()
        #expect(mock.calls.contains(.open) == false)
        #expect(counter.done == 0)
        #expect(model.errorMessage == nil)
    }

    @Test("Open with the right password calls done and clears the field")
    func openSuccess() async {
        let (model, mock) = makeModel()
        let counter = wire(model)
        model.passwordEdited("correct horse")
        await model.openTapped()
        #expect(counter.done == 1)
        #expect(model.password == "")
        #expect(model.errorMessage == nil)
        #expect(mock.current.isEncrypted)
    }

    @Test("A wrong password shows Incorrect password and clears the field")
    func openWrong() async {
        let (model, _) = makeModel()
        let counter = wire(model)
        model.passwordEdited("nope")
        await model.openTapped()
        #expect(model.errorMessage == "Incorrect password")
        #expect(model.password == "")
        #expect(counter.done == 0)
        #expect(model.isBusy == false)
    }

    @Test("Another error shows its message and clears the field")
    func openOtherError() async {
        let (model, mock) = makeModel()
        mock.errorToThrow = .io("disk full")
        model.passwordEdited("x")
        await model.openTapped()
        #expect(model.errorMessage == VaultLockError.io("disk full").errorDescription)
        #expect(model.password == "")
    }

    @Test("While opening the model is busy with Opening… and done only follows afterwards")
    func openBusy() async {
        let mock = MockVaultLocking()
        let gated = GatedVaultLocking(base: mock)
        let model = VaultsViewModel(lock: gated)
        let counter = wire(model)
        model.passwordEdited("correct horse")
        let task = Task { await model.openTapped() }
        while !gated.isWaiting { await Task.yield() }
        #expect(model.isBusy)
        #expect(VaultsViewModel.busyMessage == "Opening…")
        #expect(counter.done == 0)
        gated.release()
        await task.value
        #expect(model.isBusy == false)
        #expect(counter.done == 1)
    }

    @Test("Open Unencrypted Vault is ignored while busy")
    func unencryptedIgnoredWhileBusy() async {
        let mock = MockVaultLocking()
        let gated = GatedVaultLocking(base: mock)
        let model = VaultsViewModel(lock: gated)
        let counter = wire(model)
        model.passwordEdited("correct horse")
        let task = Task { await model.openTapped() }
        while !gated.isWaiting { await Task.yield() }
        model.unencryptedTapped()
        #expect(mock.calls.contains(.close) == false)
        gated.release()
        await task.value
        #expect(counter.done == 1)
    }

    @Test("Typing clears an error")
    func typingClearsError() async {
        let (model, _) = makeModel()
        model.passwordEdited("nope")
        await model.openTapped()
        #expect(model.errorMessage != nil)
        model.passwordEdited("n")
        #expect(model.errorMessage == nil)
        #expect(model.password == "n")
    }

    // MARK: Face ID

    @Test("The Face ID button shows only when a vault has Face ID and biometrics are available")
    func biometricVisibility() {
        #expect(makeModel(biometricVaultID: "primary").0.showsBiometricButton)
        #expect(makeModel(biometricVaultID: nil).0.showsBiometricButton == false)
        #expect(makeModel(biometricVaultID: "primary", available: false).0.showsBiometricButton == false)
    }

    @Test("The button title names the biometric kind")
    func biometricTitle() {
        #expect(makeModel(biometricVaultID: "primary", kind: .faceID).0.biometricButtonTitle == "Use Face ID")
        #expect(makeModel(biometricVaultID: "primary", kind: .touchID).0.biometricButtonTitle == "Use Touch ID")
    }

    @Test("No biometric prompt happens automatically")
    func noAutomaticPrompt() async {
        let (model, mock) = makeModel(biometricVaultID: "primary")
        _ = wire(model)
        await Task.yield()
        #expect(mock.calls.contains(.openWithBiometrics) == false)
    }

    @Test("Tapping Face ID opens the vault and calls done")
    func biometricSuccess() async {
        let (model, mock) = makeModel(biometricVaultID: "primary")
        let counter = wire(model)
        await model.biometricTapped()
        #expect(counter.done == 1)
        #expect(mock.current.id == "primary")
        #expect(model.errorMessage == nil)
    }

    @Test("Face ID errors show their texts", arguments: [
        (VaultLockError.biometryLockedOut, "Too many attempts. Use your password."),
        (.biometryNotEnrolled, "Face ID is not set up."),
        (.passcodeNotSet, "Set a device passcode to use Face ID."),
        (.biometricChanged, "Face ID changed. Use your password."),
        (.keychain(1), "Biometric authentication failed"),
    ])
    func biometricErrors(error: VaultLockError, text: String) async {
        let (model, mock) = makeModel(biometricVaultID: "primary")
        mock.biometricError = error
        let counter = wire(model)
        await model.biometricTapped()
        #expect(model.errorMessage == text)
        #expect(counter.done == 0)
    }

    @Test("A cancelled Face ID shows nothing")
    func biometricCancelled() async {
        let (model, mock) = makeModel(biometricVaultID: "primary")
        mock.biometricError = .biometricCancelled
        let counter = wire(model)
        await model.biometricTapped()
        #expect(model.errorMessage == nil)
        #expect(counter.done == 0)
        #expect(model.showsBiometricButton)
    }

    @Test("Face ID changed hides the button")
    func biometricChangedHides() async {
        let (model, mock) = makeModel(biometricVaultID: "primary")
        mock.biometricError = .biometricChanged
        await model.biometricTapped()
        #expect(model.showsBiometricButton == false)
    }

    @Test("Typing clears a Face ID error")
    func typingClearsBiometricError() async {
        let (model, mock) = makeModel(biometricVaultID: "primary")
        mock.biometricError = .biometryLockedOut
        await model.biometricTapped()
        model.passwordEdited("a")
        #expect(model.errorMessage == nil)
    }

    // MARK: Create / unencrypted

    @Test("Create New Vault goes to the Create Vault screen when a vault can be created")
    func createAllowed() async {
        let (model, _) = makeModel(isPro: true)
        let counter = wire(model)
        await model.createTapped()
        #expect(counter.create == 1)
        #expect(counter.pro == 0)
    }

    @Test("Create New Vault asks for Pro when no vault can be created")
    func createNeedsPro() async {
        let (model, _) = makeModel(isPro: false)
        let counter = wire(model)
        await model.createTapped()
        #expect(counter.pro == 1)
        #expect(counter.create == 0)
    }

    @Test("Open Unencrypted Vault closes the vault and calls done")
    func unencrypted() {
        let (model, mock) = makeModel()
        let counter = wire(model)
        model.unencryptedTapped()
        #expect(mock.calls.last == .close)
        #expect(mock.current.id == mock.unencryptedVault.id)
        #expect(counter.done == 1)
    }
}
