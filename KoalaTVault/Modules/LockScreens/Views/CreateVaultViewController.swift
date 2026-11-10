import UIKit

/// The Create Vault screen: binds `CreateVaultViewModel` (feature multiple-vaults-duress-password; built in
/// LockScreens unit 3). Until then it shows a placeholder.
final class CreateVaultViewController: UIViewController {
    private let viewModel: CreateVaultViewModel

    /// - Parameter viewModel: the screen's logic and state.
    init(viewModel: CreateVaultViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Create Vault"
        view.backgroundColor = .systemBackground
    }
}

#if DEBUG
    @available(iOS 17.0, *)
    #Preview("Create Vault") {
        UINavigationController(
            rootViewController: CreateVaultViewController(viewModel: CreateVaultViewModel(lock: MockVaultLocking())))
    }
#endif
