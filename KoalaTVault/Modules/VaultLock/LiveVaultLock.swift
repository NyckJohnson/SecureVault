import Foundation
import Security
import os

/// The live vault lock: the key lifecycle over the master-key store, the lock mode in the preferences,
/// and the lock state derived from both.
///
/// Key operations (PBKDF2, Keychain reads behind a Face ID prompt) run off the main actor; the state
/// and the lock mode are only changed on the main actor, after each awaited step returns.
@MainActor
final class LiveVaultLock: VaultLocking {
    private static let logger = Logger(subsystem: "com.KoalaTVault", category: "VaultLock")
    /// The plaintext password item from old app versions; deleted whenever it may still exist.
    nonisolated private static let legacyPasswordAccount = "com.KoalaTVault.password"
    /// The reason shown with the biometric prompt.
    nonisolated private static let biometricPrompt = "Unlock your vault"

    private let masterKeys: any MasterKeyStoring
    private let keychain: any KeychainAccessing
    private let preferences: any PreferencesStoring
    private let store: any VaultStoring
    private let biometricInfo: BiometricInfo
    private let vaultHoldsEncryptedData: @Sendable () async -> Bool

    private(set) var state: LockState {
        didSet {
            guard state != oldValue else { return }
            for continuation in continuations.values { continuation.yield(state) }
        }
    }

    private var continuations: [UUID: AsyncStream<LockState>.Continuation] = [:]

    /// - Parameters:
    ///   - vaultHoldsEncryptedData: whether the vault holds any index, encrypted file or trash entry
    ///     (see `VaultEncryptedDataCheck`); decides whether an existing key blob is stale.
    init(
        masterKeys: any MasterKeyStoring,
        keychain: any KeychainAccessing,
        preferences: any PreferencesStoring,
        store: any VaultStoring,
        biometricInfo: BiometricInfo,
        vaultHoldsEncryptedData: @escaping @Sendable () async -> Bool
    ) {
        self.masterKeys = masterKeys
        self.keychain = keychain
        self.preferences = preferences
        self.store = store
        self.biometricInfo = biometricInfo
        self.vaultHoldsEncryptedData = vaultHoldsEncryptedData
        // At launch no key is loaded: a lock starts locked, no lock starts open.
        state = LockState(lockMode: preferences.lockMode, keyLoaded: false)
    }

    deinit {
        for continuation in continuations.values { continuation.finish() }
    }

    var lockMode: LockMode { preferences.lockMode }
    var biometricKind: BiometricKind { biometricInfo.kind }
    var biometricsAvailable: Bool { biometricInfo.isAvailable }

