import Foundation
import os

/// The live vaults (feature multiple-vaults-duress-password): the unencrypted vault over Documents, always there,
/// and the encrypted vaults under `Vaults/` (see `VaultCatalog`), each opened by its own password or, for at most
/// one vault, Face ID.
///
/// The lock never lists or counts encrypted vaults for the user: a password opens whichever vault it belongs to,
/// and every failure reads the same (`.wrongPassword`). Key work (PBKDF2, Keychain reads behind a Face ID prompt,
/// the upgrade's file moves) runs off the main actor; the state (`current`, the open key stores) lives on it.
@MainActor
final class LiveVaultLock: VaultLocking {
    private static let logger = Logger(subsystem: "com.KoalaTVault", category: "VaultLock")
    /// The reason shown with the Face ID prompt.
    nonisolated private static let biometricPrompt = "Unlock your vault"
    private static let unencryptedID = "unencrypted"
    private static let unencryptedName = "KoalaTVault"

    /// A vault whose key a key store has loaded, found by a password.
    private struct Match: Sendable {
        let id: String
        let keyStore: any MasterKeyStoring
        /// Whether `keyStore` is the open vault's own key store (never wiped by a probe).
        let isOpenKeyStore: Bool
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
    private let makeCipher: @Sendable (any MasterKeyStoring) -> any FileCipher
    private let makeStore:
        @Sendable (_ root: URL, _ name: String, _ isEncrypted: Bool, any MasterKeyStoring, any FileCipher) ->
            any VaultStoring

    private let state: OpenVaultState
    /// The open encrypted vault (`current`) and its key store; nil while the unencrypted vault is current.
    private var openEncrypted: LoadedVault?
    /// The open transfer targets, by vault ID.
    private var transferTargets: [String: LoadedVault] = [:]

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
    ///   - makeCipher: a cipher over a key store.
    ///   - makeStore: a vault store for a root, name, encrypted flag, key store and cipher.
    init(
        documents: URL, vaultsFolder: URL, unencryptedStore: any VaultStoring, keychain: any KeychainAccessing,
        preferences: any PreferencesStoring, pro: any ProUnlocking, biometricInfo: BiometricInfo,
        makeKeyStore: @escaping @Sendable (_ blobAccount: String) -> any MasterKeyStoring,
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
        guard let match = await findVault(password: password) else { throw VaultLockError.wrongPassword }
        guard !match.isOpenKeyStore else { return }  // the vault already open: no change
        let loaded = try await load(match, verifyKey: false)
        makeCurrent(loaded)
    }

    func openWithBiometrics() async throws {
        guard let id = catalog.biometricVaultID(), catalog.vaultIDs().contains(id) else {
            throw VaultLockError.noBiometricVault
        }
        guard biometricInfo.isAvailable else { throw VaultLockError.biometricsUnavailable }
        guard id != openEncrypted?.vault.id else { return }
        let keyStore = makeKeyStore(VaultCatalog.blobAccount(for: id))
        do {
            try await Self.offMain { try keyStore.unlockWithBiometricKey(prompt: Self.biometricPrompt) }
        } catch VaultCryptoError.biometricItemMissing, VaultCryptoError.invalidKeyData {
            forgetFaceID(keyStore: keyStore)
            throw VaultLockError.biometricChanged
        } catch {
            keyStore.wipeKey()
            throw Self.lockError(from: error)
        }
        let loaded: LoadedVault
        do {
            loaded = try await load(Match(id: id, keyStore: keyStore, isOpenKeyStore: false), verifyKey: true)
        } catch {
            // The biometric key does not open this vault (Face ID was re-enrolled or the item is stale).
            forgetFaceID(keyStore: keyStore)
            throw error
        }
        makeCurrent(loaded)
    }

    // MARK: Creating

    func canCreateVault() async -> Bool {
        pro.isUnlocked || catalog.vaultIDs().isEmpty
    }

    func createVault(name: String, password: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultLockError.emptyName }
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        guard await canCreateVault() else { throw VaultLockError.vaultLimitReached }
        if let match = await findVault(password: password) {
            if !match.isOpenKeyStore { match.keyStore.wipeKey() }
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
        try await verify(currentPassword, of: open)
        if let match = await findVault(password: newPassword, excluding: open.vault.id) {
            match.keyStore.wipeKey()
            throw VaultLockError.passwordInUse
        }
        let keyStore = open.keyStore
        do {
            try await Self.offMain { try keyStore.rewrap(newPassword: newPassword) }
        } catch {
            throw Self.lockError(from: error)
        }
    }

    func setUsesBiometrics(_ enabled: Bool) async throws {
        guard let open = openEncrypted else { throw VaultLockError.notOpen }
        do {
            if enabled {
                guard biometricInfo.isAvailable else { throw VaultLockError.biometricsUnavailable }
                // The item is replaced first; the marker moves only once the item holds this vault's key.
                try open.keyStore.storeBiometricKey()
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
        try await verify(password, of: open)
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
        guard let match = await findVault(password: password) else { throw VaultLockError.wrongPassword }
        guard !match.isOpenKeyStore else { throw VaultLockError.sameVault }
        let loaded = try await load(match, verifyKey: false)
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
    /// actor), with its key loaded; nil when none does. The open vault is tried with its own key store, so
    /// finding it leaves its key as it was.
    private func findVault(password: String, excluding excludedID: String? = nil) async -> Match? {
        let ids = catalog.vaultIDs().filter { $0 != excludedID }
        let open = openEncrypted.map { Match(id: $0.vault.id, keyStore: $0.keyStore, isOpenKeyStore: true) }
        let makeKeyStore = self.makeKeyStore
        return await Task.detached(priority: .userInitiated) { () -> Match? in
            for id in ids {
                let match: Match
                if let open, open.id == id {
                    match = open
                } else {
                    match = Match(
                        id: id, keyStore: makeKeyStore(VaultCatalog.blobAccount(for: id)), isOpenKeyStore: false)
                }
                do {
                    try match.keyStore.unlock(password: password)
                    return match
                } catch {
                    continue  // not this vault (or its blob can't be read): try the next one
                }
            }
            return nil
        }.value
    }

    /// Throws `.wrongPassword` unless `password` opens `vault` (re-loading the same key).
    private func verify(_ password: String, of vault: LoadedVault) async throws {
        let keyStore = vault.keyStore
        do {
            try await Self.offMain { try keyStore.unlock(password: password) }
        } catch {
            throw Self.lockError(from: error)
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

    /// Runs `work` off the main actor.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
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
