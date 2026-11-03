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
    /// Follows the vault lock's state to run the housekeeping on every change to `.unlocked`.
    private var lockStateObservation: Task<Void, Never>?
    /// The latest post-unlock housekeeping; a pending migration waits for it.
    private var maintenance: Task<Void, Never>?
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
    /// Presents the setup wizard, the lock screen and the privacy cover.
    private var lockCoordinator: any AppLockCoordinating { dependencies.lockCoordinator }
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
        lockCoordinator.onUnlocked = { [weak self] in self?.lockScreenDidUnlock() }
        let needsSetup = !dependencies.preferences.hasCompletedSetup
        // Runs the launch recovery of a pending encrypt first, so `resumeIfPending` (in the post-unlock
        // steps, which never run before this) sees the record it left.
        lockCoordinator.sceneDidConnect(window: window, needsSetup: needsSetup)
        // The stream yields changes only: a vault that is already usable (no lock) runs the steps now. A
        // pending encrypt that outlived the recovery is waiting for the password on the lock screen.
        if !needsSetup && vaultLock.state != .locked
            && dependencies.preferences.pendingMigration?.kind != .encrypt {
            startMaintenance()
            presentPendingMigrationAfterMaintenance()
        }

        vaultStore.removeAllTemporaryFiles()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        lockCoordinator.sceneDidBecomeActive()
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
        lockCoordinator.sceneWillResignActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        didEnterBackground = true
        // With a lock: the key is wiped and the store's temporary files removed; the thumbnails go too.
        lockCoordinator.sceneDidEnterBackground()
        if vaultLock.lockMode != .none {
            dependencies.thumbnails.clearCache()
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        lockStateObservation?.cancel()
        lockStateObservation = nil
    }

    // MARK: - Vault Unlock

    /// Runs the housekeeping on every change to `.unlocked`, whatever caused it: the lock screen, the setup
    /// wizard's password, or adding a lock in Settings.
    private func observeLockState() {
        guard lockStateObservation == nil else { return }
        let updates = vaultLock.stateUpdates()
        lockStateObservation = Task { [weak self] in
            for await state in updates where state == .unlocked {
                self?.startMaintenance()
            }
        }
    }

    private func startMaintenance() {
        // After unlock, so the key is loaded and the folder indexes can be read.
        maintenance = Task { [vaultStore, preferences = dependencies.preferences] in
            await PostUnlockMaintenance.run(vaultStore: vaultStore, preferences: preferences, now: Date())
        }
    }

    /// The lock screen has gone: anything presented from here on stays on screen.
    private func lockScreenDidUnlock() {
        reloadFileBrowser()
        presentPendingMigrationAfterMaintenance()
    }

    private func reloadFileBrowser() {
        // Assumes root is always UINavigationController with LegacyFileBrowserViewController as the first VC.
        // Update this if the root view controller hierarchy ever changes (e.g. tab bar added).
        if let nav = window?.rootViewController as? UINavigationController,
           let browser = nav.viewControllers.first as? LegacyFileBrowserViewController {
            browser.reloadAfterAuth()
        }
    }

    /// Presents a pending migration once the housekeeping has finished. If the vault locked again in the
    /// meantime, the next unlock does it, so nothing is presented over the lock screen.
    private func presentPendingMigrationAfterMaintenance() {
        // Queued behind the state update of the same unlock, which started the housekeeping.
        Task { [weak self] in
            await self?.maintenance?.value
            guard let self, self.vaultLock.state != .locked else { return }
            self.presentPendingMigration()
        }
    }

    /// Resumes a pending migration: presents the Migration screen and resumes it once shown, or, when one is already
    /// showing (a migration paused under the lock screen), resumes it under that screen.
    private func presentPendingMigration() {
        let lockMigrator = lockMigrator
        guard lockMigrator.pending != nil,
              let root = window?.rootViewController else { return }
        // Check the whole presentation stack, not just its top.
        let stack = sequence(first: root, next: \.presentedViewController)
        guard !stack.contains(where: { $0 is MigrationViewController }) else {
            Task { await lockMigrator.resumeIfPending() }
            return
        }
        let topVC = root.topmostPresentedController
        // The migrator finishes the lock and keys itself; nothing is left to do when the screen closes.
        let migration = dependencies.settingsFactory.makeMigration(onFinish: { [logger] completedFully in
            logger.info("Resumed migration closed (completed fully: \(completedFully, privacy: .public))")
        })
        // Resumed once the screen is up, as the screen used to do on first appearing.
        topVC.present(migration, animated: true) {
            Task { await lockMigrator.resumeIfPending() }
        }
    }

    /// Removes trash items older than 30 days. Only with no lock, or with the key loaded:
    /// while locked the encrypted trash map can't be read. A failure (e.g. an unreadable trash
    /// map, which is never overwritten) is ignored: the purge runs again after the next unlock.
    private func purgeExpiredTrashIfUnlocked() async {
        guard vaultLock.state != .locked else { return }
        _ = try? await vaultStore.purgeExpiredTrash(now: Date())
    }
}
