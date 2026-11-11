import Foundation

@testable import KoalaTVault

/// A `VaultLocking` that forwards to a `MockVaultLocking` but suspends `open`, `createVault` and
/// `openWithBiometrics` until `release()` is called, so tests can look at a view model while it is busy.
@MainActor
final class GatedVaultLocking: VaultLocking {
    let base: MockVaultLocking
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isWaiting = false
    /// When set, `openWithBiometrics()` throws this error at once instead of waiting.
    var biometricFailure: (any Error)?

    init(base: MockVaultLocking) { self.base = base }

    /// Lets every suspended call continue.
    func release() {
        let pending = waiters
        waiters = []
        isWaiting = false
        for waiter in pending { waiter.resume() }
    }

    private func gate() async {
        isWaiting = true
        await withCheckedContinuation { waiters.append($0) }
    }

    var unencryptedVault: OpenVault { base.unencryptedVault }
    var current: OpenVault { base.current }
    var biometricKind: BiometricKind { base.biometricKind }
    var biometricsAvailable: Bool { base.biometricsAvailable }
    var hasBiometricVault: Bool { base.hasBiometricVault }
    var currentUsesBiometrics: Bool { base.currentUsesBiometrics }

    func currentUpdates() -> AsyncStream<OpenVault> { base.currentUpdates() }
    func upgradeIfNeeded() async throws { try await base.upgradeIfNeeded() }
    func canCreateVault() async -> Bool { await base.canCreateVault() }
    func createVault(name: String, password: String) async throws {
        await gate()
        try await base.createVault(name: name, password: password)
    }
    func open(password: String) async throws {
        await gate()
        try await base.open(password: password)
    }
    func openWithBiometrics() async throws {
        if let biometricFailure { throw biometricFailure }
        await gate()
        try await base.openWithBiometrics()
    }
    func close() { base.close() }
    func appWillResignActive() -> Bool { base.appWillResignActive() }
    func appDidEnterBackground() { base.appDidEnterBackground() }
    func changePassword(current: String, new: String) async throws {
        try await base.changePassword(current: current, new: new)
    }
    func setUsesBiometrics(_ enabled: Bool) async throws { try await base.setUsesBiometrics(enabled) }
    func deleteCurrentVault(password: String) async throws { try await base.deleteCurrentVault(password: password) }
    func openTransferTarget(password: String) async throws -> OpenVault {
        try await base.openTransferTarget(password: password)
    }
    func closeTransferTarget(_ vault: OpenVault) { base.closeTransferTarget(vault) }
}
