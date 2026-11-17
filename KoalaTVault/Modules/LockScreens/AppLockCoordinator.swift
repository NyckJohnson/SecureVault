import UIKit

/// Puts the lock screen and the privacy cover on screen; the coordinator decides when.
@MainActor
protocol LockPresenting: AnyObject {
    /// Presents `screen` full-screen, unanimated, after dismissing anything presented over the window's root.
    func presentLockScreen(_ screen: UIViewController, in window: UIWindow)
    /// Dismisses `screen`, if it is still presented.
    func dismissLockScreen(_ screen: UIViewController)
    /// Covers the window.
    func showPrivacyCover(in window: UIWindow)
    /// Removes the cover, if it shows.
    func hidePrivacyCover()
}

/// Decides when the lock screen and the privacy cover show, from the scene's events: the lock screen at launch, on
/// every return from the background and on `lock()`, for any vault; the cover while the app is inactive with an
/// encrypted vault open. At most one lock screen is up at a time.
@MainActor
final class AppLockCoordinator: AppLockCoordinating {
    private let vaults: any VaultLocking
    private let screens: any VaultsScreenFactory
    private let presenter: any LockPresenting
    private let onNeedsPro: (UIViewController) -> Void
    private weak var window: UIWindow?
    /// The lock screen on screen, if any; cleared when it reports a vault open.
    private var lockScreen: UIViewController?

    /// - Parameters:
    ///   - lock: the app's vaults.
    ///   - screens: builds the lock screen.
    ///   - presenter: puts the lock screen and the cover on screen.
    ///   - onNeedsPro: called with the lock screen to present the paywall from.
    init(
        lock: any VaultLocking,
        screens: any VaultsScreenFactory,
        presenter: any LockPresenting,
        onNeedsPro: @escaping (UIViewController) -> Void
    ) {
        self.vaults = lock
        self.screens = screens
        self.presenter = presenter
        self.onNeedsPro = onNeedsPro
    }

    func sceneDidConnect(window: UIWindow) {
        self.window = window
        showLockScreen()
    }

    func sceneWillResignActive() {
        guard vaults.appWillResignActive(), let window else { return }
        presenter.showPrivacyCover(in: window)
    }

    func sceneDidEnterBackground() {
        vaults.appDidEnterBackground()
        showLockScreen()
    }

    func sceneDidBecomeActive() {
        presenter.hidePrivacyCover()
    }

    func lock() {
        vaults.close()
        showLockScreen()
    }

    /// Presents a new lock screen unless one is already up or no window is connected yet.
    private func showLockScreen() {
        guard lockScreen == nil, let window else { return }
        // The holder breaks the cycle screen → handler → screen, and lets `onDone` name the screen it belongs to.
        let holder = ScreenHolder()
        let screen = screens.makeLockScreen(
            onDone: { [weak self] in
                guard let self, let screen = holder.screen else { return }
                self.lockScreenDone(screen)
            },
            onNeedsPro: { [weak self] controller in self?.onNeedsPro(controller) })
        holder.screen = screen
        lockScreen = screen
        presenter.presentLockScreen(screen, in: window)
    }

    /// Dismisses `screen` once a vault is open; a stale screen's late call changes nothing.
    private func lockScreenDone(_ screen: UIViewController) {
        guard lockScreen === screen else { return }
        lockScreen = nil
        presenter.dismissLockScreen(screen)
    }
}

/// Weakly holds the lock screen its own handlers belong to.
@MainActor
private final class ScreenHolder {
    weak var screen: UIViewController?
}
