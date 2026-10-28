//
//  AuthService.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import Foundation
@preconcurrency import LocalAuthentication
import os
import UIKit

enum AuthError: Error {
    case wrongPassword
    case keychainError
    /// A vault key from an earlier install is in the Keychain, the vault holds data encrypted
    /// with it, and the typed password does not unlock it.
    case existingPasswordRequired
}

extension AuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .existingPasswordRequired:
            return "A vault password already exists on this device. Enter that password."
        case .wrongPassword, .keychainError:
            return nil   // unchanged: the system's default description
        }
    }
}

@MainActor
final class AuthService {
    static let shared = AuthService()
    private init() {}

    // MARK: - Keys
    private let privacyScreenTag = 999
    nonisolated private let logger = Logger(subsystem: "com.KoalaTVault", category: "AuthService")
    /// The master key store built once by the composition root (`AppDependencies`).
    nonisolated private var keyStore: any MasterKeyStoring { LegacyStorage.current.masterKeyStore }
    /// The reason shown with the biometric prompt.
    nonisolated private static let biometricPrompt = "Unlock your vault"
    /// The first bytes of an SVC5 vault file.
    nonisolated private static let encryptedFileMagic = Data("SVC5".utf8)

    // MARK: - Lock Mode
    var lockMode: LegacyLockMode {
        get { PreferencesService.shared.lockMode }
        set { PreferencesService.shared.lockMode = newValue }
    }

    // MARK: - Password
    /// Sets up the vault key for `password` and loads it.
    ///
    /// A key blob can outlive the app in the Keychain (e.g. after a reinstall). If one exists and
    /// nothing under `vaultRootURL` was encrypted with it, the stale blob and biometric item are
    /// deleted and a new key is created. If the vault does hold encrypted data, that blob is kept
    /// and `password` must unlock it; a wrong one throws `AuthError.existingPasswordRequired`.
    ///
    /// Returns true when a new key was created, false when the existing one was kept (pass it
    /// to `rollBackPasswordSetup(createdNewKey:)` if the rest of the setup fails).
    @discardableResult
    nonisolated func createPassword(
        _ password: String,
        vaultRootURL: URL = LegacyStorage.current.vaultRootURL
    ) throws -> Bool {
        if try keyStore.hasMasterKeyBlob() {
            if vaultHoldsEncryptedData(at: vaultRootURL) {
                do {
                    try keyStore.unlock(password: password)
                } catch VaultCryptoError.wrongPassword {
                    throw AuthError.existingPasswordRequired
                }
                return false
            }
            try keyStore.deleteMasterKeyBlob()
            removeBiometricSecret()
        }
        try keyStore.createMasterKey(password: password)
        // Caller is responsible for calling enableBiometrics() afterwards if lockMode is .passwordAndBiometrics.
        return true
    }

