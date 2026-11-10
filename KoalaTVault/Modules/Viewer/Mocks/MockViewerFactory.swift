import UIKit

/// Returns plain placeholder screens titled after the item; records every call.
@MainActor
final class MockViewerFactory: ViewerFactory {
    /// A recorded call; items are identified by their `id`.
    enum Call: Equatable, Sendable {
        case makeViewer(itemIDs: [String], startingAt: Int)
        case makeEditor(String)
    }

    /// Every call so far, in order.
    private(set) var calls: [Call] = []

    init() {}

    func makeViewer(items: [VaultItem], startingAt index: Int) -> UIViewController {
        calls.append(.makeViewer(itemIDs: items.map(\.id), startingAt: index))
        let controller = UIViewController()
        controller.title = items.indices.contains(index) ? items[index].name : nil
        controller.modalPresentationStyle = .fullScreen
        return controller
    }

    func makeEditor(for item: VaultItem) -> UIViewController {
        calls.append(.makeEditor(item.id))
        let controller = UIViewController()
        controller.title = item.name
        return UINavigationController(rootViewController: controller)
    }
}
