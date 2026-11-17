import UIKit

/// Returns a placeholder lock screen and keeps the `onDone` and `onNeedsPro` handlers so a test or preview can call
/// them.
@MainActor
final class MockVaultsScreenFactory: VaultsScreenFactory {
    /// How many lock screens were made.
    private(set) var makeLockScreenCount = 0
    /// The `onDone` handler of the last screen made.
    private(set) var onDone: (() -> Void)?
    /// The `onNeedsPro` handler of the last screen made.
    private(set) var onNeedsPro: ((UIViewController) -> Void)?
    /// The last screen made.
    private(set) var lastScreen: UIViewController?

    init() {}

    func makeLockScreen(
        onDone: @escaping () -> Void,
        onNeedsPro: @escaping (UIViewController) -> Void
    ) -> UIViewController {
        makeLockScreenCount += 1
        self.onDone = onDone
        self.onNeedsPro = onNeedsPro
        let screen = UIViewController()
        screen.title = "Vaults"
        screen.view.backgroundColor = .systemBackground
        let navigation = UINavigationController(rootViewController: screen)
        navigation.modalPresentationStyle = .fullScreen
        lastScreen = navigation
        return navigation
    }

    /// Acts as if a vault was opened on the last screen: calls `onDone`.
    func simulateDone() {
        onDone?()
    }

    /// Acts as if the user tapped Create New Vault without Pro: calls `onNeedsPro` with the last screen.
    func simulateNeedsPro() {
        guard let lastScreen else { return }
        onNeedsPro?(lastScreen)
    }
}
