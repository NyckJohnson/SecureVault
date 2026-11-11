import CryptoKit
import Foundation
import Testing
import os

@testable import KoalaTVault

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

/// Makes the fast key stores of a test and remembers them, so tests can see which keys are loaded and inject
/// failures. A vault's "blob" is its password's UTF-8 bytes in the shared in-memory Keychain (no PBKDF2).
final class KeyShelf: Sendable {
    static let blobPrefix = "com.KoalaTVault.masterKeyBlob"
    static let biometricAccount = "com.KoalaTVault.biometricMasterKey"

    private struct State: Sendable {
        var instances: [String: [FastKeyStore]] = [:]
        var failures: [String: VaultCryptoError] = [:]
        var events: [String] = []
        var gates: [String: KeyGate] = [:]
        var claimed: Set<String> = []
        var entered: [String: Int] = [:]
    }

    let keychain: MockKeychainAccessing
    let vaultsFolder: URL
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(keychain: MockKeychainAccessing, vaultsFolder: URL) {
        self.keychain = keychain
        self.vaultsFolder = vaultsFolder
    }

    /// The 32 key bytes of the vault whose blob account is `account` (different for every vault).
    static func keyData(for account: String) -> Data {
        Data(SHA256.hash(data: Data(account.utf8)))
    }

    /// A new key store for `account`; every instance shares the Keychain items.
    func make(account: String) -> FastKeyStore {
        let store = FastKeyStore(shelf: self, account: account)
        state.withLock { $0.instances[account, default: []].append(store) }
        return store
    }

    /// Whether any key store of `account` has its key loaded.
    func isLoaded(account: String) -> Bool {
        let stores = state.withLock { $0.instances[account] ?? [] }
        return stores.contains { $0.isKeyLoaded }
    }

    /// The key bytes loaded by a store of `account`, or nil.
    func loadedKey(account: String) -> Data? {
        let stores = state.withLock { $0.instances[account] ?? [] }
        return stores.compactMap { $0.loadedKeyData }.first
    }

    /// Makes every call of `operation` (a `MasterKeyStoring` method name) throw `error`.
    func fail(_ operation: String, with error: VaultCryptoError) {
        state.withLock { $0.failures[operation] = error }
    }

    var events: [String] { state.withLock { $0.events } }

    /// Makes the first call of `operation` block (on its own thread) until `release(_:)`.
    func hold(_ operation: String) { state.withLock { $0.gates[operation] = KeyGate() } }

    /// Lets the held call of `operation` go on; later calls are not held.
    func release(_ operation: String) {
        let gate = state.withLock { $0.gates.removeValue(forKey: operation) }
        gate?.open()
    }

    /// How many calls of `operation` have started (held or not).
    func enteredCount(_ operation: String) -> Int { state.withLock { $0.entered[operation] ?? 0 } }

    /// Counts the call and returns the gate it must wait on, if it is the held one.
    func enter(_ operation: String) -> KeyGate? {
        state.withLock { state in
            state.entered[operation, default: 0] += 1
            guard let gate = state.gates[operation], !state.claimed.contains(operation) else { return nil }
            state.claimed.insert(operation)
            return gate
        }
    }

    /// Every key store made for `account`, oldest first.
    func instances(account: String) -> [FastKeyStore] { state.withLock { $0.instances[account] ?? [] } }

    /// The accounts that have a key store with its key loaded, sorted.
    func loadedAccounts() -> [String] {
        let all = state.withLock { $0.instances }
        return all.filter { $0.value.contains { $0.isKeyLoaded } }.map(\.key).sorted()
    }

    func failure(for operation: String) -> VaultCryptoError? { state.withLock { $0.failures[operation] } }

    func record(_ event: String) { state.withLock { $0.events.append(event) } }

    /// The vault ID of a blob account.
    func vaultID(of account: String) -> String {
        let prefix = Self.blobPrefix + "."
        return account.hasPrefix(prefix) ? String(account.dropFirst(prefix.count)) : "primary"
    }
}

/// Blocks the thread that waits on it until opened.
final class KeyGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() { _ = semaphore.wait(timeout: .now() + 8) }

    func open() {
        for _ in 0..<8 { semaphore.signal() }
    }
}

