import Foundation

/// The vaults held in memory: an unencrypted vault and encrypted vaults known by their passwords; records every
/// call.
@MainActor
final class MockVaultLocking: VaultLocking {
    /// A recorded call.
    enum Call: Equatable, Sendable {
        case currentUpdates
        case upgradeIfNeeded
        case canCreateVault
        case createVault(name: String)
        case open
        case openWithBiometrics
        case close
        case appWillResignActive
        case appDidEnterBackground
        case changePassword
        case setUsesBiometrics(Bool)
        case deleteCurrentVault
        case openTransferTarget
        case closeTransferTarget(String)
    }

    /// An encrypted vault the mock knows.
    struct Vault: Sendable {
        let id: String
        var name: String
        var password: String
    }

    /// Every call so far, in order.
    private(set) var calls: [Call] = []
    /// The encrypted vaults, by creation order.
    private(set) var vaults: [Vault]
    /// The id of the vault that uses Face ID, if any.
    var biometricVaultID: String?
    /// Whether the user has Pro (more than one encrypted vault allowed).
    var isPro: Bool
    /// When set, `openWithBiometrics()` throws this error.
    var biometricError: VaultLockError?
    /// When set, every throwing call throws this error.
    var errorToThrow: VaultLockError?

    let unencryptedVault: OpenVault
    private(set) var current: OpenVault {
        didSet {
            guard current.id != oldValue.id else { return }
            for continuation in continuations.values { continuation.yield(current) }
        }
    }
    var biometricKind: BiometricKind
    var biometricsAvailable: Bool

    private var continuations: [UUID: AsyncStream<OpenVault>.Continuation] = [:]

    /// The unencrypted vault open, one encrypted vault "My Vault" (password "correct horse") by default, Face ID
    /// available.
    init(
        vaults: [Vault] = [Vault(id: "primary", name: "My Vault", password: "correct horse")],
        biometricVaultID: String? = nil,
        isPro: Bool = false,
        biometricKind: BiometricKind = .faceID,
        biometricsAvailable: Bool = true
    ) {
        self.vaults = vaults
        self.biometricVaultID = biometricVaultID
        self.isPro = isPro
        self.biometricKind = biometricKind
        self.biometricsAvailable = biometricsAvailable
        let unencrypted = OpenVault(
            id: "unencrypted", name: "KoalaTVault", isEncrypted: false, store: MockVaultStoring())
        unencryptedVault = unencrypted
        current = unencrypted
    }

    var hasBiometricVault: Bool {
        guard let biometricVaultID else { return false }
        return vaults.contains { $0.id == biometricVaultID }
    }

    var currentUsesBiometrics: Bool { current.isEncrypted && biometricVaultID == current.id }

    func currentUpdates() -> AsyncStream<OpenVault> {
        calls.append(.currentUpdates)
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.continuations[id] = nil }
            }
        }
    }

    func upgradeIfNeeded() async throws {
        calls.append(.upgradeIfNeeded)
        if let errorToThrow { throw errorToThrow }
    }

    func canCreateVault() async -> Bool {
        calls.append(.canCreateVault)
        return isPro || vaults.isEmpty
    }

    func createVault(name: String, password: String) async throws {
        calls.append(.createVault(name: name))
        if let errorToThrow { throw errorToThrow }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultLockError.emptyName }
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        guard isPro || vaults.isEmpty else { throw VaultLockError.vaultLimitReached }
        guard !vaults.contains(where: { $0.password == password }) else { throw VaultLockError.passwordInUse }
        let vault = Vault(id: UUID().uuidString, name: trimmed, password: password)
        vaults.append(vault)
        current = Self.openVault(vault)
    }

    func open(password: String) async throws {
        calls.append(.open)
        if let errorToThrow { throw errorToThrow }
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        guard let vault = vaults.first(where: { $0.password == password }) else {
            throw VaultLockError.wrongPassword
        }
        guard vault.id != current.id else { return }
        current = Self.openVault(vault)
    }

    func openWithBiometrics() async throws {
        calls.append(.openWithBiometrics)
        guard let biometricVaultID, let vault = vaults.first(where: { $0.id == biometricVaultID }) else {
            throw VaultLockError.noBiometricVault
        }
        guard biometricsAvailable else { throw VaultLockError.biometricsUnavailable }
        if let biometricError { throw biometricError }
        guard vault.id != current.id else { return }
        current = Self.openVault(vault)
    }

    func close() {
        calls.append(.close)
        current = unencryptedVault
    }

    func appWillResignActive() -> Bool {
        calls.append(.appWillResignActive)
        return current.isEncrypted
    }

    func appDidEnterBackground() {
        calls.append(.appDidEnterBackground)
        current = unencryptedVault
    }

    func changePassword(current currentPassword: String, new: String) async throws {
        calls.append(.changePassword)
        if let errorToThrow { throw errorToThrow }
        guard let index = vaults.firstIndex(where: { $0.id == current.id }) else { throw VaultLockError.notOpen }
        guard !new.isEmpty else { throw VaultLockError.emptyPassword }
        guard vaults[index].password == currentPassword else { throw VaultLockError.wrongPassword }
        guard !vaults.contains(where: { $0.id != current.id && $0.password == new }) else {
            throw VaultLockError.passwordInUse
        }
        vaults[index].password = new
    }

    func setUsesBiometrics(_ enabled: Bool) async throws {
        calls.append(.setUsesBiometrics(enabled))
        if let errorToThrow { throw errorToThrow }
        guard current.isEncrypted else { throw VaultLockError.notOpen }
        if enabled {
            guard biometricsAvailable else { throw VaultLockError.biometricsUnavailable }
            biometricVaultID = current.id
        } else if biometricVaultID == current.id {
            biometricVaultID = nil
        }
    }

    func deleteCurrentVault(password: String) async throws {
        calls.append(.deleteCurrentVault)
        if let errorToThrow { throw errorToThrow }
        guard let index = vaults.firstIndex(where: { $0.id == current.id }) else { throw VaultLockError.notOpen }
        guard vaults[index].password == password else { throw VaultLockError.wrongPassword }
        if biometricVaultID == current.id { biometricVaultID = nil }
        vaults.remove(at: index)
        current = unencryptedVault
    }

    func openTransferTarget(password: String) async throws -> OpenVault {
        calls.append(.openTransferTarget)
        if let errorToThrow { throw errorToThrow }
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        guard let vault = vaults.first(where: { $0.password == password }) else {
            throw VaultLockError.wrongPassword
        }
        guard vault.id != current.id else { throw VaultLockError.sameVault }
        return Self.openVault(vault)
    }

    func closeTransferTarget(_ vault: OpenVault) {
        calls.append(.closeTransferTarget(vault.id))
    }

    private static func openVault(_ vault: Vault) -> OpenVault {
        OpenVault(
            id: vault.id, name: vault.name, isEncrypted: true,
            store: MockVaultStoring(name: vault.name, isEncrypted: true))
    }
}
