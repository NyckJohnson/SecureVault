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

    /// The composition root, built once by `AppDelegate`.
    private var dependencies: AppDependencies {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            // Unreachable: AppDelegate is the app's `@main` delegate.
            fatalError("SceneDelegate: the application delegate is not AppDelegate")
        }
        return appDelegate.dependencies
    }

    /// The app's one vault store.
    private var vaultStore: any VaultStoring { dependencies.vaultStore }

    // MARK: - UIWindowSceneDelegate
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        setupVaultUnlockObserver()

        let root = LegacyFileBrowserViewController(directory: vaultStore.root, services: dependencies.browserServices)
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = true
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window

        if !LegacyStorage.current.preferences.hasCompletedSetup {
            let wizard = LegacySetupWizardViewController()
            wizard.modalPresentationStyle = .fullScreen
            nav.present(wizard, animated: false)
        } else {
            AuthService.shared.handleInitialLaunch(in: window)
        }

        vaultStore.removeAllTemporaryFiles()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AuthService.shared.handleForeground(in: window)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // No-lock mode never posts vaultUnlocked on a return from background, so purge here.
        // `hasAuthenticated` is still false on a cold launch, where vaultUnlocked already purged.
        guard AuthService.shared.lockMode == .none, AuthService.shared.hasAuthenticated else { return }
        Task { await purgeExpiredTrashIfUnlocked() }
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
        Task {
            await purgeExpiredTrashIfUnlocked()
            // After unlock, so the key is loaded and the folder indexes can be read.
            // A no-op without the key (no-lock mode). A migration in progress has copies not
            // indexed yet; the sweep runs after it finishes instead (on a later unlock).
            if LegacyStorage.current.preferences.pendingMigration == nil {
                await vaultStore.sweepOrphans()
            }
            presentPendingMigration()
        }
    }

    /// Presents the Migration screen for a pending migration, unless one is already showing.
    private func presentPendingMigration() {
        guard let pending = LegacyStorage.current.preferences.pendingMigration,
              let root = window?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController {
            if presented is LegacyMigrationViewController { return }   // new: check the whole stack
            topVC = presented
        }
        guard !(topVC is LegacyMigrationViewController) else { return }
        let type = pending.kind
        let targetLockMode = pending.targetLockMode
        let migration = LegacyMigrationViewController(
            type: type, vaultStore: vaultStore, targetLockMode: targetLockMode
        ) { completedFully in
            AuthService.shared.finalizeMigration(type: type, targetLockMode: targetLockMode, completedFully: completedFully)
        }
        topVC.present(migration, animated: true)
    }

    /// Removes trash items older than 30 days. Only with no lock, or with the key loaded:
    /// while locked the encrypted trash map can't be read. A failure (e.g. an unreadable trash
    /// map, which is never overwritten) is ignored: the purge runs again after the next unlock.
    private func purgeExpiredTrashIfUnlocked() async {
        guard AuthService.shared.lockMode == .none || LegacyStorage.current.masterKeyStore.isKeyLoaded else { return }
        _ = try? await vaultStore.purgeExpiredTrash(now: Date())
    }
}
