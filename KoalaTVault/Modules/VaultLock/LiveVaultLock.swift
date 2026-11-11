import Foundation
import os

/// The live vaults (feature multiple-vaults-duress-password): the unencrypted vault over Documents, always there,
/// and the encrypted vaults under `Vaults/` (see `VaultCatalog`), each opened by its own password or, for at most
/// one vault, Face ID.
///
/// The lock never lists or counts encrypted vaults for the user: a password opens whichever vault it belongs to,
/// and every failure reads the same (`.wrongPassword`). Key work (PBKDF2, Keychain reads behind a Face ID prompt,
/// the upgrade's file moves) runs off the main actor; the state (`current`, the open key stores) lives on it.
///
/// Races: a password is always tried on a fresh key store, never on the open vault's own. Every close, background
/// or change of `current` bumps `epoch`; a call that awaited key work checks it afterwards and, if it moved, wipes
/// the key it loaded and drops the result (`.notOpen`, except `createVault`, which keeps the finished vault but
/// doesn't open it). `createVault` calls run one at a time.
@MainActor
final class LiveVaultLock: VaultLocking {
    private static let logger = Logger(subsystem: "com.KoalaTVault", category: "VaultLock")
    /// The reason shown with the Face ID prompt.
    nonisolated private static let biometricPrompt = "Unlock your vault"
    private static let unencryptedID = "unencrypted"
    private static let unencryptedName = "KoalaTVault"

    /// A vault whose key a fresh key store has loaded, found by a password.
    private struct Match: Sendable {
        let id: String
        let keyStore: any MasterKeyStoring
    }

    /// An encrypted vault in use (current or a transfer target) and the key store holding its key.
    private struct LoadedVault {
        let vault: OpenVault
        let keyStore: any MasterKeyStoring
    }

    private let catalog: VaultCatalog
    private let upgrade: VaultUpgrade
    private let pro: any ProUnlocking
    private let biometricInfo: BiometricInfo
    private let makeKeyStore: @Sendable (_ blobAccount: String) -> any MasterKeyStoring
    private let makeDecoyKeyStore: @Sendable () -> any MasterKeyStoring
    private let makeCipher: @Sendable (any MasterKeyStoring) -> any FileCipher
    private let makeStore:
        @Sendable (_ root: URL, _ name: String, _ isEncrypted: Bool, any MasterKeyStoring, any FileCipher) ->
            any VaultStoring

    private let state: OpenVaultState
    /// The open encrypted vault (`current`) and its key store; nil while the unencrypted vault is current.
    private var openEncrypted: LoadedVault?
    /// The open transfer targets, by vault ID.
    private var transferTargets: [String: LoadedVault] = [:]
    /// Bumped by every close (background included) and every change of `current`; see the type's notes.
    private var epoch = 0
    /// Whether a `createVault` call is running; later calls wait in `createWaiters`, in order.
    private var isCreating = false
    private var createWaiters: [CheckedContinuation<Void, Never>] = []

    let unencryptedVault: OpenVault

    /// - Parameters:
    ///   - documents: the unencrypted vault's root (Documents), also the source of the one-time upgrade.
    ///   - vaultsFolder: `Application Support/Vaults`, holding one folder per encrypted vault.
    ///   - unencryptedStore: the plaintext store over `documents`.
    ///   - keychain: the Keychain seam, for the vault blobs' existence and the Face ID marker.
    ///   - preferences: the old lock settings and the `vaultsUpgraded` flag, for the upgrade.
    ///   - pro: the Pro entitlement (more than one encrypted vault).
    ///   - biometricInfo: the device's biometrics.
    ///   - makeKeyStore: a key store for a vault's blob account.
    ///   - makeDecoyKeyStore: the decoy key store for password searches with no vault to try (over a private
    ///     in-memory Keychain, never the real one).
    ///   - makeCipher: a cipher over a key store.
    ///   - makeStore: a vault store for a root, name, encrypted flag, key store and cipher.
    init(
        documents: URL, vaultsFolder: URL, unencryptedStore: any VaultStoring, keychain: any KeychainAccessing,
        preferences: any PreferencesStoring, pro: any ProUnlocking, biometricInfo: BiometricInfo,
        makeKeyStore: @escaping @Sendable (_ blobAccount: String) -> any MasterKeyStoring,
        makeDecoyKeyStore: @escaping @Sendable () -> any MasterKeyStoring,
        makeCipher: @escaping @Sendable (any MasterKeyStoring) -> any FileCipher,
        makeStore:
            @escaping @Sendable (
                _ root: URL, _ name: String, _ isEncrypted: Bool, any MasterKeyStoring, any FileCipher
            ) -> any VaultStoring
    ) {
        catalog = VaultCatalog(vaultsFolder: vaultsFolder, keychain: keychain)
        upgrade = VaultUpgrade(
            documents: documents, vaultsFolder: vaultsFolder, keychain: keychain, preferences: preferences)
        self.pro = pro
        self.biometricInfo = biometricInfo
        self.makeKeyStore = makeKeyStore
        self.makeDecoyKeyStore = makeDecoyKeyStore
        self.makeCipher = makeCipher
        self.makeStore = makeStore
        let unencrypted = OpenVault(
            id: Self.unencryptedID, name: Self.unencryptedName, isEncrypted: false, store: unencryptedStore)
        unencryptedVault = unencrypted
        state = OpenVaultState(initial: unencrypted)
    }

