import CryptoKit
import Foundation
import os

@testable import KoalaTVault

/// A thread-safe ordered log shared by the doubles so tests can assert the order of steps across collaborators.
final class VaultLockEventLog: Sendable {
    private let storage = OSAllocatedUnfairLock<[String]>(initialState: [])

    var events: [String] { storage.withLock { $0 } }

    func record(_ event: String) { storage.withLock { $0.append(event) } }

    /// Index of the first occurrence of `event`, or nil.
    func index(of event: String) -> Int? { events.firstIndex(of: event) }
}

/// A thread-safe boolean flag.
final class VaultLockFlag: Sendable {
    private let storage: OSAllocatedUnfairLock<Bool>
    init(_ value: Bool) { storage = OSAllocatedUnfairLock(initialState: value) }
    var value: Bool {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// A master-key store with per-call failure injection that logs each call to a shared log.
/// Event names equal the method names: "hasMasterKeyBlob", "createMasterKey", "unlock", "rewrap",
/// "deleteMasterKeyBlob", "storeBiometricKey", "unlockWithBiometricKey", "deleteBiometricKey", "wipeKey".
final class ScriptedMasterKeys: MasterKeyStoring {
    private struct State: Sendable {
        var password: String?
        var keyLoaded: Bool
        var hasBiometricKey: Bool
        var failures: [String: VaultCryptoError] = [:]
        var anyFailures: [String: any Error] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>
    private let log: VaultLockEventLog

    init(log: VaultLockEventLog, password: String?, keyLoaded: Bool, hasBiometricKey: Bool) {
        self.log = log
        state = OSAllocatedUnfairLock(
            initialState: State(password: password, keyLoaded: keyLoaded, hasBiometricKey: hasBiometricKey))
    }

    /// The password wrapping the blob; nil when there is no blob.
    var password: String? { state.withLock { $0.password } }
    var hasBiometricKey: Bool { state.withLock { $0.hasBiometricKey } }
    var isKeyLoaded: Bool { state.withLock { $0.keyLoaded } }

    /// Calls named here throw the given error (after being logged) and change nothing.
    var failures: [String: VaultCryptoError] {
        get { state.withLock { $0.failures } }
        set { state.withLock { $0.failures = newValue } }
    }

    /// Like `failures`, but for errors that are not `VaultCryptoError`.
    var anyFailures: [String: any Error] {
        get { state.withLock { $0.anyFailures } }
        set { state.withLock { $0.anyFailures = newValue } }
    }

    func hasMasterKeyBlob() throws -> Bool {
        try perform("hasMasterKeyBlob") { $0.password != nil }
    }

    func createMasterKey(password: String) throws {
        try perform("createMasterKey") { state in
            guard !password.isEmpty else { throw VaultCryptoError.emptyPassword }
            guard state.password == nil else { throw VaultCryptoError.masterKeyAlreadyExists }
            state.password = password
            state.keyLoaded = true
        }
    }

    func unlock(password: String) throws {
        try perform("unlock") { state in
            guard let stored = state.password else { throw VaultCryptoError.noMasterKeyBlob }
            guard stored == password else { throw VaultCryptoError.wrongPassword }
            state.keyLoaded = true
        }
    }

    func rewrap(newPassword: String) throws {
        try perform("rewrap") { state in
            guard state.keyLoaded else { throw VaultCryptoError.noKeyLoaded }
            state.password = newPassword
        }
    }

    func deleteMasterKeyBlob() throws {
        try perform("deleteMasterKeyBlob") { $0.password = nil }
    }

    func storeBiometricKey() throws {
        try perform("storeBiometricKey") { state in
            guard state.keyLoaded else { throw VaultCryptoError.noKeyLoaded }
            state.hasBiometricKey = true
        }
    }

    func unlockWithBiometricKey(prompt: String) throws {
        try perform("unlockWithBiometricKey") { state in
            guard state.hasBiometricKey else { throw VaultCryptoError.biometricItemMissing }
            state.keyLoaded = true
        }
    }

    func deleteBiometricKey() throws {
        try perform("deleteBiometricKey") { $0.hasBiometricKey = false }
    }

    func wipeKey() {
        log.record("wipeKey")
        state.withLock { $0.keyLoaded = false }
    }

    func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        let loaded = state.withLock { $0.keyLoaded }
        guard loaded else { throw VaultCryptoError.noKeyLoaded }
        return try body(SymmetricKey(data: Data(repeating: 0x2A, count: 32)))
    }

    private func perform<R: Sendable>(_ name: String, _ body: @Sendable (inout State) throws -> R) throws -> R {
        log.record(name)
        return try state.withLock { state in
            if let error = state.failures[name] { throw error }
            if let error = state.anyFailures[name] { throw error }
            return try body(&state)
        }
    }
}

/// Preferences that log every lockMode write ("lockMode=none", "lockMode=password", "lockMode=passwordAndBiometrics").
final class LoggingPreferences: PreferencesStoring {
    private struct State: Sendable {
        var lockMode: LockMode
        var lockModeWrites: [LockMode] = []
        var hasCompletedSetup = false
        var sortOption = SortOption.name
        var sortDirection = SortDirection.ascending
        var pendingMigration: PendingMigration?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let log: VaultLockEventLog

    init(log: VaultLockEventLog, lockMode: LockMode) {
        self.log = log
        state = OSAllocatedUnfairLock(initialState: State(lockMode: lockMode))
    }

    /// Every value written to `lockMode`, in order.
    var lockModeWrites: [LockMode] { state.withLock { $0.lockModeWrites } }

    var lockMode: LockMode {
        get { state.withLock { $0.lockMode } }
        set {
            log.record("lockMode=\(newValue.rawValue)")
            state.withLock {
                $0.lockMode = newValue; $0.lockModeWrites.append(newValue)
            }
        }
    }

    var hasCompletedSetup: Bool {
        get { state.withLock { $0.hasCompletedSetup } }
        set { state.withLock { $0.hasCompletedSetup = newValue } }
    }

    var sortOption: SortOption {
        get { state.withLock { $0.sortOption } }
        set { state.withLock { $0.sortOption = newValue } }
    }

    var sortDirection: SortDirection {
        get { state.withLock { $0.sortDirection } }
        set { state.withLock { $0.sortDirection = newValue } }
    }

    var pendingMigration: PendingMigration? {
        get { state.withLock { $0.pendingMigration } }
        set { state.withLock { $0.pendingMigration = newValue } }
    }
}

/// A biometric probe whose answer tests set.
final class FakeBiometricProbe: BiometricProbing {
    private struct ProbeState {
        var kind: BiometricKind
        var canEvaluate: Bool
        var probeCount = 0
    }

    private let state: OSAllocatedUnfairLock<ProbeState>

    init(kind: BiometricKind, canEvaluate: Bool) {
        state = OSAllocatedUnfairLock(initialState: ProbeState(kind: kind, canEvaluate: canEvaluate))
    }

    var kind: BiometricKind {
        get { state.withLock { $0.kind } }
        set { state.withLock { $0.kind = newValue } }
    }

    var canEvaluate: Bool {
        get { state.withLock { $0.canEvaluate } }
        set { state.withLock { $0.canEvaluate = newValue } }
    }

    var probeCount: Int { state.withLock { $0.probeCount } }

    func probe() -> (kind: BiometricKind, canEvaluate: Bool) {
        state.withLock { state in
            state.probeCount += 1
            return (state.kind, state.canEvaluate)
        }
    }
}

/// Collects what `stateUpdates()` publishes.
@MainActor
final class LockStateCollector {
    private(set) var values: [LockState] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<LockState>) {
        task = Task { [weak self] in
            for await state in stream { self?.values.append(state) }
        }
    }

    /// Lets queued deliveries run so `values` is up to date.
    func settle() async {
        for _ in 0..<60 { await Task.yield() }
    }

    func stop() { task?.cancel() }
}

/// Everything a LiveVaultLock test needs, wired with doubles.
@MainActor
struct VaultLockHarness {
    let log = VaultLockEventLog()
    let keys: ScriptedMasterKeys
    let prefs: LoggingPreferences
    let keychain = MockKeychainAccessing()
    let store = MockVaultStoring(withSampleContent: false)
    let probe: FakeBiometricProbe
    let encryptedData = VaultLockFlag(false)
    let lock: LiveVaultLock

    /// - Parameters:
    ///   - lockMode: the stored lock mode at launch.
    ///   - blobPassword: the password wrapping the existing blob; nil for no blob.
    ///   - unlocked: whether the key is loaded and the lock already unlocked at the start.
    init(
        lockMode: LockMode = .none,
        blobPassword: String? = nil,
        hasBiometricKey: Bool = false,
        biometricKind: BiometricKind = .faceID,
        biometricsEnabled: Bool = true,
        vaultHasEncryptedData: Bool = false,
        keyMatchesVault: Bool = true,
        unlocked: Bool = false
    ) async throws {
        keys = ScriptedMasterKeys(
            log: log, password: blobPassword, keyLoaded: false, hasBiometricKey: hasBiometricKey)
        prefs = LoggingPreferences(log: log, lockMode: lockMode)
        probe = FakeBiometricProbe(kind: biometricKind, canEvaluate: biometricsEnabled)
        encryptedData.value = vaultHasEncryptedData
        store.keyMatches = keyMatchesVault
        let flag = encryptedData
        lock = LiveVaultLock(
            masterKeys: keys,
            keychain: keychain,
            preferences: prefs,
            store: store,
            biometricInfo: BiometricInfo(probe: probe),
            vaultHoldsEncryptedData: { flag.value })
        if unlocked, let blobPassword {
            try await lock.unlock(password: blobPassword)
        }
    }

    /// Events recorded since the start, ignoring the ones from the harness' own unlock.
    func events(after count: Int = 0) -> [String] { Array(log.events.dropFirst(count)) }
}
