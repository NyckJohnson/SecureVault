import UIKit

// coverage-exempt-file: declarations only

/// Presents the setup wizard, the lock screen and the privacy cover over the scene's window.
@MainActor
protocol AppLockCoordinating: AnyObject {
    /// Called when the scene connects; shows the wizard or the lock screen as needed.
    func sceneDidConnect(window: UIWindow, needsSetup: Bool)
    /// Shows the privacy cover when unlocked with a lock.
    func sceneWillResignActive()
    /// Locks the vault when a lock is set.
    func sceneDidEnterBackground()
    /// Shows the lock screen when locked, else hides the cover.
    func sceneDidBecomeActive()
    /// Called after the user unlocks.
    var onUnlocked: (() -> Void)? { get set }
}
