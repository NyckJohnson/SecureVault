import UIKit

@testable import KoalaTVault

/// How the tests look at the browser's title row (memo, Browser "Bar layout"): a row under the navigation bar,
/// pinned above the grid, so it is found as views of the controller's view that are not inside a scroll view.
/// The back arrow is the view with the identifier `browser.backButton` (subfolder) or `lockButton` (root); the
/// folder name (or "Select Items" / "N Selected") is a `UILabel` whose text is that string.
@MainActor
enum TitleRow {
    /// Every view under `root` that is not inside a scroll view (the grid scrolls; the title row does not).
    static func pinnedViews(in root: UIView) -> [UIView] {
        var result: [UIView] = []
        for subview in root.subviews {
            if subview is UIScrollView { continue }
            result.append(subview)
            result += pinnedViews(in: subview)
        }
        return result
    }

    static func isVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha < 0.01 { return false }
            current = candidate.superview
        }
        return true
    }

    /// The visible, pinned label with this text.
    static func label(_ text: String, in controller: UIViewController) -> UILabel? {
        controller.view.layoutIfNeeded()
        return pinnedViews(in: controller.view).compactMap { $0 as? UILabel }
            .first { $0.text == text && isVisible($0) }
    }

    /// The pinned view with this identifier, visible or not.
    static func arrow(_ id: String, in controller: UIViewController) -> UIView? {
        controller.view.layoutIfNeeded()
        return pinnedViews(in: controller.view).first { $0.accessibilityIdentifier == id }
    }

    static func visibleArrow(_ id: String, in controller: UIViewController) -> UIView? {
        arrow(id, in: controller).flatMap { isVisible($0) ? $0 : nil }
    }

    static func shows(_ text: String, in controller: UIViewController) -> Bool {
        label(text, in: controller) != nil
    }

    static func frame(of view: UIView, in controller: UIViewController) -> CGRect {
        controller.view.convert(view.bounds, from: view)
    }

    /// Identifiers of every bar item (left, right, toolbar) of the controller.
    static func barIdentifiers(of controller: UIViewController) -> [String] {
        let item = controller.navigationItem
        let items =
            (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
            + (controller.toolbarItems ?? [])
        return items.map { $0.accessibilityIdentifier ?? ($0.customView?.accessibilityIdentifier ?? "") }
    }
}
