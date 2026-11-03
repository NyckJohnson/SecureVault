import Testing
import UIKit

@testable import KoalaTVault

/// `LiveBrowserFactory(store:preferences:thumbnails:exporter:exportPresenter:importPresenter:viewerFactory:
/// settingsFactory:)` conforming to `BrowserFactory`.
@MainActor
@Suite struct LiveBrowserFactoryTests {
    private func makeFactory(store: MockVaultStoring) -> LiveBrowserFactory {
        let exporter = MockVaultExporting()
        return LiveBrowserFactory(
            store: store, preferences: MockPreferencesStoring(), thumbnails: BrowserFakeThumbnails(),
            exporter: exporter, exportPresenter: ExportPresenter(exporter: exporter),
            importPresenter: ImportPresenter(
                importer: MockVaultImporting(), cameraRoll: MockCameraRollDeleting(), store: store),
            viewerFactory: MockViewerFactory(), settingsFactory: MockSettingsFactory())
    }

    private func loads(_ store: MockVaultStoring) -> Int {
        store.calls.filter { if case .contents = $0 { true } else { false } }.count
    }

    @Test("makeRootBrowser returns a large-title navigation controller rooted at a file browser")
    func rootBrowserShape() {
        let navigation = makeFactory(store: MockVaultStoring()).makeRootBrowser()
        #expect(navigation.navigationBar.prefersLargeTitles)
        #expect(navigation.viewControllers.first is FileBrowserViewController)
    }

    @Test("reloadAll lists the folder again in the root and in a pushed subfolder")
    func reloadAllCountsLoads() async throws {
        let store = MockVaultStoring()
        let factory = makeFactory(store: store)
        let navigation = factory.makeRootBrowser()
        let host = BrowserViewHost(content: navigation)
        let grid = try #require(await host.waitForElement("fileGrid") as? UICollectionView)
        await BrowserViewSupport.waitUntil {
            grid.numberOfSections > 0 && grid.numberOfItems(inSection: 0) > 0
        }
        grid.layoutIfNeeded()
        let photos = try #require(
            (0..<grid.numberOfItems(inSection: 0)).first {
                grid.cellForItem(at: IndexPath(item: $0, section: 0))?.accessibilityIdentifier
                    == "browser.cell.Photos"
            })
        grid.delegate?.collectionView?(grid, didSelectItemAt: IndexPath(item: photos, section: 0))
        await BrowserViewSupport.waitUntil { navigation.viewControllers.count == 2 }
        await BrowserViewSupport.settle()
        let before = loads(store)
        factory.reloadAll()
        await BrowserViewSupport.waitUntil { loads(store) >= before + 2 }
        #expect(loads(store) == before + 2)
        withExtendedLifetime(host) {}
    }

    @Test("reloadAll reloads every root the factory made")
    func reloadAllReloadsTwoRoots() async throws {
        let store = MockVaultStoring()
        let factory = makeFactory(store: store)
        let first = BrowserViewHost(content: factory.makeRootBrowser())
        let second = BrowserViewHost(content: factory.makeRootBrowser())
        await BrowserViewSupport.waitUntil { loads(store) >= 2 }
        await BrowserViewSupport.settle()
        let before = loads(store)
        factory.reloadAll()
        await BrowserViewSupport.waitUntil { loads(store) >= before + 2 }
        #expect(loads(store) == before + 2)
        withExtendedLifetime((first, second)) {}
    }

    @Test("reloadAll after the navigation controller is released does nothing")
    func reloadAllAfterReleaseDoesNothing() async {
        let store = MockVaultStoring()
        let factory = makeFactory(store: store)
        do { _ = factory.makeRootBrowser() }
        factory.reloadAll()
        await BrowserViewSupport.settle()
        #expect(loads(store) == 0)
    }
}
