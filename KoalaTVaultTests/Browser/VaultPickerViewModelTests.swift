import Foundation
import Testing

@testable import KoalaTVault

// API under test (the shipped public surface):
//
// @MainActor final class VaultPickerViewModel: ObservableObject {
//     init(lock: any VaultLocking, isMove: Bool)
//     let showsUnencryptedRow: Bool          // true when lock.current is encrypted
//     let isMove: Bool
//     var title: String                      // "Move to Vault" / "Copy to Vault"
//     private(set) var password, isBusy, errorMessage
//     var onFinish: ((OpenVault?) -> Void)?  // the chosen target, or nil for Cancel
//     func passwordEdited(_:), unencryptedTapped(), useTapped() async, cancelTapped()
// }

/// A lock whose `openTransferTarget` waits until the test lets it finish, so busy can be observed.
@MainActor
private final class TransferGatedVaultLocking: VaultLocking {
    let inner: MockVaultLocking
    private(set) var openAttempts = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(inner: MockVaultLocking) { self.inner = inner }

    var isWaiting: Bool { continuation != nil }
    func release() {
        continuation?.resume()
        continuation = nil
    }

    func openTransferTarget(password: String) async throws -> OpenVault {
        openAttempts += 1
        await withCheckedContinuation { continuation = $0 }
        return try await inner.openTransferTarget(password: password)
    }

    var current: OpenVault { inner.current }
    var unencryptedVault: OpenVault { inner.unencryptedVault }
    func currentUpdates() -> AsyncStream<OpenVault> { inner.currentUpdates() }
    var biometricKind: BiometricKind { inner.biometricKind }
    var biometricsAvailable: Bool { inner.biometricsAvailable }
    var hasBiometricVault: Bool { inner.hasBiometricVault }
    var currentUsesBiometrics: Bool { inner.currentUsesBiometrics }
    func upgradeIfNeeded() async throws { try await inner.upgradeIfNeeded() }
    func canCreateVault() async -> Bool { await inner.canCreateVault() }
    func createVault(name: String, password: String) async throws {
        try await inner.createVault(name: name, password: password)
    }
    func open(password: String) async throws { try await inner.open(password: password) }
    func openWithBiometrics() async throws { try await inner.openWithBiometrics() }
    func close() { inner.close() }
    func appWillResignActive() -> Bool { inner.appWillResignActive() }
    func appDidEnterBackground() { inner.appDidEnterBackground() }
    func changePassword(current: String, new: String) async throws {
        try await inner.changePassword(current: current, new: new)
    }
    func setUsesBiometrics(_ enabled: Bool) async throws { try await inner.setUsesBiometrics(enabled) }
    func deleteCurrentVault(password: String) async throws {
        try await inner.deleteCurrentVault(password: password)
    }
    func closeTransferTarget(_ vault: OpenVault) { inner.closeTransferTarget(vault) }
}

@MainActor
@Suite struct VaultPickerViewModelTests {
    private static let otherPassword = "battery staple"

    /// A lock with two encrypted vaults; the open one is "My Vault" when `encryptedOpen`.
    private func makeLock(encryptedOpen: Bool) async throws -> MockVaultLocking {
        let lock = MockVaultLocking(
            vaults: [
                .init(id: "primary", name: "My Vault", password: "correct horse"),
                .init(id: "second", name: "Second", password: Self.otherPassword),
            ], isPro: true)
        if encryptedOpen { try await lock.open(password: "correct horse") }
        return lock
    }

    private func makeModel(
        _ lock: any VaultLocking, isMove: Bool = true
    ) -> (VaultPickerViewModel, Box) {
        let model = VaultPickerViewModel(lock: lock, isMove: isMove)
        let box = Box()
        model.onFinish = { box.reports.append($0) }
        return (model, box)
    }

    @MainActor final class Box { var reports: [OpenVault?] = [] }

    // MARK: Unencrypted row

