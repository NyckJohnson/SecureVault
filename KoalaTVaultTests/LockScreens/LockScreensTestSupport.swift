import UIKit

@testable import KoalaTVault

/// A `LockPresenting` that records what the coordinator asks for instead of touching UIKit.
@MainActor
final class RecordingLockPresenter: LockPresenting {
    /// A recorded request.
    enum Request: Equatable {
        case presentLockScreen
        case dismissLockScreen
        case showPrivacyCover
        case hidePrivacyCover
    }

    private(set) var requests: [Request] = []
    /// The screens presented, in order.
    private(set) var presentedScreens: [UIViewController] = []
    /// The screens dismissed, in order.
    private(set) var dismissedScreens: [UIViewController] = []
    /// The windows the lock screen and the cover were requested in, in order.
    private(set) var windows: [UIWindow] = []

    func count(of request: Request) -> Int {
        requests.filter { $0 == request }.count
    }

    func presentLockScreen(_ screen: UIViewController, in window: UIWindow) {
        requests.append(.presentLockScreen)
        presentedScreens.append(screen)
        windows.append(window)
    }

    func dismissLockScreen(_ screen: UIViewController) {
        requests.append(.dismissLockScreen)
        dismissedScreens.append(screen)
    }

    func showPrivacyCover(in window: UIWindow) {
        requests.append(.showPrivacyCover)
        windows.append(window)
    }

    func hidePrivacyCover() { requests.append(.hidePrivacyCover) }
}
