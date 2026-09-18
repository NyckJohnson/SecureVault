//
//  SceneDelegate.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private func setupMigrationResumeObserver() {
        NotificationCenter.default.addObserver(forName: AuthService.vaultUnlockedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resumePendingMigrationIfNeeded()
        }
    }

    private func resumePendingMigrationIfNeeded() {
        guard let type = PreferencesService.shared.pendingMigrationType,
              let root = window?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        guard !(topVC is MigrationViewController) else { return }
        let targetLockMode = PreferencesService.shared.pendingMigrationTargetLockMode
        let migration = MigrationViewController(type: type, targetLockMode: targetLockMode) { completedFully in
            AuthService.shared.finalizeMigration(type: type, targetLockMode: targetLockMode, completedFully: completedFully)
        }
        topVC.present(migration, animated: true)
    }
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        setupMigrationResumeObserver()
        let root = FileBrowserViewController(directory: VaultDirectory.root)
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = true
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()

        if !PreferencesService.shared.hasCompletedSetup {
            let wizard = SetupWizardViewController()
            wizard.modalPresentationStyle = .fullScreen
            nav.present(wizard, animated: false)
        } else {
            AuthService.shared.handleInitialLaunch(in: window)
        }
        
        // check trash folder for expired items
        FileSystem.shared.cleanupExpiredTrashItems(for: .root)
        FileSystem.shared.cleanupTempFiles()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AuthService.shared.handleForeground(in: window)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        AuthService.shared.handleBackground(in: window)
    }
}
