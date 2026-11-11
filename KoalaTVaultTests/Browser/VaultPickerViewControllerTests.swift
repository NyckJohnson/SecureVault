import Testing
import UIKit

@testable import KoalaTVault

@MainActor
@Suite struct VaultPickerViewControllerTests {
    private func field(_ identifier: String, in root: UIView) -> UITextField? {
        if let textField = root as? UITextField, textField.accessibilityIdentifier == identifier {
            return textField
        }
        for subview in root.subviews {
            if let found = field(identifier, in: subview) { return found }
        }
        return nil
    }

    @Test(
        "The vault picker password field sets no textContentType",
        arguments: [true, false])
    func passwordFieldHasNoContentType(isMove: Bool) throws {
        let controller = VaultPickerViewController(
            viewModel: VaultPickerViewModel(lock: MockVaultLocking(), isMove: isMove))
        controller.loadViewIfNeeded()
        let textField = try #require(field("vaultPicker.passwordField", in: controller.view))
        #expect(textField.textContentType == nil)
    }
}
