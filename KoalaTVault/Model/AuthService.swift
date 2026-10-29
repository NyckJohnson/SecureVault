//
//  AuthService.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//
//  What is left of the legacy auth service once VaultLock owns the key lifecycle and the lock state:
//  presenting the lock screen and the privacy cover (until LockScreens replaces it), the launch recovery
//  of an interrupted encryption, and the end of a migration (until LockMigration replaces it). Every lock
//  operation goes through the app's one `VaultLocking`.
//

import Foundation
import os
import UIKit

// MARK: - Legacy wording

extension BiometricKind {
    /// The name the legacy screens show: "Face ID", "Touch ID", or "Biometrics" without biometric hardware.
    var legacyDisplayName: String {
        switch self {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .none: return "Biometrics"
        }
    }
}

extension VaultLockError {
    /// The message the legacy screens show for this error.
    var legacyMessage: String {
        switch self {
        case .wrongPassword: return "Incorrect password"
        case .existingPasswordRequired: return "A vault password already exists on this device. Enter that password."
        case .emptyPassword: return "Password cannot be empty"
        case .passwordMissing: return "Your vault password is missing from this device."
        case .notUnlocked: return "Unlock the vault first."
        case .biometricsUnavailable: return "Biometric authentication isn't available on this device."
        case .biometricCancelled, .biometryLockedOut, .biometryNotEnrolled, .passcodeNotSet, .biometricChanged:
            return "Biometric authentication failed"
        case .keychain(let status): return "A Keychain error occurred (\(status))."
        }
    }
}

// MARK: - Migration completion (LockMigration's part)

/// The end of a legacy migration screen's run, until LockMigration replaces it.
@MainActor
enum LegacyMigrationCompletion {
    private static let logger = Logger(subsystem: "com.KoalaTVault", category: "AuthService")

