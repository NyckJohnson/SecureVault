import UIKit
import os

/// The real `LockPresenting`: puts the lock screen and the privacy cover on screen.
@MainActor
final class LockPresenter: LockPresenting {
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "LockPresenter")
    private var privacyCover: PrivacyCoverView?

    func presentLockScreen(_ screen: UIViewController, in window: UIWindow) {
        guard let root = window.rootViewController else {
            logger.error("The window has no root view controller; nothing was presented")
            return
        }
        // Anything presented over the browser (settings, a viewer, a sheet) goes first, so the lock screen covers
        // the browser itself and nothing stays open under it.
        if root.presentedViewController != nil {
            root.dismiss(animated: false)
        }
        screen.modalPresentationStyle = .fullScreen
        root.topmostPresentedController.present(screen, animated: false)
    }

    func dismissLockScreen(_ screen: UIViewController) {
        // Asking the presenter removes the lock screen and anything over it (such as the paywall).
        screen.presentingViewController?.dismiss(animated: true)
    }

    func showPrivacyCover(in window: UIWindow) {
        guard privacyCover?.superview == nil else { return }
        let cover = PrivacyCoverView(frame: window.bounds)
        window.addSubview(cover)
        privacyCover = cover
    }

    func hidePrivacyCover() {
        privacyCover?.removeFromSuperview()
        privacyCover = nil
    }
}
