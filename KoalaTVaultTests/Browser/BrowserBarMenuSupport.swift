import UIKit

@testable import KoalaTVault

/// How the tests look at the browser's bar menus (memo, Browser "Bar menus"): a bar button item identified
/// `browser.actionsMenuButton` (outside select mode) or `browser.selectActionsMenuButton` (select mode), whose
/// menu holds `UIAction`s identified `browser.menu.*`. The button may be a `UIBarButtonItem` with a `menu` or one
/// whose custom view is a `UIButton` with a menu; both are supported.
@MainActor
enum BarMenu {
    static func items(of controller: UIViewController) -> [UIBarButtonItem] {
        (controller.navigationItem.leftBarButtonItems ?? [])
            + (controller.navigationItem.rightBarButtonItems ?? []) + (controller.toolbarItems ?? [])
    }

    private static func identifier(of item: UIBarButtonItem) -> String? {
        item.accessibilityIdentifier ?? item.customView?.accessibilityIdentifier
    }

    static func item(_ id: String, in controller: UIViewController) -> UIBarButtonItem? {
        items(of: controller).first { identifier(of: $0) == id }
    }

    static func menu(_ id: String, in controller: UIViewController) -> UIMenu? {
        guard let item = item(id, in: controller) else { return nil }
        return item.menu ?? (item.customView as? UIButton)?.menu
    }

    /// True when a tap opens the menu (it is the item's primary action: no target action and no primary action).
    static func opensOnTap(_ id: String, in controller: UIViewController) -> Bool {
        guard let item = item(id, in: controller) else { return false }
        if let button = item.customView as? UIButton { return button.showsMenuAsPrimaryAction }
        return item.menu != nil && item.primaryAction == nil && item.action == nil
    }

    /// False when the item is missing; tests that care assert it exists with `item(_:in:)`.
    static func isEnabled(_ id: String, in controller: UIViewController) -> Bool {
        guard let item = item(id, in: controller) else { return false }
        if let button = item.customView as? UIButton { return button.isEnabled && item.isEnabled }
        return item.isEnabled
    }

    /// Every action of the menu in display order, sections flattened.
    static func actions(_ id: String, in controller: UIViewController) -> [UIAction] {
        func flatten(_ elements: [UIMenuElement]) -> [UIAction] {
            elements.flatMap { element -> [UIAction] in
                if let action = element as? UIAction { return [action] }
                if let menu = element as? UIMenu { return flatten(menu.children) }
                return []
            }
        }
        return menu(id, in: controller).map { flatten($0.children) } ?? []
    }

    static let actionsID = "browser.actionsMenuButton"
    static let selectActionsID = "browser.selectActionsMenuButton"

    /// The action with this entry identifier, from whichever bar menu holds it.
    static func entry(_ entry: String, in controller: UIViewController) -> UIAction? {
        for id in [actionsID, selectActionsID] {
            if let action = actions(id, in: controller).first(where: { $0.identifier.rawValue == entry }) {
                return action
            }
        }
        return nil
    }

    static func perform(_ entry: String, in controller: UIViewController) {
        self.entry(entry, in: controller)?.performWithSender(nil, target: nil)
    }

    /// Whether `image` is the SF Symbol with this name.
    static func isSymbol(_ image: UIImage?, named name: String) -> Bool {
        guard let image, let expected = UIImage(systemName: name) else { return false }
        return image.isSymbolImage && (image == expected || image.pngData() == expected.pngData())
    }
}
