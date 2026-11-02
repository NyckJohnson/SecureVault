import UIKit
import os

/// Puts the lock screens on screen; the coordinator decides when.
@MainActor
protocol LockPresenting: AnyObject {
    /// Presents the wizard full-screen, unanimated.
    func presentSetupWizard(_ viewModel: SetupWizardViewModel, in window: UIWindow)
    /// Presents the lock screen full-screen on the topmost controller.
    func presentLockScreen(_ viewModel: LockScreenViewModel, in window: UIWindow)
    /// Dismisses the wizard.
    func dismissSetupWizard()
    /// Dismisses only the lock screen; a screen under it survives. `completion` runs once the dismissal
    /// has finished, so it can present a screen without losing it to the animation.
    func dismissLockScreen(completion: @escaping @MainActor () -> Void)
    /// Covers the window.
    func showPrivacyCover(in window: UIWindow)
    /// Removes the cover, if it shows.
    func hidePrivacyCover()
}

/// Decides when the setup wizard, the lock screen and the privacy cover show, from the scene's events and
/// the vault lock's state, and recovers an interrupted encryption at launch.
@MainActor
final class AppLockCoordinator: AppLockCoordinating {
    var onUnlocked: (() -> Void)?

    private let lock: any VaultLocking
    private let preferences: any PreferencesStoring
    private let masterKeys: any MasterKeyStoring
    private let presenter: any LockPresenting
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "AppLockCoordinator")
    private weak var window: UIWindow?
    /// The lock screen on screen, if any.
    private var lockScreen: LockScreenViewModel?

    /// - Parameters:
    ///   - lock: the app's vault lock.
    ///   - preferences: read and repaired for a pending migration at launch.
    ///   - masterKeys: asked at launch whether a password blob exists.
    ///   - presenter: puts the screens on screen.
    init(
        lock: any VaultLocking,
        preferences: any PreferencesStoring,
        masterKeys: any MasterKeyStoring,
        presenter: any LockPresenting
    ) {
        self.lock = lock
        self.preferences = preferences
        self.masterKeys = masterKeys
        self.presenter = presenter
    }

    func sceneDidConnect(window: UIWindow, needsSetup: Bool) {
        self.window = window
        if needsSetup {
            presentSetupWizard(in: window)
            return
        }
        let encryptionNeedsPassword = recoverPendingEncryption()
        if lock.state == .locked || encryptionNeedsPassword {
            presentLockScreenIfNeeded()
        }
    }

    func sceneWillResignActive() {
        guard lock.appWillResignActive(), let window else { return }
        presenter.showPrivacyCover(in: window)
    }

    func sceneDidEnterBackground() {
        lock.appDidEnterBackground()
    }

    func sceneDidBecomeActive() {
        lock.appWillEnterForeground()
        if lock.state == .locked {
            presentLockScreenIfNeeded()
            if let lockScreen {
                Task { await lockScreen.sceneDidBecomeActive() }
            }
        }
        // Also when locked: a cover left from before the background would hide the lock screen.
        presenter.hidePrivacyCover()
    }

    private func presentSetupWizard(in window: UIWindow) {
        let wizard = SetupWizardViewModel(lock: lock, preferences: preferences)
        wizard.onFinished = { [weak self] in self?.presenter.dismissSetupWizard() }
        presenter.presentSetupWizard(wizard, in: window)
    }

    private func presentLockScreenIfNeeded() {
        guard lockScreen == nil, let window else { return }
        let viewModel = LockScreenViewModel(lock: lock, preferences: preferences)
        viewModel.onUnlocked = { [weak self] in self?.lockScreenDidUnlock() }
        lockScreen = viewModel
        presenter.presentLockScreen(viewModel, in: window)
    }

    private func lockScreenDidUnlock() {
        lockScreen = nil
        presenter.dismissLockScreen { [weak self] in
            guard let self else { return }
            self.presenter.hidePrivacyCover()
            self.onUnlocked?()
        }
    }

    /// Settles a pending encrypt migration; returns whether it needs the password. With no password blob it
    /// can never finish (no key exists, so nothing was encrypted with it): the record is dropped and the vault
    /// stays without a lock. A Keychain error counts as a blob, so nothing is lost to a passing failure.
    private func recoverPendingEncryption() -> Bool {
        guard preferences.pendingMigration?.kind == .encrypt else { return false }
        do {
            if try masterKeys.hasMasterKeyBlob() { return true }
        } catch {
            logger.error("Keychain read failed at launch: \(error.localizedDescription, privacy: .public)")
            return true
        }
        logger.error("Pending encryption without a password; finishing as No Lock")
        preferences.pendingMigration = nil
        preferences.lockMode = .none
        // The vault lock read the lock mode when it was built; this updates its state to `.open`.
        lock.appWillEnterForeground()
        return false
    }
}
