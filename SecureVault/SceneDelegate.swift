//
//  SceneDelegate.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
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
        FileSystem.shared.cleanupExpiredTrashItems()
        FileSystem.shared.cleanupTempFiles()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AuthService.shared.handleForeground(in: window)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        AuthService.shared.handleBackground(in: window)
    }
}
