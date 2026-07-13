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
        let root = FileBrowserViewController(directory: FileStoreService.shared.rootURL)
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = true
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()

        if !UserDefaults.standard.bool(forKey: "hasCompletedSetup") {
            let wizard = SetupWizardViewController()
            wizard.modalPresentationStyle = .fullScreen
            nav.present(wizard, animated: false)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if AuthService.shared.appDidForeground() {
            showLockScreen()
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        AuthService.shared.appDidBackground()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }

    private func showLockScreen() {
        guard let root = window?.rootViewController else { return }
        guard !(root.presentedViewController is LockScreenViewController) else { return }
        let lock = LockScreenViewController()
        lock.delegate = self
        lock.modalPresentationStyle = .fullScreen
        root.present(lock, animated: false)
    }
}

extension SceneDelegate: LockScreenDelegate {
    func lockScreenDidAuthenticate() {
        window?.rootViewController?.dismiss(animated: true)
    }
}
