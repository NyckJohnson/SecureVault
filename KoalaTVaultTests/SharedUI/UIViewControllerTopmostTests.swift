import Testing
import UIKit

@testable import KoalaTVault

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
    func followsChain() {
        let (root, window) = hosted()
        defer { window.isHidden = true }
        let first = UIViewController()
        let second = UIViewController()
        let third = UIViewController()
        root.present(first, animated: false)
        first.present(second, animated: false)
        second.present(third, animated: false)

        #expect(root.topmostPresentedController === third)
        #expect(first.topmostPresentedController === third)
        #expect(third.topmostPresentedController === third)
    }
}
