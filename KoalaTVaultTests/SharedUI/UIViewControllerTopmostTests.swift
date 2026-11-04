import Testing
import UIKit

@testable import KoalaTVault

@MainActor
private func presentAndWait(_ presenter: UIViewController, _ presented: UIViewController) async {
    presented.modalPresentationStyle = .fullScreen
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        presenter.present(presented, animated: false) { continuation.resume() }
    }
}

@MainActor
@Suite struct UIViewControllerTopmostTests {
    private func hosted() -> (UIViewController, UIWindow) {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
        return (root, window)
    }

    @Test("With nothing presented the topmost controller is the controller itself")
    func nothingPresented() {
        let (root, window) = hosted()
        defer { window.isHidden = true }
        #expect(root.topmostPresentedController === root)
    }

    @Test("The topmost controller follows presentedViewController to the end of the chain")
    func followsChain() async {
        let (root, window) = hosted()
        defer { window.isHidden = true }
        let first = UIViewController()
        let second = UIViewController()
        let third = UIViewController()
        await presentAndWait(root, first)
        await presentAndWait(first, second)
        await presentAndWait(second, third)

        #expect(root.topmostPresentedController === third)
        #expect(first.topmostPresentedController === third)
        #expect(third.topmostPresentedController === third)
    }

    @Test("The topmost controller stops before a presented controller that is being dismissed")
    func stopsBeforeDismissing() async {
        let (root, window) = hosted()
        defer { window.isHidden = true }
        let first = UIViewController()
        let second = DismissingViewController()
        await presentAndWait(root, first)
        await presentAndWait(first, second)

        second.reportsDismissing = true
        #expect(root.topmostPresentedController === first)
        #expect(first.topmostPresentedController === first)

        second.reportsDismissing = false
        #expect(root.topmostPresentedController === second)
    }

    @Test("A dismissing controller in the middle of the chain hides everything above it")
    func stopsAtFirstDismissingInChain() async {
        let (root, window) = hosted()
        defer { window.isHidden = true }
        let first = DismissingViewController()
        let second = UIViewController()
        await presentAndWait(root, first)
        await presentAndWait(first, second)

        first.reportsDismissing = true
        #expect(root.topmostPresentedController === root)
    }
}

@MainActor
private final class DismissingViewController: UIViewController {
    var reportsDismissing = false
    override var isBeingDismissed: Bool { reportsDismissing }
}
