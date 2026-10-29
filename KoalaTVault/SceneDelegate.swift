//
//  SceneDelegate.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit
import os

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// Follows the vault lock's state to run the post-unlock steps.
    private var lockStateObservation: Task<Void, Never>?
    /// Set on a genuine backgrounding, so a return (not the cold launch) purges the trash with no lock.
    private var didEnterBackground = false
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "SceneDelegate")

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
    /// The app's one vault lock.
    private var vaultLock: any VaultLocking { dependencies.vaultLock }
    /// The legacy lock screen and privacy cover presenter.
    private var authService: AuthService { dependencies.authService }
    /// The app's one lock migration.
    private var lockMigrator: any LockMigrating { dependencies.lockMigrator }

    deinit {
        lockStateObservation?.cancel()
    }

    // MARK: - UIWindowSceneDelegate

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let root = LegacyFileBrowserViewController(directory: vaultStore.root, services: dependencies.browserServices)
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = true
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window

        // Subscribe before anything can unlock, so no change is missed.
        observeLockState()
        if !dependencies.preferences.hasCompletedSetup {
            let wizard = LegacySetupWizardViewController(vaultLock: vaultLock)
            wizard.modalPresentationStyle = .fullScreen
            nav.present(wizard, animated: false)
        } else {
            // Runs the launch recovery of a pending encrypt first, so `resumeIfPending` (in the post-unlock
            // steps, which never run before this) sees the record it left.
            let showedLockScreen = authService.handleInitialLaunch(in: window)
            // The stream yields changes only: a vault that is already usable (no lock) runs the steps now.
            if !showedLockScreen && vaultLock.state != .locked {
                handleVaultUnlocked()
            }
        }

        vaultStore.removeAllTemporaryFiles()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        authService.handleForeground(in: window)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // With no lock there is no unlock on a return from background, so purge here. Not on the cold
        // launch, where the post-unlock steps already purged.
        guard didEnterBackground else { return }
        didEnterBackground = false
        guard vaultLock.lockMode == .none else { return }
        Task { await purgeExpiredTrashIfUnlocked() }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        authService.handleWillResignActive(in: window)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        didEnterBackground = true
        // With a lock: the key is wiped and the store's temporary files removed; the thumbnails go too.
        vaultLock.appDidEnterBackground()
        if vaultLock.lockMode != .none {
            dependencies.thumbnails.clearCache()
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        lockStateObservation?.cancel()
        lockStateObservation = nil
    }

    // MARK: - Vault Unlock

    /// Runs the post-unlock steps on every change to `.unlocked`.
    private func observeLockState() {
        guard lockStateObservation == nil else { return }
        let updates = vaultLock.stateUpdates()
        lockStateObservation = Task { [weak self] in
            for await state in updates where state == .unlocked {
                self?.handleVaultUnlocked()
            }
        }
    }

    private func handleVaultUnlocked() {
        Task {
            // After unlock, so the key is loaded and the folder indexes can be read.
            await PostUnlockMaintenance.run(
                vaultStore: vaultStore, preferences: dependencies.preferences, now: Date())
            // Anything presented over the lock screen would be dismissed with it.
            authService.afterLockScreenDismissed(in: window) { [weak self] in
                self?.presentPendingMigration()
            }
        }
    }

    /// Resumes a pending migration: presents the Migration screen, which resumes it, or, when one is already
    /// showing (a migration paused under the lock screen), resumes it under that screen.
    private func presentPendingMigration() {
        let lockMigrator = lockMigrator
        guard let pending = lockMigrator.pending,
              let root = window?.rootViewController else { return }
        // Check the whole presentation stack, not just its top.
        let stack = sequence(first: root, next: \.presentedViewController)
        guard !stack.contains(where: { $0 is LegacyMigrationViewController }) else {
            Task { await lockMigrator.resumeIfPending() }
            return
        }
        let topVC = root.topmostPresentedController
        // The migrator finishes the lock and keys itself; nothing is left to do when the screen closes.
        let migration = LegacyMigrationViewController(
            type: pending.kind, migrator: lockMigrator, begin: { await $0.resumeIfPending() },
            onComplete: { [logger] completedFully in
                logger.info("Resumed migration closed (completed fully: \(completedFully, privacy: .public))")
            })
        topVC.present(migration, animated: true)
    }

    /// Removes trash items older than 30 days. Only with no lock, or with the key loaded:
    /// while locked the encrypted trash map can't be read. A failure (e.g. an unreadable trash
    /// map, which is never overwritten) is ignored: the purge runs again after the next unlock.
    private func purgeExpiredTrashIfUnlocked() async {
        guard vaultLock.state != .locked else { return }
        _ = try? await vaultStore.purgeExpiredTrash(now: Date())
    }
}
