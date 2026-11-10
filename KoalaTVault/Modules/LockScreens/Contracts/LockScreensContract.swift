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
}

/// Builds the Vaults screen.
@MainActor
protocol VaultsScreenFactory: AnyObject {
    /// The Vaults screen in its navigation controller. `onNeedsPro` is called with the screen to present the paywall
    /// from (Create New Vault without Pro, an encrypted vault already there).
    func makeVaults(onNeedsPro: @escaping (UIViewController) -> Void) -> UIViewController
}