/// A key store whose blob is the password's bytes in the Keychain item `account`.
final class FastKeyStore: MasterKeyStoring {
    private let shelf: KeyShelf
    let account: String
    private let loaded = OSAllocatedUnfairLock<Data?>(initialState: nil)
    private let unlocks = OSAllocatedUnfairLock(initialState: 0)
    private let wipes = OSAllocatedUnfairLock(initialState: 0)

    /// How many times `unlock(password:)` was called.
    var unlockCalls: Int { unlocks.withLock { $0 } }
    /// How many times `wipeKey()` was called.
    var wipeCalls: Int { wipes.withLock { $0 } }

    init(shelf: KeyShelf, account: String) {
        self.shelf = shelf
        self.account = account
    }

    var isKeyLoaded: Bool { loaded.withLock { $0 != nil } }
    var loadedKeyData: Data? { loaded.withLock { $0 } }

    func hasMasterKeyBlob() throws -> Bool {
        try shelf.keychain.read(account: account, prompt: nil) != nil
    }

    func createMasterKey(password: String) throws {
        try begin("createMasterKey")
        guard !password.isEmpty else { throw VaultCryptoError.emptyPassword }
        guard try shelf.keychain.read(account: account, prompt: nil) == nil else {
            throw VaultCryptoError.masterKeyAlreadyExists
        }
        try shelf.keychain.write(Data(password.utf8), account: account, accessibility: .whenUnlocked)
        load(KeyShelf.keyData(for: account))
    }

    func unlock(password: String) throws {
        unlocks.withLock { $0 += 1 }
        try begin("unlock")
        shelf.record("unlock:\(shelf.vaultID(of: account))")
        guard let blob = try shelf.keychain.read(account: account, prompt: nil) else {
            throw VaultCryptoError.noMasterKeyBlob
        }
        guard blob == Data(password.utf8) else { throw VaultCryptoError.wrongPassword }
        load(KeyShelf.keyData(for: account))
    }

    func rewrap(newPassword: String) throws {
        try begin("rewrap")
        guard isKeyLoaded else { throw VaultCryptoError.noKeyLoaded }
        try shelf.keychain.write(Data(newPassword.utf8), account: account, accessibility: .whenUnlocked)
    }

    func deleteMasterKeyBlob() throws {
        try begin("deleteMasterKeyBlob")
        let folder = shelf.vaultsFolder.appendingPathComponent(shelf.vaultID(of: account))
        let exists = FileManager.default.fileExists(atPath: folder.path)
        shelf.record("deleteBlob:folderExists=\(exists)")
        try shelf.keychain.delete(account: account)
    }

    func storeBiometricKey() throws {
        guard let key = loadedKeyData else { throw VaultCryptoError.noKeyLoaded }
        try begin("storeBiometricKey")
        try shelf.keychain.write(
            key, account: KeyShelf.biometricAccount, accessibility: .biometryCurrentSetThisDeviceOnly)
    }

    func unlockWithBiometricKey(prompt: String) throws {
        try begin("unlockWithBiometricKey")
        guard let key = try shelf.keychain.read(account: KeyShelf.biometricAccount, prompt: prompt) else {
            throw VaultCryptoError.biometricItemMissing
        }
        load(key)
    }

    func deleteBiometricKey() throws {
        try begin("deleteBiometricKey")
        try shelf.keychain.delete(account: KeyShelf.biometricAccount)
    }

    func wipeKey() {
        wipes.withLock { $0 += 1 }
        shelf.record("wipeKey:\(shelf.vaultID(of: account))")
        loaded.withLock { $0 = nil }
    }

    func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        guard let data = loadedKeyData else { throw VaultCryptoError.noKeyLoaded }
        return try body(SymmetricKey(data: data))
    }

    private func begin(_ operation: String) throws {
        shelf.enter(operation)?.wait()
        if let error = shelf.failure(for: operation) { throw error }
    }

    private func load(_ data: Data) { loaded.withLock { $0 = data } }
}

/// Makes the vault stores of a test (in-memory mocks) and remembers them by vault ID.
final class VaultStoreRegistry: Sendable {
    private struct State: Sendable {
        var stores: [String: [MockVaultStoring]] = [:]
        var mismatching: Set<String> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Makes `keyMatchesVault()` answer false for stores created for `vaultID` from now on.
    func keyDoesNotMatch(_ vaultID: String) { state.withLock { _ = $0.mismatching.insert(vaultID) } }

