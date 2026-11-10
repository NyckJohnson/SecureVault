import UIKit

/// The Vaults screen: binds `VaultsViewModel` (feature multiple-vaults-duress-password; built in LockScreens
/// unit 3). Until then it shows a placeholder.
final class VaultsViewController: UIViewController {
    private let viewModel: VaultsViewModel

    /// - Parameter viewModel: the screen's logic and state.
    init(viewModel: VaultsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Vaults"
        view.backgroundColor = .systemBackground
    }
}

/// The live `VaultsScreenFactory` (feature multiple-vaults-duress-password; built in LockScreens unit 3).
@MainActor
final class LiveVaultsScreenFactory: VaultsScreenFactory {
    private let lock: any VaultLocking

    /// - Parameter lock: the app's vaults.
    init(lock: any VaultLocking) {
        self.lock = lock
    }

    func makeVaults(onNeedsPro: @escaping (UIViewController) -> Void) -> UIViewController {
        fatalError("Not implemented: LiveVaultsScreenFactory.makeVaults")
    }
}

#if DEBUG
    @available(iOS 17.0, *)
    #Preview("Vaults") {
        UINavigationController(
            rootViewController: VaultsViewController(viewModel: VaultsViewModel(lock: MockVaultLocking())))
    }
#endif
