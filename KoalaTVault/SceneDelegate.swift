//
//  SceneDelegate.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit
import os

/// Runs the app's one scene: the one-time vault upgrade at connect, the root browser of the vault that is `current`
/// (swapped on every change of vault) with the lock screen over it, the housekeeping after an encrypted vault opens,
/// the unencrypted vault's trash purge, and the scene's lifecycle events for the lock coordinator (privacy cover,
/// closing the vault and the lock screen on background).
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// Shown when `upgradeIfNeeded` fails (journey 12).
    static let upgradeFailedMessage = "Couldn't finish updating your vaults. Restart the app to try again."

    var window: UIWindow?
    /// The window's root, holding the current vault's root browser; the lock screen is presented over it.
    private let root = VaultRootViewController()
    /// The connect sequence (upgrade, then the browser and the lock screen).
    private var startTask: Task<Void, Never>?
    /// Follows `currentUpdates` once the scene has started.
    private var vaultChangesTask: Task<Void, Never>?
    /// The housekeeping after an encrypted vault opened; cancelled when the vault changes again.
    private var postOpenTask: Task<Void, Never>?
    /// The leftover encryption started from the Migration screen.
    private var encryptionTask: Task<Void, Never>?
    /// Whether the connect sequence has finished; until then a return to the foreground purges nothing (the
    /// upgrade may still be moving the unencrypted vault's files).
    private var hasStarted = false
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "SceneDelegate")

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
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window

        // Listed now, deleted in the background: the first frame doesn't wait for a large leftover.
        dependencies.removeTemporaryFilesOfEarlierLaunches()
        startTask = Task { [weak self] in await self?.start(in: window) }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        startTask?.cancel()
        vaultChangesTask?.cancel()
        postOpenTask?.cancel()
        encryptionTask?.cancel()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        dependencies.lockCoordinator.sceneWillResignActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        dependencies.lockCoordinator.sceneDidEnterBackground()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // The first foreground of a launch comes before the connect sequence has finished; that one purges itself.
        guard hasStarted else { return }
        purgeUnencryptedTrash()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        dependencies.lockCoordinator.sceneDidBecomeActive()
    }

    // MARK: - Connect

    /// The one-time upgrade (its failure reported over the lock screen; the app carries on), then the root browser
    /// of `current` with the lock screen over it, then following vault changes and purging the unencrypted vault's
    /// expired trash.
    private func start(in window: UIWindow) async {
        let dependencies = dependencies
        var upgradeFailed = false
        do {
            try await dependencies.vaultLock.upgradeIfNeeded()
        } catch {
            // Not logged in detail: an I/O message can name the user's files. The next launch carries on.
            logger.error("The vault upgrade failed")
            upgradeFailed = true
        }
        #if DEBUG
        await dependencies.seedTestVaultIfRequested()
        #endif
        guard !Task.isCancelled else { return }

        let services = dependencies.openServices(for: dependencies.vaultLock.current)
        root.show(services.browserFactory.makeRootBrowser())
        dependencies.lockCoordinator.sceneDidConnect(window: window)
        observeVaultChanges()
        hasStarted = true
        purgeUnencryptedTrash()
        if upgradeFailed {
            let alert = UIAlertController(title: nil, message: Self.upgradeFailedMessage, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            topmostController.present(alert, animated: true)
        }
    }

    // MARK: - Vault changes

    private func observeVaultChanges() {
        let updates = dependencies.vaultLock.currentUpdates()
        vaultChangesTask = Task { [weak self] in
            for await vault in updates {
                self?.vaultDidChange(to: vault)
            }
        }
    }

    /// Another vault is `current`: dismisses what is presented over the browser (unless the lock screen is up, which
    /// stays), clears the old vault's thumbnails, stops a leftover encryption, builds the new vault's services and
    /// swaps the root browser; for an encrypted vault, then the housekeeping and the leftover encryption.
    private func vaultDidChange(to vault: OpenVault) {
        let dependencies = dependencies
        postOpenTask?.cancel()
        postOpenTask = nil
        dependencies.lockScreens.cancelPendingAction()

        if !dependencies.lockScreens.isLockScreenUp, root.presentedViewController != nil {
            root.dismiss(animated: false)
        }
        dependencies.lockMigrator.cancel()
        encryptionTask?.cancel()
        encryptionTask = nil
        let services = dependencies.openServices(for: vault)
        root.show(services.browserFactory.makeRootBrowser())

        guard vault.isEncrypted else { return }
        postOpenTask = Task { [weak self] in await self?.afterOpening(vault) }
    }

    /// The housekeeping after `vault` opened (purge expired trash, sweep orphans), then, if it has files left
    /// unencrypted, the Migration screen once the lock screen has gone.
    private func afterOpening(_ vault: OpenVault) async {
        await PostUnlockMaintenance.run(vaultStore: vault.store, now: Date())
        guard !Task.isCancelled else { return }
        let hasUnencryptedFiles: Bool
        do {
            hasUnencryptedFiles = try await vault.store.hasUnencryptedFiles()
        } catch {
            // The check runs again the next time the vault opens.
            logger.error("Checking the open vault for unencrypted files failed")
            return
        }
        guard hasUnencryptedFiles, !Task.isCancelled, isCurrent(vault) else { return }
        dependencies.lockScreens.whenLockScreenGone { [weak self] in
            self?.presentMigration(for: vault)
        }
    }

    /// Shows the Migration screen and, once it shows, encrypts `vault`'s leftover files; the browser reloads when it
    /// finishes.
    private func presentMigration(for vault: OpenVault) {
        let dependencies = dependencies
        guard isCurrent(vault), let services = dependencies.currentServices else { return }
        let browserFactory = services.browserFactory
        let migration = services.settingsFactory.makeMigration(onFinish: { [weak browserFactory] _ in
            browserFactory?.reloadAll()
        })
        let migrator = dependencies.lockMigrator
        topmostController.present(migration, animated: true) { [weak self] in
            guard let self, self.isCurrent(vault) else { return }
            self.encryptionTask = Task { await migrator.encryptLeftovers(in: vault.store) }
        }
    }

    // MARK: - Helpers

    /// Whether `vault` is still the open vault.
    private func isCurrent(_ vault: OpenVault) -> Bool {
        dependencies.vaultLock.current.id == vault.id
    }

    /// Purges the unencrypted vault's trash items older than 30 days (at launch and on each return to the
    /// foreground). A failure is logged and the purge runs again next time.
    private func purgeUnencryptedTrash() {
        let store = dependencies.vaultLock.unencryptedVault.store
        let logger = logger
        Task {
            do {
                _ = try await store.purgeExpiredTrash(now: Date())
            } catch {
                logger.error("Purging the unencrypted vault's expired trash failed")
            }
        }
    }

    /// The controller at the top of the presentation chain over the root.
    private var topmostController: UIViewController {
        var controller: UIViewController = root
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
}

// MARK: - Root container

/// The window's root: holds the current vault's root browser as its one child, so the browser can be swapped on a
/// vault change while the lock screen stays presented over the root.
private final class VaultRootViewController: UIViewController {
    private var browser: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }

    /// Replaces the shown browser with `browser`.
    func show(_ browser: UIViewController) {
        if let old = self.browser {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(browser)
        browser.view.frame = view.bounds
        browser.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(browser.view)
        browser.didMove(toParent: self)
        self.browser = browser
        setNeedsStatusBarAppearanceUpdate()
    }

    override var childForStatusBarStyle: UIViewController? { browser }
    override var childForStatusBarHidden: UIViewController? { browser }
    override var childForHomeIndicatorAutoHidden: UIViewController? { browser }
}
