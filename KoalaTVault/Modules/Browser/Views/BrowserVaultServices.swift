import UIKit

/// What the browser needs for the Lock button and Move/Copy to Vault (feature multiple-vaults-duress-password):
/// the app's vaults, the transfer between them, and the Lock action the shell gives.
@MainActor
struct BrowserVaultServices {
    let lock: any VaultLocking
    let transfer: any VaultTransferring
    let onLock: () -> Void
}

#if DEBUG
    @available(iOS 17.0, *)
    #Preview("Browser: root of an encrypted vault, Lock button") {
        let store = MockVaultStoring(name: "Travel", isEncrypted: true)
        let exporter = MockVaultExporting()
        let lock = MockVaultLocking(
            vaults: [MockVaultLocking.Vault(id: "primary", name: "My Vault", password: "correct horse")], isPro: true)
        let browser = FileBrowserViewController(
            directory: store.root, store: store, preferences: MockPreferencesStoring(),
            thumbnails: MockThumbnailProviding(), exporter: exporter,
            exportPresenter: ExportPresenter(exporter: exporter),
            importPresenter: ImportPresenter(
                importer: MockVaultImporting(), cameraRoll: MockCameraRollDeleting(), store: store),
            viewerFactory: MockViewerFactory(), settingsFactory: MockSettingsFactory(),
            vaultServices: BrowserVaultServices(
                lock: lock, transfer: MockVaultTransferring(), onLock: {}))
        let navigation = UINavigationController(rootViewController: browser)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }
#endif
