import UIKit

/// The vault picker: binds `VaultPickerViewModel` (feature multiple-vaults-duress-password; built in Browser
/// unit 3). Until then it shows a placeholder.
final class VaultPickerViewController: UIViewController {
    private let viewModel: VaultPickerViewModel

    /// - Parameter viewModel: the screen's logic and state.
    init(viewModel: VaultPickerViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Choose Vault"
        view.backgroundColor = .systemBackground
    }
}

#if DEBUG
    @available(iOS 17.0, *)
    #Preview("Vault Picker") {
        UINavigationController(
            rootViewController: VaultPickerViewController(viewModel: VaultPickerViewModel(lock: MockVaultLocking())))
    }
#endif