    func stateUpdates() -> AsyncStream<LockState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LockState>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { _ in
            Task { @MainActor [weak self] in self?.continuations[id] = nil }
        }
        return stream
    }

    // MARK: - Setting up a lock

    func setUp(mode: LockMode, password: String?) async throws {
        guard mode != .none else {
            preferences.lockMode = .none
            refreshState()
            return
        }
        guard let password, !password.isEmpty else { throw VaultLockError.emptyPassword }
        try await addLock(mode: mode, password: password)
    }

    func prepareToAddLock(mode: LockMode, password: String) async throws {
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        try await addLock(mode: mode, password: password)
    }

    /// Loads or creates the key for `password`, stores the biometric item for biometric mode, then writes
    /// `mode`. Any failure after the key was loaded or created rolls back and leaves the lock mode as it was.
    private func addLock(mode: LockMode, password: String) async throws {
        defer { refreshState() }
        if mode == .passwordAndBiometrics && !biometricInfo.isAvailable {
            throw VaultLockError.biometricsUnavailable
        }
        let createdNewKey = try await establishKey(password: password)
        if mode == .passwordAndBiometrics {
            do {
                try await offMain { [masterKeys] in try masterKeys.storeBiometricKey() }
            } catch {
                await rollBack(createdNewKey: createdNewKey)
                throw Self.lockError(from: error)
            }
        }
        preferences.lockMode = mode
    }

    /// Loads the key for `password`, creating it when there is no usable blob.
    ///
    /// A blob over a vault without encrypted data is stale (e.g. left from an earlier install): it and its
    /// biometric item are deleted and a new key is created. A blob over encrypted data is never replaced;
    /// `password` must unlock it. Returns true when a new key was created.
    private func establishKey(password: String) async throws -> Bool {
        let keys = masterKeys
        let hasBlob: Bool
        do {
            hasBlob = try await offMain { try keys.hasMasterKeyBlob() }
        } catch {
            throw Self.lockError(from: error)
        }
        if hasBlob {
            if await vaultHoldsEncryptedData() {
                do {
                    try await offMain { try keys.unlock(password: password) }
                } catch VaultCryptoError.wrongPassword {
                    throw VaultLockError.existingPasswordRequired
                } catch {
                    throw Self.lockError(from: error)
                }
                return false
            }
            do {
                try await offMain { try keys.deleteMasterKeyBlob() }
            } catch {
                throw Self.lockError(from: error)
            }
            // A stale biometric item only holds the stale key; storing a new one replaces it.
            await deleteBiometricKeyLogging("stale biometric item")
        }
        do {
            try await offMain { try keys.createMasterKey(password: password) }
        } catch {
            throw Self.lockError(from: error)
        }
        return true
    }

    /// Undoes `establishKey` after a later step failed: deletes the biometric item, deletes the blob when it
    /// was newly created (a kept blob still protects encrypted data), and wipes the key. A blob that can't be
    /// deleted is logged; the next setup on the empty vault replaces it.
    private func rollBack(createdNewKey: Bool) async {
        await deleteBiometricKeyLogging("rollback biometric item")
        if createdNewKey {
            do {
                try await offMain { [masterKeys] in try masterKeys.deleteMasterKeyBlob() }
            } catch {
                Self.logger.error("Rollback blob delete failed: \(String(describing: error), privacy: .public)")
            }
        }
        masterKeys.wipeKey()
    }

    // MARK: - Unlocking

    func unlock(password: String) async throws {
        guard !password.isEmpty else { throw VaultLockError.emptyPassword }
        defer { refreshState() }
        let keys = masterKeys
        do {
            try await offMain { try keys.unlock(password: password) }
        } catch {
            throw Self.lockError(from: error)
        }
        await deleteLegacyPasswordItem()
        if preferences.lockMode == .passwordAndBiometrics {
            // Refreshes the item after biometric enrollment changes; the password still unlocks if this fails.
            do {
                try await offMain { try keys.storeBiometricKey() }
            } catch {
                Self.logger.error(
                    "Refreshing the biometric item failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func unlockWithBiometrics() async throws {
        guard preferences.lockMode == .passwordAndBiometrics else { throw VaultLockError.biometricsUnavailable }
        defer { refreshState() }
        let keys = masterKeys
        do {
            try await offMain { try keys.unlockWithBiometricKey(prompt: Self.biometricPrompt) }
        } catch VaultCryptoError.biometricItemMissing {
            throw VaultLockError.biometricChanged
        } catch {
            throw Self.lockError(from: error)
        }
        // The item holds raw key bytes; any 32 bytes load, so check them against the vault.
        guard await store.keyMatchesVault() else {
            masterKeys.wipeKey()
            await deleteBiometricKeyLogging("mismatched biometric item")
            throw VaultLockError.biometricChanged
        }
    }

    // MARK: - Scene lifecycle

    func appWillResignActive() -> Bool {
        preferences.lockMode != .none && state == .unlocked
    }

    func appDidEnterBackground() {
        guard preferences.lockMode != .none else { return }
        masterKeys.wipeKey()
        store.removeAllTemporaryFiles()
        state = .locked
    }

    func appWillEnterForeground() {
        if preferences.lockMode == .none { state = .open }
    }

    // MARK: - Settings

    func changePassword(current: String, new: String) async throws {
        guard !new.isEmpty else { throw VaultLockError.emptyPassword }
        defer { refreshState() }
        let keys = masterKeys
        do {
            try await offMain { try keys.unlock(password: current) }
            // The key stays the same, so files and the biometric item stay valid.
            try await offMain { try keys.rewrap(newPassword: new) }
        } catch {
            throw Self.lockError(from: error)
        }
    }

    func switchMode(to mode: LockMode) async throws {
        let current = preferences.lockMode
        // Adding or removing the lock goes through the migration (`prepareToAddLock` / `removeKeysAfterDecryption`).
        guard mode != .none, current != .none else { throw VaultLockError.notUnlocked }
        guard mode != current else { return }
        let keys = masterKeys
        if mode == .passwordAndBiometrics {
            guard keys.isKeyLoaded else { throw VaultLockError.notUnlocked }
            guard biometricInfo.isAvailable else { throw VaultLockError.biometricsUnavailable }
            do {
                try await offMain { try keys.storeBiometricKey() }
            } catch {
                throw Self.lockError(from: error)
            }
            preferences.lockMode = mode
        } else {
            preferences.lockMode = mode
            // A leftover item is harmless once the mode is password; the error is still reported.
            do {
                try await offMain { try keys.deleteBiometricKey() }
            } catch {
                throw Self.lockError(from: error)
            }
        }
    }

    // MARK: - Removing the lock

    func removeKeysAfterDecryption() async throws {
        defer { refreshState() }
        let keys = masterKeys
        // Each step is idempotent; a failure stops here and the next call redoes the remaining steps.
        do {
            try await offMain { try keys.deleteBiometricKey() }
            preferences.lockMode = .none
            try await offMain { try keys.deleteMasterKeyBlob() }
        } catch {
            throw Self.lockError(from: error)
        }
        keys.wipeKey()
        await deleteLegacyPasswordItem()
    }

    // MARK: - Helpers

    /// Sets the state from the lock mode and whether the key is loaded; publishes only a change.
    private func refreshState() {
        state = LockState(lockMode: preferences.lockMode, keyLoaded: masterKeys.isKeyLoaded)
    }

    /// Deletes the old plaintext password item; a failure is logged and otherwise ignored.
    private func deleteLegacyPasswordItem() async {
        let keychain = keychain
        do {
            try await offMain { try keychain.delete(account: Self.legacyPasswordAccount) }
        } catch {
            Self.logger.error(
                "Deleting the legacy password item failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Deletes the biometric item where a failure must not stop the caller; the failure is logged.
    private func deleteBiometricKeyLogging(_ what: StaticString) async {
        do {
            try await offMain { [masterKeys] in try masterKeys.deleteBiometricKey() }
        } catch {
            Self.logger.error(
                "Deleting the \(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs blocking Keychain and key-derivation work off the main actor.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    /// Maps a key-store error to the lock's error.
    ///
    /// Key-store failures with no lock equivalent (corrupt blob, invalid key data, a crypto failure, an
    /// existing key) surface as a Keychain error with the closest Security status.
    private static func lockError(from error: any Error) -> VaultLockError {
        guard let error = error as? VaultCryptoError else {
            return (error as? VaultLockError) ?? .keychain(errSecInternalError)
        }
        if let biometricError = biometricLockError(from: error) { return biometricError }
        switch error {
        case .wrongPassword: return .wrongPassword
        case .emptyPassword: return .emptyPassword
        case .noMasterKeyBlob: return .passwordMissing
        case .noKeyLoaded: return .notUnlocked
        case .keychain(let status): return .keychain(status)
        case .masterKeyAlreadyExists: return .keychain(errSecDuplicateItem)
        default: return .keychain(errSecDecode)
        }
    }

    /// The lock error for a biometric key-store error, or nil for any other error.
    private static func biometricLockError(from error: VaultCryptoError) -> VaultLockError? {
        switch error {
        case .biometricCancelled: return .biometricCancelled
        case .biometricItemMissing: return .biometricChanged
        case .biometryLockedOut: return .biometryLockedOut
        case .biometryNotEnrolled: return .biometryNotEnrolled
        case .passcodeNotSet: return .passcodeNotSet
        default: return nil
        }
    }
}

/// The check behind `LiveVaultLock`'s `vaultHoldsEncryptedData`: whether anything under the vault root was
/// encrypted with a vault key. Needs no key.
enum VaultEncryptedDataCheck {
    /// The first bytes of an SVC5 vault file.
    private static let encryptedFileMagic = Data("SVC5".utf8)

    /// Whether `rootURL` holds a `.vault_map` index, a file in the encrypted format, or a trash entry (a
    /// `.trash_map` or anything in a `.trash` folder). Hidden files are included. Errs on the safe side: a
    /// root or entry that can't be read counts as encrypted data.
    static func holdsEncryptedData(at rootURL: URL, fileManager: FileManager) -> Bool {
        // A root that can't be listed (missing, no permission) is treated as not empty.
        guard (try? fileManager.contentsOfDirectory(atPath: rootURL.path)) != nil else { return true }
        let unreadable = OSAllocatedUnfairLock(initialState: false)
        guard
            let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [],
                errorHandler: { _, _ in
                    unreadable.withLock { $0 = true }
                    return false
                }
            )
        else { return true }

        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if name == ".vault_map" || name == ".trash_map" { return true }
            guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                return true  // coverage-exempt: only if the entry vanishes between listing and reading its properties
            }
            if isDirectory {
                if name == ".trash", (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty != true {
                    return true
                }
            } else if mayBeEncryptedFile(at: url) {
                return true
            }
        }
        return unreadable.withLock { $0 }
    }

    /// Whether the file starts with the encrypted format's magic bytes; a file that can't be read counts
    /// as encrypted.
    private static func mayBeEncryptedFile(at url: URL) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var prefix = Data()
            while prefix.count < encryptedFileMagic.count {
                guard let chunk = try handle.read(upToCount: encryptedFileMagic.count - prefix.count),
                    !chunk.isEmpty
                else { break }
                prefix.append(chunk)
            }
            return prefix == encryptedFileMagic
        } catch {
            return true
        }
    }
}
