import UIKit

/// Records the scene events it receives instead of presenting anything.
@MainActor
final class MockAppLockCoordinating: AppLockCoordinating {
    /// A recorded call.
    enum Call: Equatable, Sendable {
        case sceneDidConnect(needsSetup: Bool)
        case sceneWillResignActive
        case sceneDidEnterBackground
        case sceneDidBecomeActive
    }

    /// Every call so far, in order.
    private(set) var calls: [Call] = []
    var onUnlocked: (() -> Void)?

    init() {}

    func sceneDidConnect(window: UIWindow, needsSetup: Bool) {
        calls.append(.sceneDidConnect(needsSetup: needsSetup))
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

    /// Acts as if the user unlocked: calls `onUnlocked`.
    func simulateUnlock() {
        onUnlocked?()
    }
}