    /// Finishes a migration that `completedFully`: a decrypt removes the keys and the lock through `vaultLock`.
    ///
    /// An encrypt needs nothing here: the lock was added before the encryption started
    /// (`VaultLocking.prepareToAddLock`), so the lock mode already is the target. A migration that didn't
    /// complete fully changes nothing (a skipped decrypt keeps the lock and keys).
    /// - Throws: the `VaultLockError` of `removeKeysAfterDecryption`; the steps it didn't reach are left as
    ///   they were, and calling it again redoes them.
    static func finalize(type: MigrationKind, completedFully: Bool, vaultLock: any VaultLocking) async throws {
        guard completedFully, type == .decrypt else { return }
        do {
            try await vaultLock.removeKeysAfterDecryption()
        } catch {
            logger.error("Removing the keys after decryption failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

// MARK: - Lock presentation (LockScreens' part)

/// Presents the lock screen and the privacy cover over the window, and recovers an interrupted encryption at
/// launch. Built once by the composition root (`AppDependencies`); every lock decision comes from `vaultLock`.
@MainActor
final class AuthService {
    private let vaultLock: any VaultLocking
    private let preferences: any PreferencesStoring
    private let keyStore: any MasterKeyStoring
    private let privacyScreenTag = 999
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "AuthService")
    /// Work waiting for the lock screen to be dismissed (see `afterLockScreenDismissed`).
    private var lockScreenDismissalWaiters: [@MainActor () -> Void] = []

    /// - Parameters:
    ///   - vaultLock: the app's one vault lock.
    ///   - preferences: the app's settings (read for a pending migration).
    ///   - keyStore: the master key store, asked at launch whether a password blob exists.
    init(vaultLock: any VaultLocking, preferences: any PreferencesStoring, keyStore: any MasterKeyStoring) {
        self.vaultLock = vaultLock
        self.preferences = preferences
        self.keyStore = keyStore
    }

    // MARK: - Scene Lifecycle

    /// Call from `sceneWillResignActive`. Any interruption (Control Center, an alert, the StoreKit sheet)
    /// triggers it, so it only covers the screen, and only when the vault lock says so.
    func handleWillResignActive(in window: UIWindow?) {
        guard vaultLock.appWillResignActive() else { return }
        showPrivacyScreen(in: window)
    }

    /// Call from `sceneDidBecomeActive`: updates the lock state, then shows the lock screen when the vault is
    /// locked, or removes the privacy cover.
    func handleForeground(in window: UIWindow?) {
        vaultLock.appWillEnterForeground()
        if vaultLock.state == .locked {
            showLockScreen(in: window)
        } else {
            hidePrivacyScreen(in: window)
        }
    }

    /// Call once the scene is set up (not while the setup wizard shows). Returns true when it showed the
    /// lock screen: the vault is locked, or an interrupted encryption needs the password to finish.
    @discardableResult
    func handleInitialLaunch(in window: UIWindow?) -> Bool {
        resolveUnfinishableEncryption()
        guard vaultLock.state == .locked || pendingEncryptionNeedsPassword else { return false }
        showLockScreen(in: window)
        return true
    }

    /// An interrupted encryption (adding a lock) finishes only with the key, so the launch asks for the
    /// password even if the lock mode was never saved (lock mode none, password set). A Keychain error
    /// counts as a password set.
    private var pendingEncryptionNeedsPassword: Bool {
        guard preferences.pendingMigration?.kind == .encrypt else { return false }
        return (try? keyStore.hasMasterKeyBlob()) ?? true
    }

    /// A pending encryption with no password at all can never finish (no key exists, so nothing was
    /// encrypted with it): drop the pending record and leave the vault without a lock, so launch never sits
    /// on a lock screen or migration screen with no way forward. Files stay as they are on disk.
    private func resolveUnfinishableEncryption() {
        guard preferences.pendingMigration?.kind == .encrypt else { return }
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
        preferences.pendingMigration = nil
        preferences.lockMode = .none
        // The vault lock read the lock mode when it was built; this updates its state to `.open`.
        vaultLock.appWillEnterForeground()
    }

    // MARK: - Auth Success

    /// Called by the lock screen after an unlock: dismisses only the lock screen (an in-progress migration
    /// screen under it survives), removes the privacy cover, reloads the browser, then runs the work
    /// waiting in `afterLockScreenDismissed`.
    func didAuthenticate(in window: UIWindow?) {
        guard let root = window?.rootViewController else {
            runLockScreenDismissalWaiters()
            return
        }
        let topVC = root.topmostPresentedController
        // topVC is the lock screen itself; dismiss it specifically, not its presenter's whole chain.
        let dismisser = topVC.presentingViewController ?? root
        dismisser.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.hidePrivacyScreen(in: window)
            self.reloadFileBrowser(in: window)
            self.runLockScreenDismissalWaiters()
        }
    }

    /// Runs `action` now when no lock screen is in the window's presentation stack, otherwise once the lock
    /// screen has been dismissed after an unlock. Anything presented over the lock screen would be
    /// dismissed with it.
    func afterLockScreenDismissed(in window: UIWindow?, _ action: @escaping @MainActor () -> Void) {
        guard let root = window?.rootViewController,
              sequence(first: root, next: \.presentedViewController)
                .contains(where: { $0 is LegacyLockScreenViewController })
        else {
            action()
            return
        }
        lockScreenDismissalWaiters.append(action)
    }

    private func runLockScreenDismissalWaiters() {
        let waiters = lockScreenDismissalWaiters
        lockScreenDismissalWaiters = []
        for waiter in waiters { waiter() }
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
        let topVC = root.topmostPresentedController

        guard !(topVC is LegacyLockScreenViewController) else {
            hidePrivacyScreen(in: window)
            return
        }
        let lock = LegacyLockScreenViewController(
            vaultLock: vaultLock, preferences: preferences
        ) { [weak self] window in
            self?.didAuthenticate(in: window)
        }
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
           let browser = nav.viewControllers.first as? LegacyFileBrowserViewController {
            browser.reloadAfterAuth()
        }
    }
}
