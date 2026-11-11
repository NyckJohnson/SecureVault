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

    private func view(_ identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for subview in root.subviews {
            if let found = view(identifier, in: subview) { return found }
        }
        return nil
    }

    private func showCreateVault() -> (UIWindow, CreateVaultViewController) {
        let controller = CreateVaultViewController(
            viewModel: CreateVaultViewModel(lock: MockVaultLocking()))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        return (window, controller)
    }

    private func tapCreate(in controller: CreateVaultViewController) throws {
        let button = try #require(view("createVault.createButton", in: controller.view) as? UIControl)
        button.sendActions(for: .touchUpInside)
    }

    @Test("Create Vault shows a name field with no textContentType")
    func createVaultNameField() throws {
        let (window, controller) = showCreateVault()
        defer { window.isHidden = true }
        let textField = try #require(field("createVault.nameField", in: controller.view))
        #expect(textField.textContentType == nil)
    }

    @Test(
        "Create Vault has no password or confirmation field on the screen",
        arguments: [
            "createVault.passwordField", "createVault.confirmField",
            "createVault.alertPasswordField", "createVault.alertConfirmField",
        ])
    func createVaultScreenHasNoPasswordFields(identifier: String) {
        let (window, controller) = showCreateVault()
        defer { window.isHidden = true }
        #expect(field(identifier, in: controller.view) == nil)
    }

    @Test("Create Vault has a Create button on the screen")
    func createVaultCreateButton() {
        let (window, controller) = showCreateVault()
        defer { window.isHidden = true }
        #expect(view("createVault.createButton", in: controller.view) != nil)
    }

    @Test("Create with a name presents the Set Password alert with its message")
    func createPresentsSetPasswordAlert() throws {
        let (window, controller) = showCreateVault()
        defer { window.isHidden = true }
        let name = try #require(field("createVault.nameField", in: controller.view))
        name.text = "Work"
        try tapCreate(in: controller)
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        #expect(alert.title == "Set Password")
        #expect(alert.message == "Choose a password for this vault.")
        #expect(alert.preferredStyle == .alert)
    }

    @Test("The Set Password alert has Cancel and Create actions")
    func alertHasCancelAndCreate() throws {
        let (window, controller) = showCreateVault()
        defer { window.isHidden = true }
        let name = try #require(field("createVault.nameField", in: controller.view))
        name.text = "Work"
        try tapCreate(in: controller)
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        let actions = alert.actions
        #expect(actions.count == 2)
        #expect(actions.contains { $0.title == "Cancel" && $0.style == .cancel })
        #expect(actions.contains { $0.title == "Create" })
    }

    @Test("The Set Password alert has secure password and confirm fields with no textContentType")
    func alertFields() throws {
        let (window, controller) = showCreateVault()
        defer { window.isHidden = true }
        let name = try #require(field("createVault.nameField", in: controller.view))
        name.text = "Work"
        try tapCreate(in: controller)
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        let fields = try #require(alert.textFields)
        #expect(fields.count == 2)
        let password = try #require(
            fields.first { $0.accessibilityIdentifier == "createVault.alertPasswordField" })
        let confirm = try #require(
            fields.first { $0.accessibilityIdentifier == "createVault.alertConfirmField" })
        #expect(password.isSecureTextEntry)
        #expect(confirm.isSecureTextEntry)
        #expect(password.textContentType == nil)
        #expect(confirm.textContentType == nil)
    }

    @Test(
        "Create with a blank name presents no alert and shows the name error",
        arguments: ["", "   ", " \t "])
    func blankNameShowsErrorWithoutAlert(name: String) async throws {
        let (window, controller) = showCreateVault()
        defer { window.isHidden = true }
        let nameField = try #require(field("createVault.nameField", in: controller.view))
        nameField.text = name
        try tapCreate(in: controller)
        let expected = "Enter a name for the vault"
        for _ in 0..<20 {
            let label = view("createVault.errorLabel", in: controller.view) as? UILabel
            if label?.text == expected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(controller.presentedViewController == nil)
        let label = try #require(view("createVault.errorLabel", in: controller.view) as? UILabel)
        #expect(label.text == "Enter a name for the vault")
    }
}
