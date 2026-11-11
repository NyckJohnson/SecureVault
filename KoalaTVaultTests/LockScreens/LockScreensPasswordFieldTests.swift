import Testing
import UIKit

@testable import KoalaTVault

@MainActor
@Suite struct LockScreensPasswordFieldTests {
    private func field(_ identifier: String, in root: UIView) -> UITextField? {
        if let textField = root as? UITextField, textField.accessibilityIdentifier == identifier {
            return textField
        }
        for subview in root.subviews {
            if let found = field(identifier, in: subview) { return found }
        }
        return nil
    }

    @Test("The lock screen password field sets no textContentType")
    func vaultsPasswordField() throws {
        let controller = VaultsViewController(viewModel: VaultsViewModel(lock: MockVaultLocking()))
        controller.loadViewIfNeeded()
        let textField = try #require(field("vaults.passwordField", in: controller.view))
        #expect(textField.textContentType == nil)
    }

    @Test(
        "Create Vault password and confirm fields set no textContentType",
        arguments: ["createVault.passwordField", "createVault.confirmField"])
    func createVaultPasswordFields(identifier: String) throws {
        let controller = CreateVaultViewController(
            viewModel: CreateVaultViewModel(lock: MockVaultLocking()))
        controller.loadViewIfNeeded()
        let textField = try #require(field(identifier, in: controller.view))
        #expect(textField.textContentType == nil)
    }
}
