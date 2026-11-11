import Testing

@testable import KoalaTVault

@MainActor
@Suite struct CreateVaultViewModelTests {
    private final class Counter { var done = 0; var pro = 0 }

    private func makeModel(isPro: Bool = false) -> (CreateVaultViewModel, MockVaultLocking, Counter) {
        let mock = MockVaultLocking(isPro: isPro)
        let model = CreateVaultViewModel(lock: mock)
        let counter = Counter()
        model.onDone = { counter.done += 1 }
        model.onNeedsPro = { counter.pro += 1 }
        return (model, mock, counter)
    }

    private func fill(_ model: CreateVaultViewModel, name: String, password: String, confirm: String) {
        model.nameEdited(name)
        model.passwordEdited(password)
        model.confirmationEdited(confirm)
    }

    @Test("An empty or blank name shows Enter a name for the vault", arguments: ["", "   ", "\n "])
    func emptyName(name: String) async {
        let (model, mock, counter) = makeModel(isPro: true)
        fill(model, name: name, password: "pw", confirm: "pw")
        await model.createTapped()
        #expect(model.errorMessage == "Enter a name for the vault")
        #expect(mock.calls.contains(.createVault(name: "")) == false)
        #expect(counter.done == 0)
    }

    @Test("An empty password shows Password cannot be empty")
    func emptyPassword() async {
        let (model, mock, _) = makeModel(isPro: true)
        fill(model, name: "Work", password: "", confirm: "")
        await model.createTapped()
        #expect(model.errorMessage == "Password cannot be empty")
        #expect(mock.vaults.count == 1)
    }

    @Test("Mismatched passwords show Passwords do not match")
    func mismatch() async {
        let (model, mock, _) = makeModel(isPro: true)
        fill(model, name: "Work", password: "a", confirm: "b")
        await model.createTapped()
        #expect(model.errorMessage == "Passwords do not match")
        #expect(mock.vaults.count == 1)
    }

    @Test("The name is checked before the password, the password before the confirmation")
    func checkOrder() async {
        let (model, _, _) = makeModel(isPro: true)
        fill(model, name: " ", password: "", confirm: "x")
        await model.createTapped()
        #expect(model.errorMessage == "Enter a name for the vault")
        fill(model, name: "Work", password: "", confirm: "x")
        await model.createTapped()
        #expect(model.errorMessage == "Password cannot be empty")
    }

    @Test("A valid form creates the vault with the trimmed name and password, then calls done")
    func success() async {
        let (model, mock, counter) = makeModel(isPro: true)
        fill(model, name: "  Work  ", password: "secret", confirm: "secret")
        await model.createTapped()
        #expect(mock.calls.contains(.createVault(name: "Work")))
        #expect(mock.vaults.last?.name == "Work")
        #expect(mock.vaults.last?.password == "secret")
        #expect(counter.done == 1)
        #expect(model.errorMessage == nil)
        #expect(model.isBusy == false)
    }

    @Test("While creating the model is busy with Creating Vault…")
    func busy() async {
        let mock = MockVaultLocking(isPro: true)
        let gated = GatedVaultLocking(base: mock)
        let model = CreateVaultViewModel(lock: gated)
        var done = 0
        model.onDone = { done += 1 }
        fill(model, name: "Work", password: "s", confirm: "s")
        let task = Task { await model.createTapped() }
        while !gated.isWaiting { await Task.yield() }
        #expect(model.isBusy)
        #expect(CreateVaultViewModel.busyMessage == "Creating Vault…")
        #expect(done == 0)
        gated.release()
        await task.value
        #expect(model.isBusy == false)
        #expect(done == 1)
    }

    @Test("A password used by another vault shows Choose a different password. and clears the passwords")
    func passwordInUse() async {
        let (model, _, counter) = makeModel(isPro: true)
        fill(model, name: "Work", password: "correct horse", confirm: "correct horse")
        await model.createTapped()
        #expect(model.errorMessage == "Choose a different password.")
        #expect(model.name == "Work")
        #expect(model.password == "")
        #expect(model.confirmation == "")
        #expect(counter.done == 0)
    }

    @Test("The vault limit asks for Pro")
    func limit() async {
        let (model, _, counter) = makeModel(isPro: false)
        fill(model, name: "Work", password: "other", confirm: "other")
        await model.createTapped()
        #expect(counter.pro == 1)
        #expect(counter.done == 0)
    }

    @Test("Another error shows its message, keeps the name and clears the passwords")
    func otherError() async {
        let (model, mock, counter) = makeModel(isPro: true)
        mock.errorToThrow = .io("disk full")
        fill(model, name: "Work", password: "x", confirm: "x")
        await model.createTapped()
        #expect(model.errorMessage == VaultLockError.io("disk full").errorDescription)
        #expect(model.name == "Work")
        #expect(model.password == "")
        #expect(model.confirmation == "")
        #expect(counter.done == 0)
    }
}
