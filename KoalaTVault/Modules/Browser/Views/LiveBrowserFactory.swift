import UIKit

/// Makes the real root file browser and reloads the browsers it made.
@MainActor
final class LiveBrowserFactory: BrowserFactory {
    private let store: any VaultStoring
    private let preferences: any PreferencesStoring
    private let thumbnails: any ThumbnailProviding
    private let exporter: any VaultExporting
    private let exportPresenter: ExportPresenter
    private let importPresenter: ImportPresenter
    private let viewerFactory: any ViewerFactory
    private let settingsFactory: any SettingsFactory
    private let vaultServices: BrowserVaultServices
    /// The navigation controllers `makeRootBrowser()` made, held weakly so a dropped one goes away.
    private var navigations: [WeakNavigation] = []

    /// - Parameters:
    ///   - store: the app's one vault store.
    ///   - preferences: the app's settings (sort, lock state for the drag-out rule).
    ///   - thumbnails: the app's one thumbnail provider.
    ///   - exporter: prepares items for sharing (the one the export presenter uses).
    ///   - exportPresenter: the app's one export presenter.
    ///   - importPresenter: the app's one import presenter.
    ///   - viewerFactory: makes the viewer and the editor.
    ///   - settingsFactory: makes Settings and the paywall.
    ///   - vaultServices: the app's vaults, the transfer and the Lock action, for the Lock button and
    ///     Move/Copy to Vault (feature multiple-vaults-duress-password).
    init(
        store: any VaultStoring, preferences: any PreferencesStoring, thumbnails: any ThumbnailProviding,
        exporter: any VaultExporting, exportPresenter: ExportPresenter, importPresenter: ImportPresenter,
        viewerFactory: any ViewerFactory, settingsFactory: any SettingsFactory,
        vaultServices: BrowserVaultServices
    ) {
        self.store = store
        self.preferences = preferences
        self.thumbnails = thumbnails
        self.exporter = exporter
        self.exportPresenter = exportPresenter
        self.importPresenter = importPresenter
        self.viewerFactory = viewerFactory
        self.settingsFactory = settingsFactory
        self.vaultServices = vaultServices
    }

    /// A navigation controller (large titles, as today) rooted at the browser of the vault root.
    func makeRootBrowser() -> UINavigationController {
        let root = FileBrowserViewController(
            directory: store.root, store: store, preferences: preferences, thumbnails: thumbnails,
            exporter: exporter, exportPresenter: exportPresenter, importPresenter: importPresenter,
            viewerFactory: viewerFactory, settingsFactory: settingsFactory, vaultServices: vaultServices)
        let navigation = UINavigationController(rootViewController: root)
        navigation.navigationBar.prefersLargeTitles = true
        navigations.removeAll { $0.navigation == nil }
        navigations.append(WeakNavigation(navigation: navigation))
        return navigation
    }

    /// Lists the folder again in every browser on each navigation stack this factory made (the root and
    /// any subfolders pushed on it).
    func reloadAll() {
        navigations.removeAll { $0.navigation == nil }
        for entry in navigations {
            guard let navigation = entry.navigation else { continue }
            for case let browser as FileBrowserViewController in navigation.viewControllers {
                browser.reload()
            }
        }
    }
}

/// A navigation controller the factory made, held weakly.
@MainActor
private struct WeakNavigation {
    weak var navigation: UINavigationController?
}
