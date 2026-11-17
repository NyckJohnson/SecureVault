import UIKit

// coverage-exempt-file: declarations only

/// Shows the privacy cover over the scene's window and closes the open vault when the app goes to the background.
@MainActor
protocol AppLockCoordinating: AnyObject {
    /// Called when the scene connects.
    func sceneDidConnect(window: UIWindow)
    /// Shows the privacy cover when an encrypted vault is open.
    func sceneWillResignActive()
    /// Closes the open vault.
    func sceneDidEnterBackground()
    /// Hides the privacy cover.
    func sceneDidBecomeActive()
    /// Closes the open vault and shows the lock screen (the browser's Lock button, a deleted vault).
    func lock()
}

/// Builds the lock screen.
@MainActor
protocol VaultsScreenFactory: AnyObject {
    /// The lock screen in its navigation controller. `onDone` is called when a vault is open (by password, Face ID,
    /// a new vault, or the unencrypted vault). `onNeedsPro` is called with the screen to present the paywall from
    /// (Create New Vault without Pro, an encrypted vault already there).
    func makeLockScreen(
        onDone: @escaping () -> Void,
        onNeedsPro: @escaping (UIViewController) -> Void
    ) -> UIViewController
}