    /// The store factory the lock is given.
    @Sendable func build(
        root: URL, name: String, isEncrypted: Bool, keyStore: any MasterKeyStoring, cipher: any FileCipher
    ) -> any VaultStoring {
        make(root: root, name: name, isEncrypted: isEncrypted)
    }

    func make(root: URL, name: String, isEncrypted: Bool) -> MockVaultStoring {
        let id = root.lastPathComponent
        let store = MockVaultStoring(withSampleContent: false, name: name, isEncrypted: isEncrypted)
        state.withLock { state in
            if state.mismatching.contains(id) { store.keyMatches = false }
            state.stores[id, default: []].append(store)
        }
        return store
    }

    /// Whether any store made for `vaultID` was told to remove all its temporary files.
    func removedTemporaryFiles(_ vaultID: String) -> Bool {
        let stores = state.withLock { $0.stores[vaultID] ?? [] }
        return stores.contains { $0.calls.contains(.removeAllTemporaryFiles) }
    }
}

/// One encrypted vault to put on disk and in the Keychain before the lock is made.
struct SeedVault {
    let id: String
    /// The name in `.vault_info`; nil leaves the file out.
    var name: String?
    let password: String
    var faceID = false
}

/// Everything a LiveVaultLock test needs: temp folders, the in-memory Keychain, fast key stores, mock stores.
/// Seed vaults and files before the first use of `lock`.
@MainActor
final class VaultLockFixture {
    let root: URL
    let documents: URL
    let vaultsFolder: URL
    let keychain = MockKeychainAccessing()
    let preferences: MockPreferencesStoring
    let pro: MockProUnlocking
    let probe: FakeBiometricProbe
    let shelf: KeyShelf
    let registry = VaultStoreRegistry()
    let unencryptedStore = MockVaultStoring(withSampleContent: false, name: "KoalaTVault", isEncrypted: false)
    private let cipherError = OSAllocatedUnfairLock<VaultCryptoError?>(initialState: nil)

    init(
        pro isPro: Bool = false,
        upgraded: Bool = true,
        lockMode: LockMode = .none,
        canEvaluate: Bool = true,
        biometricKind: BiometricKind = .faceID,
        vaults: [SeedVault] = []
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        documents = root.appendingPathComponent("Documents")
        vaultsFolder = root.appendingPathComponent("AppSupport").appendingPathComponent("Vaults")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: vaultsFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        preferences = MockPreferencesStoring(lockMode: lockMode, vaultsUpgraded: upgraded)
        pro = MockProUnlocking(isUnlocked: isPro)
        probe = FakeBiometricProbe(kind: biometricKind, canEvaluate: canEvaluate)
        shelf = KeyShelf(keychain: keychain, vaultsFolder: vaultsFolder)
        for vault in vaults { try seed(vault) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// The lock under test, made on first use.
    lazy var lock: LiveVaultLock = makeLock()

    private func makeLock() -> LiveVaultLock {
        let shelf = self.shelf
        let registry = self.registry
        let cipherError = self.cipherError
        return LiveVaultLock(
            documents: documents,
            vaultsFolder: vaultsFolder,
            unencryptedStore: unencryptedStore,
            keychain: keychain,
            preferences: preferences,
            pro: pro,
            biometricInfo: BiometricInfo(probe: probe),
            makeKeyStore: { account in shelf.make(account: account) },
            makeCipher: { _ in Self.makeCipher(failing: cipherError.withLock { $0 }) },
            makeStore: registry.build)
    }

    private nonisolated static func makeCipher(failing error: VaultCryptoError?) -> MockFileCipher {
        let cipher = MockFileCipher()
        cipher.errorToThrow = error
        return cipher
    }

    /// Makes every cipher the lock creates from now on throw `error` (so writing a name fails).
    func failCiphers(with error: VaultCryptoError) { cipherError.withLock { $0 = error } }

    /// Puts an encrypted vault on disk and its blob in the Keychain.
    func seed(_ vault: SeedVault) throws {
        let folder = vaultsFolder.appendingPathComponent(vault.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let account = VaultCatalog.blobAccount(for: vault.id)
        try keychain.write(Data(vault.password.utf8), account: account, accessibility: .whenUnlocked)
        if let name = vault.name {
            let catalog = VaultCatalog(vaultsFolder: vaultsFolder, keychain: keychain)
            try catalog.writeName(name, of: vault.id, cipher: MockFileCipher())
        }
        if vault.faceID { try giveFaceID(to: vault.id) }
    }

    /// Makes `vaultID` the Face ID vault: its key in the biometric item and the marker naming it.
    func giveFaceID(to vaultID: String) throws {
        let account = VaultCatalog.blobAccount(for: vaultID)
        try keychain.write(
            KeyShelf.keyData(for: account), account: KeyShelf.biometricAccount,
            accessibility: .biometryCurrentSetThisDeviceOnly)
        try keychain.write(
            Data(vaultID.utf8), account: VaultCatalog.markerAccount, accessibility: .whenUnlocked)
    }

    /// Puts a blobless folder (an interrupted creation) under `Vaults/`, with the given file names inside.
    func seedBloblessFolder(_ id: String, files: [String] = []) throws {
        let folder = vaultsFolder.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files { try Data("x".utf8).write(to: folder.appendingPathComponent(file)) }
    }

    func blobAccount(_ id: String) -> String { VaultCatalog.blobAccount(for: id) }

    func blob(of id: String) -> Data? { keychain.items[VaultCatalog.blobAccount(for: id)] }

    var marker: String? {
        keychain.items[VaultCatalog.markerAccount].flatMap { String(bytes: $0, encoding: .utf8) }
    }

    var biometricItem: Data? { keychain.items[KeyShelf.biometricAccount] }

    /// The names of the entries under `Vaults/`, sorted; empty when the folder is missing.
    var vaultFolderNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: vaultsFolder.path)) ?? []).sorted()
    }