    // MARK: State

    var current: OpenVault { state.current }

    func currentUpdates() -> AsyncStream<OpenVault> { state.updates() }

    var biometricKind: BiometricKind { biometricInfo.kind }

    var biometricsAvailable: Bool { biometricInfo.isAvailable }

    var hasBiometricVault: Bool {
        guard let id = catalog.biometricVaultID() else { return false }
        return catalog.vaultIDs().contains(id)
    }

    var currentUsesBiometrics: Bool {
        guard let open = openEncrypted else { return false }
        return catalog.biometricVaultID() == open.vault.id
    }

    // MARK: Launch

    func upgradeIfNeeded() async throws {
        let upgrade = self.upgrade
        let catalog = self.catalog
        do {
            try await Self.offMain {
                try upgrade.run()
                catalog.removeInterruptedCreations()
            }
        } catch {
            throw Self.lockError(from: error)
        }
    }

    // MARK: Opening

    func open(password: String) async throws {
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        let started = epoch
        let match = await findVault(password: password)
        try ensureUninterrupted(since: started, wiping: match?.keyStore)
        guard let match else { throw VaultLockError.wrongPassword }
        guard match.id != openEncrypted?.vault.id else {
            match.keyStore.wipeKey()  // the vault already open: no change
            return
        }
        let loaded = try await load(match, verifyKey: false)
        try ensureUninterrupted(since: started, wiping: loaded.keyStore)
        makeCurrent(loaded)
    }

    func openWithBiometrics() async throws {
        guard let id = catalog.biometricVaultID(), catalog.vaultIDs().contains(id) else {
            throw VaultLockError.noBiometricVault
        }
        guard biometricInfo.isAvailable else { throw VaultLockError.biometricsUnavailable }
        guard id != openEncrypted?.vault.id else { return }
        let started = epoch
        let keyStore = makeKeyStore(VaultCatalog.blobAccount(for: id))
        do {
            try await Self.offMain { try keyStore.unlockWithBiometricKey(prompt: Self.biometricPrompt) }
        } catch VaultCryptoError.biometricItemMissing, VaultCryptoError.invalidKeyData {
            try ensureUninterrupted(since: started, wiping: keyStore)
            forgetFaceID(keyStore: keyStore)
            throw VaultLockError.biometricChanged
        } catch {
            keyStore.wipeKey()
            try ensureUninterrupted(since: started, wiping: nil)
            throw Self.lockError(from: error)
        }
        try ensureUninterrupted(since: started, wiping: keyStore)
        let loaded: LoadedVault
        do {
            loaded = try await load(Match(id: id, keyStore: keyStore), verifyKey: true)
        } catch {
            try ensureUninterrupted(since: started, wiping: keyStore)
            // The biometric key does not open this vault (Face ID was re-enrolled or the item is stale).
            forgetFaceID(keyStore: keyStore)
            throw error
        }
        try ensureUninterrupted(since: started, wiping: keyStore)
        makeCurrent(loaded)
    }

    // MARK: Creating

    func canCreateVault() async -> Bool {
        pro.isUnlocked || catalog.vaultIDs().isEmpty
    }

