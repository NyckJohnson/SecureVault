import Testing
import UIKit

@testable import KoalaTVault

/// Seams the Browser view tests assume (the code-writer builds them):
///
/// `FileBrowserViewController(directory:store:preferences:thumbnails:exporter:exportPresenter:importPresenter:
/// viewerFactory:settingsFactory:)` is a `UIViewController & AlertPresenting` that makes its own
/// `FileBrowserViewModel` (alerts = itself) and loads it when it appears. Its `fileGrid` is a
/// `UICollectionView` whose data source returns `FileCell`s. Bar buttons carry the memo's identifiers (nav bar
/// or the controller's `toolbarItems`).
/// Internal hooks for drag and drop (UIKit drop sessions cannot be built in a test):
/// `dropTargetAllowed(at: IndexPath?) -> Bool`, `drop(_ dragged: VaultItem?, at: IndexPath) async`,
/// `dragItems(at: IndexPath) -> [UIDragItem]` (the item's `localObject` is its `VaultItem`; the item provider
/// registers the file only when the view model's drag-out rule allows it).
///
/// `FileCell` is a `UICollectionViewCell` with `configure(with: VaultItem, thumbnails: any ThumbnailProviding,
/// folderAssetAvailable: Bool)`, an internal `thumbnailView: UIImageView`, and `accessibilityIdentifier`
/// `browser.cell.<name>`.
///
/// `FolderPickerViewController(store:preferences:excluding:directory:onChoose:onCancel:)` is shown in a
/// navigation controller, lists subfolders in a `UITableView`, and pushes a deeper picker (same callbacks)
/// when a row is selected.
@MainActor
final class BrowserViewHost {
    let window: UIWindow
    let root: UIViewController

    /// With `regularWidth` the content is hosted in a container that forces a regular horizontal size class,
    /// so an action sheet is adapted to a popover (as on iPad) and its anchor can be inspected.
    init(content: UIViewController, regularWidth: Bool = false) {
        root = content
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        if regularWidth {
            let container = UIViewController()
            container.addChild(content)
            container.view.addSubview(content.view)
            content.view.frame = container.view.bounds
            content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            content.didMove(toParent: container)
            container.setOverrideTraitCollection(
                UITraitCollection(horizontalSizeClass: .regular), forChild: content)
            window.rootViewController = container
        } else {
            window.rootViewController = content
        }
        window.makeKeyAndVisible()
        content.view.layoutIfNeeded()
    }

    var topmost: UIViewController {
        var top = root
        while let next = top.presentedViewController { top = next }
        return top
    }

    var navigation: UINavigationController? { root as? UINavigationController }

    /// The alert or sheet on top once one appears.
    func alert() async -> UIAlertController? {
        await BrowserViewSupport.waitUntil { self.topmost is UIAlertController }
        return topmost as? UIAlertController
    }

    func noAlert() async -> Bool {
        await BrowserViewSupport.settle()
        return !(topmost is UIAlertController)
    }

    /// Every controller on screen: the stack, then each presented chain (with its stack).
    private func visibleControllers() -> [UIViewController] {
        var result: [UIViewController] = []
        var current: UIViewController? = root
        while let controller = current {
            if let nav = controller as? UINavigationController {
                result += nav.viewControllers
            } else {
                result.append(controller)
            }
            current = controller.presentedViewController
        }
        return result
    }

    /// A view, or a bar button item, with this accessibility identifier.
    func element(_ id: String) -> AnyObject? {
        for controller in visibleControllers() {
            if let view = BrowserViewHost.find(id, in: controller.view) { return view }
            let items =
                (controller.navigationItem.leftBarButtonItems ?? [])
                + (controller.navigationItem.rightBarButtonItems ?? [])
                + (controller.toolbarItems ?? [])
            if let item = items.first(where: { $0.accessibilityIdentifier == id }) { return item }
        }
        return nil
    }

    func waitForElement(_ id: String) async -> AnyObject? {
        await BrowserViewSupport.waitUntil { self.element(id) != nil }
        return element(id)
    }

    static func find(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        for subview in view.subviews {
            if let found = find(id, in: subview) { return found }
        }
        return nil
    }

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

    static func texts(in view: UIView) -> [String] {
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text { result.append(text) }
        for subview in view.subviews { result += texts(in: subview) }
        return result
    }

    /// The title shown by the top of the navigation stack.
    var shownTitle: String? {
        navigation?.topViewController?.navigationItem.title ?? navigation?.topViewController?.title
    }
}

enum BrowserViewSupport {
    @MainActor
    static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<3000 {
            if condition() { return }
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor
    static func settle() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

extension UIAlertController {
    /// Fires the action that confirms (the first one that is not Cancel).
    func fireConfirm() {
        actions.first { $0.style != .cancel }?.fire()
    }
}

/// Thumbnails that return a distinct image per request and can be held until the test releases them.
final class BrowserFakeThumbnails: ThumbnailProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var requestedIDs: [String] = []
    private var cancelledIDs: [String] = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var held: Set<String> = []
    private var images: [String: UIImage] = [:]

    func requested() -> [String] { lock.withLock { requestedIDs } }
    func cancelled() -> [String] { lock.withLock { cancelledIDs } }

    /// The image this fake returns for the item, made on first use.
    func image(for id: String) -> UIImage {
        lock.withLock {
            if let existing = images[id] { return existing }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
            let image = renderer.image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
            images[id] = image
            return image
        }
    }

    func hold(_ id: String) { lock.withLock { _ = held.insert(id) } }

    var isWaiting: Bool { lock.withLock { !waiting.isEmpty } }

    func release(_ id: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            held.remove(id)
            return waiting.removeValue(forKey: id)
        }
        continuation?.resume()
    }

    func thumbnail(for item: VaultItem, size: CGSize, scale: CGFloat) async -> UIImage? {
        let shouldHold = lock.withLock { () -> Bool in
            requestedIDs.append(item.id)
            return held.contains(item.id)
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { waiting[item.id] = continuation }
            }
        }
        // Only images and videos have a thumbnail; documents and the like return nil.
        guard item.isDirectory || item.kind == .image || item.kind == .video else { return nil }
        return image(for: item.id)
    }

    func cancel(_ item: VaultItem) { lock.withLock { cancelledIDs.append(item.id) } }
    func clearCache() {}
    func clearCache(for item: VaultItem) {}
}
