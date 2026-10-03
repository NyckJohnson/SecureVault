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
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AuthService.shared.handleForeground(in: window)
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
}
