import UIKit

/// Returns a navigation controller with a plain placeholder root; records every call.
@MainActor
final class MockBrowserFactory: BrowserFactory {
    /// A recorded call.
    enum Call: Equatable, Sendable { case makeRootBrowser, reloadAll }

    /// Every call so far, in order.
    private(set) var calls: [Call] = []

    init() {}

    func makeRootBrowser() -> UINavigationController {
        calls.append(.makeRootBrowser)
        let controller = UIViewController()
        controller.title = "KoalaTVault"
        return UINavigationController(rootViewController: controller)
    }

    func reloadAll() {
        calls.append(.reloadAll)
    }
}
