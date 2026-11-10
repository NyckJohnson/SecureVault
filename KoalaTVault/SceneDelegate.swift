//
//  SceneDelegate.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit
import os

/// Feature multiple-vaults-duress-password transition: the lock contracts changed and their live types are stubs
/// until their modules are rebuilt, so the scene only shows the root browser. The vault changes, the privacy cover,
/// closing on background and the post-open housekeeping return in the shell step after Browser (see the memo's
/// "Shell changes"). Nothing here calls a stubbed member, so the app and the unit-test host still launch.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// The composition root, built once by `AppDelegate`.
    private var dependencies: AppDependencies {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            // Unreachable: AppDelegate is the app's `@main` delegate.
            fatalError("SceneDelegate: the application delegate is not AppDelegate")
        }
        return appDelegate.dependencies
    }

    // MARK: - UIWindowSceneDelegate

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = dependencies.browserFactory.makeRootBrowser()
        window.makeKeyAndVisible()
        self.window = window

        // Listed now, deleted in the background: the first frame doesn't wait for a large leftover.
        dependencies.removeTemporaryFilesOfEarlierLaunches()
    }
}
