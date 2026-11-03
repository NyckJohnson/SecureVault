import Foundation
import UIKit

@testable import KoalaTVault

/// Puts a view controller in a real window so appearance callbacks, presentation and table cells work.
@MainActor
final class SettingsViewHost {
    let window: UIWindow
    let root: UIViewController

    /// - Parameter content: shown as the window's root (wrap it in a navigation controller to push).
    init(content: UIViewController) {
        root = content
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1600))
        window.rootViewController = content
        window.makeKeyAndVisible()
        content.view.layoutIfNeeded()
    }

    /// A blank root that `content` is presented from, so it can dismiss itself.
    static func presenting(_ content: UIViewController) -> SettingsViewHost {
        let host = SettingsViewHost(content: UIViewController())
        host.root.present(content, animated: false)
        content.view.layoutIfNeeded()
        return host
    }

    /// The controller shown on top of everything presented from the root.
    var topmost: UIViewController {
        var top = root
        while let next = top.presentedViewController { top = next }
        return top
    }

    /// The top of the navigation stack when the root is a navigation controller.
    var navigationTop: UIViewController? {
        (root as? UINavigationController)?.topViewController
    }

    /// The alert or action sheet on top, once one appears.
    func alert() async -> UIAlertController? {
        await SettingsTestSupport.waitUntil { self.topmost is UIAlertController }
        return topmost as? UIAlertController
    }

    /// True when no alert is up after giving pending work time to run.
    func noAlert() async -> Bool {
        await SettingsTestSupport.settle()
        return !(topmost is UIAlertController)
    }

    /// Every view (and bar button item) reachable from the visible controllers, found by identifier.
    func element(_ id: String) -> AnyObject? {
        var controller: UIViewController? = root
        while let current = controller {
            if let view = SettingsViewHost.find(id, in: current.view) { return view }
            let navigationItem = current.navigationItem
            let items = (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? [])
            for item in items
            where item.accessibilityIdentifier == id {
                return item
            }
            controller = current.presentedViewController
        }
        if let nav = root as? UINavigationController {
            for child in nav.viewControllers {
                if let view = SettingsViewHost.find(id, in: child.view) { return view }
            }
        }
        return nil
    }

    static func find(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        for subview in view.subviews {
            if let found = find(id, in: subview) { return found }
        }
        return nil
    }

    /// Waits for an element to exist.
    func waitForElement(_ id: String) async -> AnyObject? {
        await SettingsTestSupport.waitUntil { self.element(id) != nil }
        return element(id)
    }

    /// Every label text inside a view, joined; includes the cell's built-in text label.
    static func texts(in view: UIView) -> [String] {
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text { result.append(text) }
        if let cell = view as? UITableViewCell, let text = cell.textLabel?.text { result.append(text) }
        if let cell = view as? UITableViewCell {
            let configured = (cell.contentConfiguration as? UIListContentConfiguration)?.text
            if let configured { result.append(configured) }
        }
        for subview in view.subviews { result += texts(in: subview) }
        return result
    }

    /// Whether the element is enabled (a control or a bar button item).
    func isEnabled(_ id: String) -> Bool? {  // swiftlint:disable:this discouraged_optional_boolean
        if let control = element(id) as? UIControl { return control.isEnabled }
        if let item = element(id) as? UIBarButtonItem { return item.isEnabled }
        return nil
    }

    /// Taps a button or bar button item.
    func tap(_ id: String) {
        if let control = element(id) as? UIControl {
            control.sendActions(for: .touchUpInside)
        } else if let item = element(id) as? UIBarButtonItem {
            if let action = item.primaryAction {
                action.performWithSender(item, target: nil)
            } else if let selector = item.action {
                UIApplication.shared.sendAction(selector, to: item.target, from: item, for: nil)
            }
        }
    }

    /// Selects a table row the way a tap would, by the cell's identifier.
    func selectRow(_ id: String, inTable tableID: String) {
        guard let table = element(tableID) as? UITableView,
            let cell = SettingsViewHost.find(id, in: table) as? UITableViewCell,
            let path = table.indexPath(for: cell)
        else { return }
        table.delegate?.tableView?(table, didSelectRowAt: path)
    }
}

extension UIAlertAction {
    /// Runs the action's handler, as tapping it would.
    @MainActor
    func fire() {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        guard let handler = value(forKey: "handler") else { return }
        unsafeBitCast(handler as AnyObject, to: Handler.self)(self)
    }
}

extension UIAlertController {
    func fire(_ title: String) {
        actions.first { $0.title == title }?.fire()
    }

    var actionTitles: [String] { actions.compactMap(\.title) }

    func field(_ id: String) -> UITextField? {
        textFields?.first { $0.accessibilityIdentifier == id }
    }
}

/// Stands in for `UIApplication`'s background-task calls and records them.
@MainActor
final class SettingsFakeBackgroundTime: BackgroundTimeProviding {
    private(set) var begun: [UIBackgroundTaskIdentifier] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private(set) var expirationHandlers: [() -> Void] = []
    private var next = 100

    func beginBackgroundTask(
        withName taskName: String?, expirationHandler handler: (() -> Void)?
    ) -> UIBackgroundTaskIdentifier {
        next += 1
        let identifier = UIBackgroundTaskIdentifier(rawValue: next)
        begun.append(identifier)
        if let handler { expirationHandlers.append(handler) }
        return identifier
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }

    /// Tasks begun and not yet ended.
    var openCount: Int { begun.count - ended.count }
}