    @Test("The Unencrypted Vault row shows when the open vault is encrypted")
    func rowShownFromEncryptedVault() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        let (model, _) = makeModel(lock)
        #expect(model.showsUnencryptedRow)
    }

    @Test("The Unencrypted Vault row is hidden when the unencrypted vault is open")
    func rowHiddenFromUnencryptedVault() async throws {
        let lock = try await makeLock(encryptedOpen: false)
        let (model, _) = makeModel(lock)
        #expect(!model.showsUnencryptedRow)
    }

    @Test("Choosing the Unencrypted Vault row reports the unencrypted vault as the target")
    func unencryptedRowChosen() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        let (model, box) = makeModel(lock)
        model.unencryptedTapped()
        #expect(box.reports.count == 1)
        #expect(box.reports.first??.id == lock.unencryptedVault.id)
        #expect(box.reports.first??.isEncrypted == false)
        #expect(!lock.calls.contains(.openTransferTarget))
    }

    @Test("Choosing the Unencrypted row twice, then Cancel, reports exactly once")
    func reportsOnlyOnce() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        let (model, box) = makeModel(lock)
        model.unencryptedTapped()
        model.unencryptedTapped()
        model.cancelTapped()
        #expect(box.reports.count == 1)
    }

    @Test("Tapping the Unencrypted Vault row when it is not offered reports nothing")
    func unencryptedRowIgnoredWhenHidden() async throws {
        let lock = try await makeLock(encryptedOpen: false)
        let (model, box) = makeModel(lock)
        model.unencryptedTapped()
        #expect(box.reports.isEmpty)
    }

    // MARK: Use Vault

    @Test("A password with Use Vault opens that vault as the target and reports it")
    func useVaultOpensTarget() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        let (model, box) = makeModel(lock)
        model.passwordEdited(Self.otherPassword)
        await model.useTapped()
        #expect(lock.calls.contains(.openTransferTarget))
        #expect(box.reports.count == 1)
        #expect(box.reports.first??.id == "second")
        #expect(model.errorMessage == nil)
        #expect(!model.isBusy)
        #expect(model.password.isEmpty)
    }

    @Test("Use Vault works from the unencrypted vault too")
    func useVaultFromUnencrypted() async throws {
        let lock = try await makeLock(encryptedOpen: false)
        let (model, box) = makeModel(lock)
        model.passwordEdited("correct horse")
        await model.useTapped()
        #expect(box.reports.first??.id == "primary")
    }

    @Test("An empty password with Use Vault is ignored")
    func emptyPasswordIgnored() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        let (model, box) = makeModel(lock)
        await model.useTapped()
        #expect(!lock.calls.contains(.openTransferTarget))
        #expect(box.reports.isEmpty)
        #expect(model.errorMessage == nil)
    }

    // MARK: Errors

    @Test("A wrong password shows Incorrect password and reports no target")
    func wrongPassword() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        let (model, box) = makeModel(lock)
        model.passwordEdited("nope")
        await model.useTapped()
        #expect(model.errorMessage == "Incorrect password")
        #expect(box.reports.isEmpty)
        #expect(model.password.isEmpty)
        #expect(!model.isBusy)
    }

    @Test("The open vault's own password shows the already-in-this-vault message")
    func sameVault() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        let (model, box) = makeModel(lock)
        model.passwordEdited("correct horse")
        await model.useTapped()
        #expect(model.errorMessage == "These items are already in this vault.")
        #expect(box.reports.isEmpty)
    }

    @Test("Other errors show their own message")
    func otherErrorShowsItsMessage() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        lock.errorToThrow = .io("Disk full")
        let (model, box) = makeModel(lock)
        model.passwordEdited(Self.otherPassword)
        await model.useTapped()
        #expect(model.errorMessage == "Disk full")
        #expect(box.reports.isEmpty)
    }

    @Test("The error clears when the user edits the password")
    func errorClearsOnTyping() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        let (model, _) = makeModel(lock)
        model.passwordEdited("nope")
        await model.useTapped()
        #expect(model.errorMessage != nil)
        model.passwordEdited("n")
        #expect(model.errorMessage == nil)
        #expect(model.password == "n")
    }

    @Test("The picker can retry after an error")
    func retryAfterError() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        let (model, box) = makeModel(lock)
        model.passwordEdited("nope")
        await model.useTapped()
        model.passwordEdited(Self.otherPassword)
        await model.useTapped()
        #expect(box.reports.first??.id == "second")
    }

    // MARK: Busy

    @Test("Busy while the vault opens, and every action is ignored meanwhile")
    func busyIgnoresActions() async throws {
        let mock = try await makeLock(encryptedOpen: true)
        let gated = TransferGatedVaultLocking(inner: mock)
        let (model, box) = makeModel(gated)
        model.passwordEdited(Self.otherPassword)
        let task = Task { await model.useTapped() }
        while !gated.isWaiting { await Task.yield() }
        #expect(model.isBusy)

        await model.useTapped()
        model.unencryptedTapped()
        model.cancelTapped()
        #expect(gated.openAttempts == 1)
        #expect(box.reports.isEmpty)

        gated.release()
        _ = await task.result
        #expect(!model.isBusy)
        #expect(box.reports.count == 1)
        #expect(box.reports.first??.id == "second")
    }

    // MARK: Cancel

    @Test("Cancel reports no target")
    func cancelReportsNil() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        let (model, box) = makeModel(lock)
        model.cancelTapped()
        #expect(box.reports.count == 1)
        #expect(try #require(box.reports.first) == nil)
        #expect(!lock.calls.contains(.openTransferTarget))
    }

    // MARK: Title

    @Test("The title says Move to Vault for a move and Copy to Vault for a copy")
    func titles() async throws {
        let lock = try await makeLock(encryptedOpen: true)
        #expect(makeModel(lock, isMove: true).0.title == "Move to Vault")
        #expect(makeModel(lock, isMove: false).0.title == "Copy to Vault")
    }
}
