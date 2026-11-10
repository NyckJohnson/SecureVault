import Foundation
import Security
import os

/// The live vault lock. Feature multiple-vaults-duress-password replaces the lock-mode lock with the vaults
/// (VaultLock unit 1 rebuilds it); until then every vault member fails loudly.
@MainActor
final class LiveVaultLock: VaultLocking {
    private let masterKeys: any MasterKeyStoring
    private let keychain: any KeychainAccessing
    private let preferences: any PreferencesStoring
    private let store: any VaultStoring
    private let biometricInfo: BiometricInfo
    private let vaultHoldsEncryptedData: @Sendable () async -> Bool

    /// - Parameters:
    ///   - vaultHoldsEncryptedData: whether the vault holds any index, encrypted file or trash entry
    ///     (see `VaultEncryptedDataCheck`).
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
    }

    var current: OpenVault {
        fatalError("Not implemented: LiveVaultLock.current (feature multiple-vaults-duress-password)")
    }
    var unencryptedVault: OpenVault {
        fatalError("Not implemented: LiveVaultLock.unencryptedVault (feature multiple-vaults-duress-password)")
    }
    func currentUpdates() -> AsyncStream<OpenVault> {
        fatalError("Not implemented: LiveVaultLock.currentUpdates (feature multiple-vaults-duress-password)")
    }
    var biometricKind: BiometricKind { biometricInfo.kind }
    var biometricsAvailable: Bool { biometricInfo.isAvailable }
    var hasBiometricVault: Bool {
        fatalError("Not implemented: LiveVaultLock.hasBiometricVault (feature multiple-vaults-duress-password)")
    }
    var currentUsesBiometrics: Bool {
        fatalError("Not implemented: LiveVaultLock.currentUsesBiometrics (feature multiple-vaults-duress-password)")
    }
    func upgradeIfNeeded() async throws {
        fatalError("Not implemented: LiveVaultLock.upgradeIfNeeded (feature multiple-vaults-duress-password)")
    }
    func canCreateVault() async -> Bool {
        fatalError("Not implemented: LiveVaultLock.canCreateVault (feature multiple-vaults-duress-password)")
    }
    func createVault(name: String, password: String) async throws {
        fatalError("Not implemented: LiveVaultLock.createVault (feature multiple-vaults-duress-password)")
    }
    func open(password: String) async throws {
        fatalError("Not implemented: LiveVaultLock.open (feature multiple-vaults-duress-password)")
    }
    func openWithBiometrics() async throws {
        fatalError("Not implemented: LiveVaultLock.openWithBiometrics (feature multiple-vaults-duress-password)")
    }
    func close() {
        fatalError("Not implemented: LiveVaultLock.close (feature multiple-vaults-duress-password)")
    }
    func appWillResignActive() -> Bool {
        fatalError("Not implemented: LiveVaultLock.appWillResignActive (feature multiple-vaults-duress-password)")
    }
    func appDidEnterBackground() {
        fatalError("Not implemented: LiveVaultLock.appDidEnterBackground (feature multiple-vaults-duress-password)")
    }
    func changePassword(current: String, new: String) async throws {
        fatalError("Not implemented: LiveVaultLock.changePassword (feature multiple-vaults-duress-password)")
    }
    func setUsesBiometrics(_ enabled: Bool) async throws {
        fatalError("Not implemented: LiveVaultLock.setUsesBiometrics (feature multiple-vaults-duress-password)")
    }
    func deleteCurrentVault(password: String) async throws {
        fatalError("Not implemented: LiveVaultLock.deleteCurrentVault (feature multiple-vaults-duress-password)")
    }
    func openTransferTarget(password: String) async throws -> OpenVault {
        fatalError("Not implemented: LiveVaultLock.openTransferTarget (feature multiple-vaults-duress-password)")
    }
    func closeTransferTarget(_ vault: OpenVault) {
        fatalError("Not implemented: LiveVaultLock.closeTransferTarget (feature multiple-vaults-duress-password)")
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
