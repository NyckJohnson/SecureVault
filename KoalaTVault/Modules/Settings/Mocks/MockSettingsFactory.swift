import UIKit

/// Returns plain placeholder screens and keeps the callbacks so a test can run them; records every call.
@MainActor
final class MockSettingsFactory: SettingsFactory {
    /// A recorded call.
    enum Call: Equatable, Sendable { case makeSettings, makePaywall, makeMigration }

    /// Every call so far, in order.
    private(set) var calls: [Call] = []
    /// The `onUnlock` of the last paywall made.
    private(set) var lastOnUnlock: (() -> Void)?
    /// The `onFinish` of the last migration screen made.
    private(set) var lastOnFinish: ((Bool) -> Void)?

    init() {}

    func makeSettings() -> UIViewController {
        calls.append(.makeSettings)
        let controller = UIViewController()
        controller.title = "Security"
        return UINavigationController(rootViewController: controller)
    }

    func makePaywall(onUnlock: @escaping () -> Void) -> UIViewController {
        calls.append(.makePaywall)
        lastOnUnlock = onUnlock
        let controller = UIViewController()
        controller.title = "Unlock Pro"
        return controller
    }

    func makeMigration(onFinish: @escaping (Bool) -> Void) -> UIViewController {
        calls.append(.makeMigration)
        lastOnFinish = onFinish
        let controller = UIViewController()
        controller.title = "Encrypting Files"
        controller.modalPresentationStyle = .fullScreen
        return controller
    }
}
