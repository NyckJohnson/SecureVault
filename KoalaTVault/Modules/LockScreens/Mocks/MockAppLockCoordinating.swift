import UIKit

/// Records the scene events it receives instead of presenting anything.
@MainActor
final class MockAppLockCoordinating: AppLockCoordinating {
    /// A recorded call.
    enum Call: Equatable, Sendable {
        case sceneDidConnect
        case sceneWillResignActive
        case sceneDidEnterBackground
        case sceneDidBecomeActive
    }

    /// Every call so far, in order.
    private(set) var calls: [Call] = []

    init() {}

    func sceneDidConnect(window: UIWindow) {
        calls.append(.sceneDidConnect)
    }

    func sceneWillResignActive() {
        calls.append(.sceneWillResignActive)
    }

    func sceneDidEnterBackground() {
        calls.append(.sceneDidEnterBackground)
    }

    func sceneDidBecomeActive() {
        calls.append(.sceneDidBecomeActive)
    }
}