    /// Undoes a `createPassword` whose setup could not finish (e.g. enabling biometrics failed):
    /// removes the biometric item, removes the key blob when `createdNewKey` (a kept blob still
    /// protects encrypted data, so it stays), and wipes the key from memory. Lock mode is not
    /// touched. A blob that can't be removed is logged; the next `createPassword` on the empty
    /// vault replaces it.
    nonisolated func rollBackPasswordSetup(createdNewKey: Bool) {
        removeBiometricSecret()
        if createdNewKey {
            do {
                try keyStore.deleteMasterKeyBlob()
            } catch {
                logger.error("Rolling back the vault key failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        keyStore.wipeKey()
    }

    /// Whether anything under `rootURL` was encrypted with a vault key: a `.vault_map` index, a
    /// file in the encrypted format, or a trash entry (a `.trash_map` or anything in a `.trash`
    /// folder). Hidden files are included. Errs on the safe side: if the root or any part of it
    /// can't be read, the vault counts as holding encrypted data. Needs no key.
    nonisolated func vaultHoldsEncryptedData(at rootURL: URL) -> Bool {
        let fileManager = FileManager.default
        // A root that can't be listed (missing, no permission) is treated as not empty.
        guard (try? fileManager.contentsOfDirectory(atPath: rootURL.path)) != nil else { return true }
        var unreadable = false
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in unreadable = true; return false }
        ) else { return true }

        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if name == ".vault_map" || name == ".trash_map" { return true }
            guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else { return true }
            if isDirectory {
                if name == ".trash", (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty != true {
                    return true
                }
            } else if mayBeEncryptedFile(at: url) {
                return true
            }
        }
        return unreadable
    }

    /// Whether the file at `url` may be an encrypted vault file: it starts with the encrypted
    /// format's magic bytes. Errs on the safe side: a file that can't be read counts as encrypted.
    nonisolated private func mayBeEncryptedFile(at url: URL) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var prefix = Data()
            while prefix.count < Self.encryptedFileMagic.count {
                guard let chunk = try handle.read(upToCount: Self.encryptedFileMagic.count - prefix.count),
                      !chunk.isEmpty else { break }
                prefix.append(chunk)
            }
            return prefix == Self.encryptedFileMagic
        } catch {
            return true
        }
    }

    nonisolated func changePassword(to newPassword: String) throws {
        // rewrap keeps the same key in memory; the biometric item (raw key bytes) stays valid.
        try keyStore.rewrap(newPassword: newPassword)
    }

    nonisolated func verifyPassword(_ password: String) throws {
        // A successful unlock also deletes the legacy plaintext password item.
        do {
            try keyStore.unlock(password: password)
        } catch VaultCryptoError.wrongPassword {
            throw AuthError.wrongPassword
        }
    }

    func hasPassword() -> Bool {
        (try? keyStore.hasMasterKeyBlob()) ?? true
    }

    func removePassword() throws {
        try keyStore.deleteMasterKeyBlob()
        removeBiometricSecret()
    }

    // MARK: - Biometric Secret Storage

    /// Stores the currently loaded master key in the Keychain protected by biometrics.
    /// Only call when lockMode is .passwordAndBiometrics and the master key is loaded.
    /// Throws `VaultCryptoError.noKeyLoaded` without the key, or `AuthError.keychainError`.
    nonisolated func enableBiometrics() throws {
        do {
            try keyStore.storeBiometricKey()
        } catch VaultCryptoError.noKeyLoaded {
            throw VaultCryptoError.noKeyLoaded
        } catch {
            logger.error("Storing the biometric key failed: \(error.localizedDescription, privacy: .public)")
            throw AuthError.keychainError
        }
    }

    /// Removes the biometrically-protected master key from the Keychain. A failure is logged;
    /// the item is replaced the next time biometrics are enabled.
    nonisolated func removeBiometricSecret() {
        do {
            try keyStore.deleteBiometricKey()
        } catch {
            logger.error("Removing the biometric key failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Migration Completion
    func finalizeMigration(
        type: LegacyMigrationViewController.MigrationType,
        targetLockMode: LegacyLockMode?,
        completedFully: Bool
    ) {
        guard completedFully else { return }
        switch type {
        case .encrypt:
            if let targetLockMode { lockMode = targetLockMode }
        case .decrypt:
            lockMode = .none
            do {
                try removePassword()
            } catch {
                // Removal failed: the keychain blob persists while lockMode is .none.
                // The key is wiped below so the vault is still inaccessible, but the
                // inconsistency should be investigated.
                logger.error("removePassword failed during decrypt migration: \(error.localizedDescription, privacy: .public)")
            }
            keyStore.wipeKey()
        }
    }

    // MARK: - Biometrics
    var biometricsAvailable: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: nil
        )
    }

    var biometricType: String {
        let context = LAContext()
        context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: nil
        )
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometrics"
        }
    }

    func authenticateWithBiometrics(
        completion: @escaping @MainActor @Sendable (Bool, Error?) -> Void
    ) {
        // The Keychain read (in the key store) is the sole authentication gate — the Secure
        // Enclave enforces it at hardware level, unlike evaluatePolicy whose result can be faked
        // on a jailbroken device.
        DispatchQueue.global(qos: .userInitiated).async { [keyStore] in
            do {
                try keyStore.unlockWithBiometricKey(prompt: Self.biometricPrompt)
                DispatchQueue.main.async { completion(true, nil) }
            } catch VaultCryptoError.biometricCancelled {
                // nil signals user-initiated dismissal so the lock screen shows no error.
                DispatchQueue.main.async { completion(false, nil) }
            } catch {
                DispatchQueue.main.async { completion(false, AuthError.keychainError) }
            }
        }
    }

    // MARK: - Lock State
    var isLocked = false
    var hasAuthenticated = false

    static let vaultUnlockedNotification = Notification.Name(
        "KoalaTVault.vaultUnlocked"
    )

    // MARK: - Scene Lifecycle
    /// Call from `sceneWillResignActive`. Any interruption — Control Center, an
    /// alert, the StoreKit purchase sheet — triggers this, so it only covers the
    /// screen; it must NOT wipe the key or present the lock screen, since most of
    /// these interruptions aren't a real backgrounding.
    func handleWillResignActive(in window: UIWindow?) {
        guard hasAuthenticated, lockMode != .none else { return }
        showPrivacyScreen(in: window)
    }

    /// Call from `sceneDidEnterBackground`. This only fires on a genuine
    /// backgrounding (home button, app switch, screen lock), so this is where
    /// the actual lock — wiping the key and requiring re-auth — belongs.
    func handleDidEnterBackground(in window: UIWindow?) {
        guard hasAuthenticated, lockMode != .none else { return }
        isLocked = true
        keyStore.wipeKey()
        FileSystem.shared.cleanupTempFiles()
        ThumbnailService.shared.clearCache()
    }

    func handleForeground(in window: UIWindow?) {
        if lockMode == .none {
            hasAuthenticated = true
            hidePrivacyScreen(in: window)
            return
        }
        if isLocked {
            showLockScreen(in: window)
        } else {
            hidePrivacyScreen(in: window)
        }
    }

    func handleInitialLaunch(in window: UIWindow?) {
        resolveUnfinishableEncryption()
        guard lockMode != .none || pendingEncryptionNeedsPassword else {
            NotificationCenter.default.post(
                name: AuthService.vaultUnlockedNotification,
                object: nil
            )
            return
        }
        isLocked = true
        showLockScreen(in: window)
    }

    /// An interrupted encryption (adding a lock) finishes only with the key, so the launch asks
    /// for the password even if the lock mode was never saved (lock mode none, password set).
    private var pendingEncryptionNeedsPassword: Bool {
        PreferencesService.shared.pendingMigrationType == .encrypt && hasPassword()
    }

    /// A pending encryption with no password at all can never finish (no key exists, so
    /// nothing was encrypted with it): drop the pending record and leave the vault unlocked, so
    /// launch never sits on a lock screen or migration screen with no way forward. Files stay
    /// as they are on disk; nothing is deleted.
    private func resolveUnfinishableEncryption() {
        guard PreferencesService.shared.pendingMigrationType == .encrypt else { return }
        let blobExists: Bool
        do {
            blobExists = try keyStore.hasMasterKeyBlob()
        } catch {
            // Keychain unreadable right now: keep everything and ask for the password as usual.
            logger.error("Keychain read failed at launch: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !blobExists else { return }
        logger.error("Pending encryption without a password; finishing as No Lock")
        PreferencesService.shared.pendingMigrationType = nil
        PreferencesService.shared.pendingMigrationTargetLockMode = nil
        lockMode = .none
    }

    // MARK: - Auth Success
    func didAuthenticate(in window: UIWindow?) {
        isLocked = false
        hasAuthenticated = true
        guard let root = window?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        // topVC is the lock screen itself — dismiss it specifically, not its presenter's
        // whole chain, so an in-progress LegacyMigrationViewController underneath survives.
        let dismisser = topVC.presentingViewController ?? root
        dismisser.dismiss(animated: true) {
            self.hidePrivacyScreen(in: window)
            self.reloadFileBrowser(in: window)
            NotificationCenter.default.post(
                name: AuthService.vaultUnlockedNotification,
                object: nil
            )
        }
    }

    // MARK: - Privacy Screen
    private func showPrivacyScreen(in window: UIWindow?) {
        guard window?.viewWithTag(privacyScreenTag) == nil else { return }
        let privacy = UIView()
        privacy.backgroundColor = .systemBackground
        privacy.tag = privacyScreenTag
        privacy.accessibilityIdentifier = "privacyCover"
        let logo = UIImageView(image: UIImage(systemName: "lock.fill"))
        logo.tintColor = .systemBlue
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        privacy.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: privacy.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: privacy.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 60),
            logo.heightAnchor.constraint(equalToConstant: 60)
        ])
        privacy.frame = window?.bounds ?? .zero
        window?.addSubview(privacy)
    }

    private func hidePrivacyScreen(in window: UIWindow?) {
        window?.viewWithTag(privacyScreenTag)?.removeFromSuperview()
    }

    // MARK: - Lock Screen
    private func showLockScreen(in window: UIWindow?) {
        guard let root = window?.rootViewController else { return }
        // find topmost presented view controller
        var topVC = root
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        guard !(topVC is LegacyLockScreenViewController) else {
            hidePrivacyScreen(in: window)
            return
        }
        let lock = LegacyLockScreenViewController()
        lock.modalPresentationStyle = .fullScreen
        topVC.present(lock, animated: false) { [weak self] in
            self?.hidePrivacyScreen(in: window)
        }
    }

    // MARK: - File Browser Reload
    private func reloadFileBrowser(in window: UIWindow?) {
        // Assumes root is always UINavigationController with LegacyFileBrowserViewController as the first VC.
        // Update this if the root view controller hierarchy ever changes (e.g. tab bar added).
        if let nav = window?.rootViewController as? UINavigationController,
            let browser = nav.viewControllers.first
                as? LegacyFileBrowserViewController
        {
            browser.reloadAfterAuth()
        }
    }
}
