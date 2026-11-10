import UIKit

/// Returns a placeholder Vaults screen and keeps the `onNeedsPro` handler so a test or preview can call it.
@MainActor
final class MockVaultsScreenFactory: VaultsScreenFactory {
    /// How many Vaults screens were made.
    private(set) var makeVaultsCount = 0
    /// The `onNeedsPro` handler of the last screen made.
    private(set) var onNeedsPro: ((UIViewController) -> Void)?
    /// The last screen made.
    private(set) var lastScreen: UIViewController?

    init() {}

    func makeVaults(onNeedsPro: @escaping (UIViewController) -> Void) -> UIViewController {
        makeVaultsCount += 1
        self.onNeedsPro = onNeedsPro
        let screen = UIViewController()
        screen.title = "Vaults"
        screen.view.backgroundColor = .systemBackground
        let navigation = UINavigationController(rootViewController: screen)
        lastScreen = navigation
        return navigation
    }

    /// Acts as if the user tapped Create New Vault without Pro: calls `onNeedsPro` with the last screen.
    func simulateNeedsPro() {
        guard let lastScreen else { return }
        onNeedsPro?(lastScreen)
    }
}
