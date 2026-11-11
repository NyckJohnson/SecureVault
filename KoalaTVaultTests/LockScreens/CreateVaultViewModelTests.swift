import Testing

@testable import KoalaTVault

@MainActor
@Suite struct CreateVaultViewModelTests {
    private final class Counter {
        var done = 0
        var pro = 0
    }

    private struct Fixture {
        let model: CreateVaultViewModel
        let mock: MockVaultLocking
        let counter: Counter
    }

    private func makeModel(isPro: Bool = false) -> Fixture {
        let mock = MockVaultLocking(isPro: isPro)
        let model = CreateVaultViewModel(lock: mock)
        let counter = Counter()
        model.onDone = { counter.done += 1 }
        model.onNeedsPro = { counter.pro += 1 }
        return Fixture(model: model, mock: mock, counter: counter)
    }

    private func createCalls(_ mock: MockVaultLocking) -> Int {
        mock.calls.filter {
            if case .createVault = $0 { return true }
            return false
        }.count
    }

    private func fill(_ model: CreateVaultViewModel, name: String, password: String, confirm: String) {
        model.nameEdited(name)
        model.passwordEdited(password)
        model.confirmationEdited(confirm)
    }

    @Test("An empty or blank name shows Enter a name for the vault", arguments: ["", " ", "   ", "\n "])
    func emptyName(name: String) async {
        let fixture = makeModel(isPro: true)
        let model = fixture.model
        let mock = fixture.mock
        let counter = fixture.counter
        fill(model, name: name, password: "pw", confirm: "pw")
        await model.createTapped()
        #expect(model.errorMessage == "Enter a name for the vault")
        #expect(createCalls(mock) == 0)
        #expect(counter.done == 0)
    }

    @Test("An empty password shows Password cannot be empty")
    func emptyPassword() async {
        let fixture = makeModel(isPro: true)
        let model = fixture.model
        let mock = fixture.mock
        fill(model, name: "Work", password: "", confirm: "")
        await model.createTapped()
        #expect(model.errorMessage == "Password cannot be empty")
        #expect(createCalls(mock) == 0)
        #expect(mock.vaults.count == 1)
    }

    @Test("Mismatched passwords show Passwords do not match")
    func mismatch() async {
        let fixture = makeModel(isPro: true)
        let model = fixture.model
        let mock = fixture.mock
        fill(model, name: "Work", password: "a", confirm: "b")
        await model.createTapped()
        #expect(model.errorMessage == "Passwords do not match")
        #expect(createCalls(mock) == 0)
        #expect(mock.vaults.count == 1)
    }

    @Test("The name is checked before the password, the password before the confirmation")
    func checkOrder() async {
        let fixture = makeModel(isPro: true)
        let model = fixture.model
        fill(model, name: " ", password: "", confirm: "x")
        await model.createTapped()
        #expect(model.errorMessage == "Enter a name for the vault")
        fill(model, name: "Work", password: "", confirm: "x")
        await model.createTapped()
        #expect(model.errorMessage == "Password cannot be empty")
    }

    @Test("A valid form creates the vault with the trimmed name and password, then calls done")
    func success() async {
        let fixture = makeModel(isPro: true)
        let model = fixture.model
        let mock = fixture.mock
        let counter = fixture.counter
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

    @Test(
        "A password used by another vault shows Choose a different password. and clears the passwords")
    func passwordInUse() async {
        let fixture = makeModel(isPro: true)
        let model = fixture.model
        let counter = fixture.counter
        fill(model, name: "Work", password: "correct horse", confirm: "correct horse")
        await model.createTapped()
        #expect(model.errorMessage == "Choose a different password.")
        #expect(model.name == "Work")
        #expect(model.password.isEmpty)
        #expect(model.confirmation.isEmpty)
        #expect(counter.done == 0)
    }

    @Test("The vault limit asks for Pro")
    func limit() async {
        let fixture = makeModel(isPro: false)
        let model = fixture.model
        let counter = fixture.counter
        fill(model, name: "Work", password: "other", confirm: "other")
        await model.createTapped()
        #expect(counter.pro == 1)
        #expect(counter.done == 0)
        #expect(model.name == "Work")
        #expect(model.password.isEmpty)
        #expect(model.confirmation.isEmpty)
    }

    @Test("Another error shows its message, keeps the name and clears the passwords")
    func otherError() async {
        let fixture = makeModel(isPro: true)
        let model = fixture.model
        let mock = fixture.mock
        let counter = fixture.counter
        mock.errorToThrow = .io("disk full")
        fill(model, name: "Work", password: "x", confirm: "x")
        await model.createTapped()
        #expect(model.errorMessage == VaultLockError.io("disk full").errorDescription)
        #expect(model.name == "Work")
        #expect(model.password.isEmpty)
        #expect(model.confirmation.isEmpty)
        #expect(counter.done == 0)
    }
}
