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
    private let vaults: any VaultLocking
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
        self.vaults = lock
        self.preferences = preferences
        self.masterKeys = masterKeys
        self.presenter = presenter
    }

    func sceneDidConnect(window: UIWindow) {
        fatalError("Not implemented: AppLockCoordinator.sceneDidConnect (feature multiple-vaults-duress-password)")
    }

    func sceneWillResignActive() {
        guard vaults.appWillResignActive(), let window else { return }
        presenter.showPrivacyCover(in: window)
    }

    func sceneDidEnterBackground() {
        vaults.appDidEnterBackground()
    }

    func sceneDidBecomeActive() {
        fatalError("Not implemented: AppLockCoordinator.sceneDidBecomeActive (feature multiple-vaults-duress-password)")
    }

    func lock() {
        fatalError("Not implemented: AppLockCoordinator.lock (feature multiple-vaults-duress-password)")
    }
}
