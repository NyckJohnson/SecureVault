import UIKit

/// Makes the real viewer and editor screens.
@MainActor
final class LiveViewerFactory: ViewerFactory {
    private let store: any VaultStoring
    private let videoAssets: any VideoAssetProviding
    private let exportPresenter: ExportPresenter

    /// - Parameters:
    ///   - store: the app's vault store, which opens the items and writes documents.
    ///   - videoAssets: the app's one video loader.
    ///   - exportPresenter: the app's one export presenter, for the viewer's Share button.
    init(store: any VaultStoring, videoAssets: any VideoAssetProviding, exportPresenter: ExportPresenter) {
        self.store = store
        self.videoAssets = videoAssets
        self.exportPresenter = exportPresenter
    }

    func makeViewer(items: [VaultItem], startingAt index: Int) -> UIViewController {
        FileViewerViewController(
            items: items, startingAt: index, store: store, videoAssets: videoAssets,
            exportPresenter: exportPresenter, makeEditor: { [store] item in Self.makeEditor(for: item, store: store) })
    }

    func makeEditor(for item: VaultItem) -> UIViewController {
        Self.makeEditor(for: item, store: store)
    }

    private static func makeEditor(for item: VaultItem, store: any VaultStoring) -> UIViewController {
        let navigation = UINavigationController(rootViewController: TextEditorViewController(item: item, store: store))
        navigation.modalPresentationStyle = .fullScreen
        return navigation
    }
}