    func folderExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: vaultsFolder.appendingPathComponent(id).path)
    }

    /// The name stored in the vault's `.vault_info`, or nil.
    func storedName(of id: String) -> String? {
        VaultCatalog(vaultsFolder: vaultsFolder, keychain: keychain).readName(of: id, cipher: MockFileCipher())
    }

    func isLoaded(_ id: String) -> Bool { shelf.isLoaded(account: blobAccount(id)) }

    /// Waits (up to three seconds) until a call of `operation` has started on a key store.
    func waitUntilEntered(_ operation: String, above baseline: Int = 0) async {
        for _ in 0..<600 {
            if shelf.enteredCount(operation) > baseline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(operation) was never called")
    }

    /// Runs `call` with the first `operation` held, runs `interrupt` while it is held, then releases it.
    func runHeld(
        _ operation: String, interrupt: Interrupt, call: @escaping @MainActor () async throws -> Void
    ) async -> Result<Void, any Error> {
        let baseline = shelf.enteredCount(operation)
        shelf.hold(operation)
        let task = Task { @MainActor in try await call() }
        await waitUntilEntered(operation, above: baseline)
        await interrupt.run(on: lock)
        shelf.release(operation)
        return await task.result
    }
}

/// What happens to the lock while a password check is in progress.
enum Interrupt: Sendable, CaseIterable {
    case close, background, openBravo

    /// The vault ID that is current afterwards.
    var currentID: String { self == .openBravo ? "bbbb-2" : "unencrypted" }

    @MainActor
    func run(on lock: LiveVaultLock) async {
        switch self {
        case .close: lock.close()
        case .background: lock.appDidEnterBackground()
        case .openBravo: try? await lock.open(password: "bravo pw")
        }
    }
}

/// Records an issue unless `result` is a failure with exactly `expected`.
func expectFailure(
    _ result: Result<Void, any Error>, _ expected: VaultLockError, sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success: Issue.record("Expected \(expected) but the call succeeded", sourceLocation: sourceLocation)
    case .failure(let error):
        #expect((error as? VaultLockError) == expected, sourceLocation: sourceLocation)
    }
}

/// Collects the vault IDs `currentUpdates()` publishes.
@MainActor
final class CurrentCollector {
    private(set) var ids: [String] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<OpenVault>) {
        task = Task { [weak self] in
            for await vault in stream { self?.ids.append(vault.id) }
        }
    }

    /// Lets queued deliveries run so `ids` is up to date.
    func settle() async {
        for _ in 0..<60 { await Task.yield() }
    }

    deinit { task?.cancel() }
}

/// Runs `body` and records an issue unless it throws exactly `expected`.
@MainActor
func expectLockError(
    _ expected: VaultLockError, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @MainActor () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("Expected \(expected) but nothing was thrown", sourceLocation: sourceLocation)
    } catch let error as VaultLockError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected \(expected) but got \(error)", sourceLocation: sourceLocation)
    }
}
