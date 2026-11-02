import UIKit
import os

/// The real `LockPresenting`: puts the wizard, the lock screen and the privacy cover on screen.
@MainActor
final class LockPresenter: LockPresenting {
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "LockPresenter")
    // UIKit owns a presented controller, so these clear themselves if it goes away some other way.
    private weak var setupWizard: UIViewController?
    private weak var lockScreen: UIViewController?
    private var lockScreenDismissalCompletion: (@MainActor () -> Void)?
    private var privacyCover: PrivacyCoverView?

    func presentSetupWizard(_ viewModel: SetupWizardViewModel, in window: UIWindow) {
        guard let topmost = topmostController(in: window) else { return }
        let wizard = SetupWizardViewController(viewModel: viewModel)
        wizard.modalPresentationStyle = .fullScreen
        setupWizard = wizard
        topmost.present(wizard, animated: false)
    }

    func presentLockScreen(_ viewModel: LockScreenViewModel, in window: UIWindow) {
        guard let topmost = topmostController(in: window) else { return }
        let screen = LockScreenViewController(viewModel: viewModel)
        screen.modalPresentationStyle = .fullScreen
        lockScreen = screen
        topmost.present(screen, animated: false)
    }

    func dismissSetupWizard() {
        setupWizard?.presentingViewController?.dismiss(animated: true)
        setupWizard = nil
    }

    func dismissLockScreen(completion: @escaping @MainActor () -> Void) {
        // Asking the presenter, not the lock screen: it removes the lock screen and anything over it, and
        // leaves the presenter (such as a migration screen) in place.
        guard let screen = lockScreen, let presenter = screen.presentingViewController else {
            completion()
            return
        }
        // A dismissal is in flight only while UIKit is still transitioning (a queued one included). A stored
        // completion with no transition means UIKit refused that dismissal, so this call must try again.
        if lockScreenDismissalCompletion != nil, presenter.transitionCoordinator != nil { return }
        lockScreenDismissalCompletion = completion
        presenter.dismiss(animated: true) { self.finishLockScreenDismissal(of: screen) }
    }

    /// Clears the dismissed screen, unless a newer one has taken its place, and runs the stored completion once.
    private func finishLockScreenDismissal(of screen: UIViewController) {
        if lockScreen === screen { lockScreen = nil }
        let completion = lockScreenDismissalCompletion
        lockScreenDismissalCompletion = nil
        completion?()
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

    private func topmostController(in window: UIWindow) -> UIViewController? {
        guard let root = window.rootViewController else {
            logger.error("The window has no root view controller; nothing was presented")
            return nil
        }
        return root.topmostPresentedController
    }
}
