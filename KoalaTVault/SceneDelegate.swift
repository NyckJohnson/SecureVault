//
//  SceneDelegate.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var vaultUnlockObserver: NSObjectProtocol?

    // MARK: - UIWindowSceneDelegate
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        setupVaultUnlockObserver()

        let root = FileBrowserViewController(directory: .root)
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = true
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window

        if !PreferencesService.shared.hasCompletedSetup {
            let wizard = SetupWizardViewController()
            wizard.modalPresentationStyle = .fullScreen
            nav.present(wizard, animated: false)
        } else {
            AuthService.shared.handleInitialLaunch(in: window)
        }

        FileSystem.shared.cleanupTempFiles()
        FileSystem.shared.sweepOrphanedEncryptedFiles(in: .root)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AuthService.shared.handleForeground(in: window)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // No-lock mode never posts vaultUnlocked on a return from background, so purge here.
        // `hasAuthenticated` is still false on a cold launch, where vaultUnlocked already purged.
        guard AuthService.shared.lockMode == .none, AuthService.shared.hasAuthenticated else { return }
        purgeExpiredTrashIfUnlocked()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        AuthService.shared.handleWillResignActive(in: window)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        AuthService.shared.handleDidEnterBackground(in: window)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let observer = vaultUnlockObserver {
            NotificationCenter.default.removeObserver(observer)
            vaultUnlockObserver = nil
        }
    }

    // MARK: - Vault Unlock

    private func setupVaultUnlockObserver() {
        guard vaultUnlockObserver == nil else { return }
        vaultUnlockObserver = NotificationCenter.default.addObserver(
            forName: AuthService.vaultUnlockedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleVaultUnlocked()
            }
        }
    }

    private func handleVaultUnlocked() {
        purgeExpiredTrashIfUnlocked()
        guard let type = PreferencesService.shared.pendingMigrationType,
              let root = window?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController {
            if presented is MigrationViewController { return }   // new: check the whole stack
            topVC = presented
        }
        guard !(topVC is MigrationViewController) else { return }
        let targetLockMode = PreferencesService.shared.pendingMigrationTargetLockMode
        let migration = MigrationViewController(type: type, targetLockMode: targetLockMode) { completedFully in
            AuthService.shared.finalizeMigration(type: type, targetLockMode: targetLockMode, completedFully: completedFully)
        }
        topVC.present(migration, animated: true)
    }

    /// Removes trash items older than 30 days. Only with no lock, or with the key loaded:
    /// while locked the encrypted trash map can't be read, and a legacy plaintext one would
    /// be rewritten as plaintext. Runs on the main thread, like the orphan sweep.
    private func purgeExpiredTrashIfUnlocked() {
        guard AuthService.shared.lockMode == .none || CryptoService.shared.isKeyLoaded else { return }
        FileSystem.shared.cleanupExpiredTrashItems(for: .root)
    }
}