    func createVault(name: String, password: String) async throws {
        await beginCreating()
        defer { endCreating() }
        let started = epoch
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultLockError.emptyName }
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        guard await canCreateVault() else { throw VaultLockError.vaultLimitReached }
        if let match = await findVault(password: password) {
            match.keyStore.wipeKey()
            throw VaultLockError.passwordInUse
        }

        let id = UUID().uuidString
        let folder = catalog.folderURL(for: id)
        let keyStore = makeKeyStore(VaultCatalog.blobAccount(for: id))
        var blobMade = false
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await Self.offMain { try keyStore.createMasterKey(password: password) }
            blobMade = true
            let cipher = makeCipher(keyStore)
            try catalog.writeName(trimmed, of: id, cipher: cipher)
            guard epoch == started else {
                // Closed meanwhile: the finished vault stays (it opens by its password) but is not opened.
                keyStore.wipeKey()
                return
            }
            let store = makeStore(folder, trimmed, true, keyStore, cipher)
            let vault = OpenVault(id: id, name: trimmed, isEncrypted: true, store: store)
            makeCurrent(LoadedVault(vault: vault, keyStore: keyStore))
        } catch {
            // No half-made vault: remove the folder, then the blob.
            keyStore.wipeKey()
            removeFolderIfPresent(folder)
            if blobMade {
                do {
                    try keyStore.deleteMasterKeyBlob()
                } catch {
                    Self.logger.error("Could not remove the key of an unfinished vault: \(error, privacy: .public)")
                }
            }
            throw Self.lockError(from: error)
        }
    }

    // MARK: Closing

    func close() {
        epoch += 1
        closeTransferTargets()
        guard openEncrypted != nil else { return }
        closeOpenVault()
        state.set(unencryptedVault)
    }

    func appWillResignActive() -> Bool {
        current.isEncrypted
    }

    func appDidEnterBackground() {
        close()
    }

    // MARK: Managing the open vault

    func changePassword(current currentPassword: String, new newPassword: String) async throws {
        guard let open = openEncrypted else { throw VaultLockError.notOpen }
        guard !newPassword.isEmpty else { throw VaultLockError.emptyPassword }
        let started = epoch
        // The fresh store that checked the password holds the key and does the rewrap, so a close meanwhile
        // can't wipe the key under it.
        let checked = try await check(currentPassword, of: open.vault.id, since: started)
        defer { checked.wipeKey() }
        let match = await findVault(password: newPassword, excluding: open.vault.id)
        try ensureUninterrupted(since: started, wiping: match?.keyStore)
        if let match {
            match.keyStore.wipeKey()
            throw VaultLockError.passwordInUse
        }
        do {
            try await Self.offMain { try checked.rewrap(newPassword: newPassword) }
        } catch {
            throw Self.lockError(from: error)
        }
    }

    func setUsesBiometrics(_ enabled: Bool) async throws {
        guard let open = openEncrypted else {
            if enabled { throw VaultLockError.notOpen }
            return  // turning Face ID off in the unencrypted vault: nothing to do
        }
        do {
            if enabled {
                guard biometricInfo.isAvailable else { throw VaultLockError.biometricsUnavailable }
                let started = epoch
                let previousMarker = catalog.biometricVaultID()
                let keyStore = open.keyStore
                // The item is replaced first; the marker moves only once the item holds this vault's key.
                try await Self.offMain { try keyStore.storeBiometricKey() }
                guard epoch == started else {
                    restoreBiometricItem(previousMarker: previousMarker, keyStore: keyStore)
                    throw VaultLockError.notOpen
                }
                // If this write fails, the item holds this vault's key while the marker still names the previous
                // vault: that vault's next Face ID open fails `keyMatchesVault` and ends in `.biometricChanged`,
                // which forgets Face ID (accepted).
                try catalog.setBiometricVaultID(open.vault.id)
            } else if catalog.biometricVaultID() == open.vault.id {
                try open.keyStore.deleteBiometricKey()
                try catalog.setBiometricVaultID(nil)
            }
        } catch {
            throw Self.lockError(from: error)
        }
    }

    func deleteCurrentVault(password: String) async throws {
        guard let open = openEncrypted else { throw VaultLockError.notOpen }
        let started = epoch
        let checked = try await check(password, of: open.vault.id, since: started)
        checked.wipeKey()
        // From here on nothing awaits: the vault cannot be closed part-way.
        let id = open.vault.id
        do {
            if catalog.biometricVaultID() == id {
                try open.keyStore.deleteBiometricKey()
                try catalog.setBiometricVaultID(nil)
            }
            // The folder goes before the blob: a blob with no folder is harmless, a folder with no blob is not a vault.
            try FileManager.default.removeItem(at: catalog.folderURL(for: id))
        } catch {
            throw Self.lockError(from: error)
        }
        do {
            try open.keyStore.deleteMasterKeyBlob()
        } catch {
            close()  // the folder is gone: the vault cannot stay open
            throw Self.lockError(from: error)
        }
        close()
    }

    // MARK: Transfer target

    func openTransferTarget(password: String) async throws -> OpenVault {
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        let started = epoch
        let match = await findVault(password: password)
        try ensureUninterrupted(since: started, wiping: match?.keyStore)
        guard let match else { throw VaultLockError.wrongPassword }
        guard match.id != openEncrypted?.vault.id else {
            match.keyStore.wipeKey()
            throw VaultLockError.sameVault
        }
        let loaded = try await load(match, verifyKey: false)
        try ensureUninterrupted(since: started, wiping: loaded.keyStore)
        if let previous = transferTargets[match.id] { Self.release(previous) }
        transferTargets[match.id] = loaded
        return loaded.vault
    }

    func closeTransferTarget(_ vault: OpenVault) {
        guard let target = transferTargets.removeValue(forKey: vault.id) else { return }
        Self.release(target)
    }

    // MARK: Helpers

    /// The first vault, in sorted ID order, that `password` unlocks (one PBKDF2 per vault tried, off the main
    /// actor), on a fresh key store that then holds its key; nil when none does. The caller adopts or wipes it.
    private func findVault(password: String, excluding excludedID: String? = nil) async -> Match? {
        let ids = catalog.vaultIDs().filter { $0 != excludedID }
        let makeKeyStore = self.makeKeyStore
        return try? await Self.offMain { () -> Match? in
            for id in ids {
                let keyStore = makeKeyStore(VaultCatalog.blobAccount(for: id))
                do {
                    try keyStore.unlock(password: password)
                    return Match(id: id, keyStore: keyStore)
                } catch {
                    continue  // not this vault (or its blob can't be read): try the next one
                }
            }
            return nil
        }
    }

    /// Checks that `password` opens vault `id` on a fresh key store, which is returned with the key loaded (the
    /// caller wipes it).
    /// - Throws: `.notOpen` if the lock changed since `started` (the store is wiped), else the mapped key error
    ///   (`.wrongPassword` for a wrong password).
    private func check(_ password: String, of id: String, since started: Int) async throws -> any MasterKeyStoring {
        let keyStore = makeKeyStore(VaultCatalog.blobAccount(for: id))
        do {
            try await Self.offMain { try keyStore.unlock(password: password) }
        } catch {
            try ensureUninterrupted(since: started, wiping: keyStore)
            throw Self.lockError(from: error)
        }
        try ensureUninterrupted(since: started, wiping: keyStore)
        return keyStore
    }

    /// Throws `.notOpen`, after wiping `keyStore`, when a close or a change of `current` happened since `started`.
    private func ensureUninterrupted(since started: Int, wiping keyStore: (any MasterKeyStoring)?) throws {
        guard epoch != started else { return }
        keyStore?.wipeKey()
        throw VaultLockError.notOpen
    }

    /// After an interrupted `setUsesBiometrics(true)`: puts the biometric item back as it was where possible. With
    /// no Face ID vault before, the item is deleted. The previous vault's key can't be written back (it isn't
    /// loaded), so its next Face ID open ends in `.biometricChanged`; the same vault's key is already right.
    private func restoreBiometricItem(previousMarker: String?, keyStore: any MasterKeyStoring) {
        guard previousMarker == nil else { return }
        do {
            try keyStore.deleteBiometricKey()
        } catch {
            Self.logger.error("Could not delete the biometric key: \(error, privacy: .public)")
        }
    }

    /// Builds the open vault of `match`: its name from `.vault_info` ("My Vault" when missing, then written) and
    /// its store. With `verifyKey`, a key that does not open the vault throws `.biometricChanged` before anything
    /// is written.
    private func load(_ match: Match, verifyKey: Bool) async throws -> LoadedVault {
        let cipher = makeCipher(match.keyStore)
        let storedName = catalog.readName(of: match.id, cipher: cipher)
        let name = storedName ?? VaultCatalog.defaultName
        let store = makeStore(catalog.folderURL(for: match.id), name, true, match.keyStore, cipher)
        if verifyKey, !(await store.keyMatchesVault()) {
            throw VaultLockError.biometricChanged
        }
        if storedName == nil {
            do {
                try catalog.writeName(name, of: match.id, cipher: cipher)
            } catch {
                // The name shows anyway; it is written again on the next open.
                Self.logger.error("Could not write a vault's name: \(error, privacy: .public)")
            }
        }
        let vault = OpenVault(id: match.id, name: name, isEncrypted: true, store: store)
        return LoadedVault(vault: vault, keyStore: match.keyStore)
    }

    /// Closes the open vault and any transfer target, then makes `loaded` current.
    private func makeCurrent(_ loaded: LoadedVault) {
        epoch += 1
        closeTransferTargets()
        closeOpenVault()
        openEncrypted = loaded
        state.set(loaded.vault)
    }

    /// Wipes the open encrypted vault's key and temp files; `current` is left for the caller to set.
    private func closeOpenVault() {
        guard let open = openEncrypted else { return }
        openEncrypted = nil
        Self.release(open)
    }

    private func closeTransferTargets() {
        let targets = transferTargets.values
        transferTargets = [:]
        for target in targets { Self.release(target) }
    }

    /// Wipes a vault's key and removes its temp files.
    private static func release(_ loaded: LoadedVault) {
        loaded.keyStore.wipeKey()
        loaded.vault.store.removeAllTemporaryFiles()
    }

    /// Waits until no other `createVault` runs, then marks one as running.
    private func beginCreating() async {
        guard isCreating else {
            isCreating = true
            return
        }
        // `endCreating` hands the running mark straight to the first waiter.
        await withCheckedContinuation { createWaiters.append($0) }
    }

    /// Lets the next waiting `createVault` run, or clears the running mark.
    private func endCreating() {
        if createWaiters.isEmpty {
            isCreating = false
        } else {
            createWaiters.removeFirst().resume()
        }
    }

    /// Wipes the key and forgets Face ID: the biometric item and the marker are deleted (best effort).
    private func forgetFaceID(keyStore: any MasterKeyStoring) {
        keyStore.wipeKey()
        do {
            try keyStore.deleteBiometricKey()
        } catch {
            Self.logger.error("Could not delete the biometric key: \(error, privacy: .public)")
        }
        do {
            try catalog.setBiometricVaultID(nil)
        } catch {
            Self.logger.error("Could not delete the Face ID vault marker: \(error, privacy: .public)")
        }
    }

    private func removeFolderIfPresent(_ folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            // An empty blobless folder is removed at the next launch.
            Self.logger.error("Could not remove an unfinished vault's folder: \(error, privacy: .public)")
        }
    }

    /// Runs `work` off the main actor, on a GCD queue rather than the Swift concurrency pool: key work blocks
    /// (PBKDF2, a Keychain read waiting on Face ID) and must not hold one of the pool's few threads.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Maps a failure to the lock's error: crypto errors to the same-named case, a Keychain status to
    /// `.keychain`, anything else to `.io` with its description.
    private static func lockError(from error: any Error) -> VaultLockError {
        if let lockError = error as? VaultLockError { return lockError }
        guard let crypto = error as? VaultCryptoError else { return .io(error.localizedDescription) }
        switch crypto {
        case .wrongPassword: return .wrongPassword
        case .emptyPassword: return .emptyPassword
        case .biometricCancelled: return .biometricCancelled
        case .biometryLockedOut: return .biometryLockedOut
        case .biometryNotEnrolled: return .biometryNotEnrolled
        case .passcodeNotSet: return .passcodeNotSet
        case .keychain(let status): return .keychain(status)
        case .biometricItemMissing, .corruptBlob, .invalidKeyData, .encryptionFailed, .decryptionFailed,
            .noKeyLoaded, .noMasterKeyBlob, .masterKeyAlreadyExists:
            return .io(crypto.localizedDescription)
        }
    }
}
