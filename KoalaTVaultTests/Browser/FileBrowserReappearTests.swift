import Testing
import UIKit

@testable import KoalaTVault

/// Feature multiple-vaults-duress-password (device retest 3): a browser reloads its folder every time it comes
/// back on screen after it first appeared, so changes made deeper in the stack or from a full-screen screen
/// over it show on return. The reload is quiet while the vault is locked.
@MainActor
extension FileBrowserViewControllerTests {
    private func gridNames(of controller: UIViewController) -> [String] {
        controller.view.layoutIfNeeded()
        guard let grid = BrowserViewHost.find("fileGrid", in: controller.view) as? UICollectionView,
            grid.numberOfSections > 0
        else { return [] }
        grid.layoutIfNeeded()
        return (0..<grid.numberOfItems(inSection: 0)).compactMap { item in
            grid.cellForItem(at: IndexPath(item: item, section: 0))?.accessibilityIdentifier?
                .replacingOccurrences(of: "browser.cell.", with: "")
        }
    }

    private func storeItem(_ name: String, in store: MockVaultStoring) throws -> VaultItem {
        try #require(store.allItems.first { $0.name == name })
    }

    private func loadCount(_ store: MockVaultStoring) -> Int {
        store.calls.filter { if case .contents = $0 { true } else { false } }.count
    }

    private func pushFolder(
        _ name: String, from rig: Rig, expecting count: Int
    ) async throws -> FileBrowserViewController {
        let top = try #require(rig.host.navigation?.topViewController)
        top.view.layoutIfNeeded()
        let grid = try #require(BrowserViewHost.find("fileGrid", in: top.view) as? UICollectionView)
        await BrowserViewSupport.waitUntil { gridNames(of: top).contains(name) }
        let index = try #require(gridNames(of: top).firstIndex(of: name))
        grid.delegate?.collectionView?(grid, didSelectItemAt: IndexPath(item: index, section: 0))
        await BrowserViewSupport.waitUntil { (rig.host.navigation?.viewControllers.count ?? 0) == count }
        let pushed = try #require(rig.host.navigation?.topViewController as? FileBrowserViewController)
        await BrowserViewSupport.waitUntil { !gridNames(of: pushed).isEmpty || name == "Inner" }
        await BrowserViewSupport.settle()
        return pushed
    }

    // MARK: - Pop back

    @Test("Popping back to the root lists what changed in the root while a subfolder was open")
    func popBackShowsAddedItem() async throws {
        let rig = try await makeRig()
        _ = try await pushFolder("Photos", from: rig, expecting: 2)
        _ = try await rig.store.createFolder(named: "Arrived", in: rig.store.root)
        rig.host.navigation?.popViewController(animated: false)
        await BrowserViewSupport.waitUntil { gridNames(of: rig.controller).contains("Arrived") }
        #expect(gridNames(of: rig.controller).contains("Arrived"))
    }

    @Test("Popping back to the root drops an item that was deleted from a subfolder's view of the world")
    func popBackDropsRemovedItem() async throws {
        let rig = try await makeRig()
        _ = try await pushFolder("Photos", from: rig, expecting: 2)
        let beach = try storeItem("Beach.jpg", in: rig.store)
        try await rig.store.moveToTrash(beach)
        rig.host.navigation?.popViewController(animated: false)
        await BrowserViewSupport.waitUntil { !gridNames(of: rig.controller).contains("Beach.jpg") }
        #expect(!gridNames(of: rig.controller).contains("Beach.jpg"))
    }

    @Test("Popping back reloads the folder once more")
    func popBackReloadsOnce() async throws {
        let rig = try await makeRig()
        _ = try await pushFolder("Photos", from: rig, expecting: 2)
        await BrowserViewSupport.settle()
        let before = loadCount(rig.store)
        rig.host.navigation?.popViewController(animated: false)
        await BrowserViewSupport.waitUntil { loadCount(rig.store) > before }
        await BrowserViewSupport.settle()
        // One reload for the root coming back; the popped subfolder does not reload itself.
        #expect(loadCount(rig.store) == before + 1)
    }

    @Test("In root, folder A, folder B: popping from B to A shows a change made in A")
    func popBackTwoLevels() async throws {
        let rig = try await makeRig()
        let photos = try await pushFolder("Photos", from: rig, expecting: 2)
        let photosItem = try storeItem("Photos", in: rig.store)
        let photosDirectory = try #require(photosItem.asDirectory)
        _ = try await rig.store.createFolder(named: "Inner", in: photosDirectory)
        // A reload of A (already on screen) is not guaranteed yet, so wait for B's parent to list it by
        // popping and re-pushing is avoided: push B from the freshly reloaded A.
        rig.host.navigation?.popViewController(animated: false)
        await BrowserViewSupport.waitUntil { gridNames(of: rig.controller).contains("Photos") }
        let again = try await pushFolder("Photos", from: rig, expecting: 2)
        await BrowserViewSupport.waitUntil { gridNames(of: again).contains("Inner") }
        let inner = try await pushFolder("Inner", from: rig, expecting: 3)
        _ = try await rig.store.createFolder(named: "Extra", in: photosDirectory)
        rig.host.navigation?.popViewController(animated: false)
        await BrowserViewSupport.waitUntil { gridNames(of: again).contains("Extra") }
        #expect(gridNames(of: again).contains("Extra"))
        withExtendedLifetime((photos, inner)) {}
    }

    // MARK: - Full-screen screens and sheets over the browser

    @Test("Dismissing a full-screen screen presented over the browser reloads the grid")
    func dismissFullScreenReloads() async throws {
        let rig = try await makeRig()
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        rig.controller.present(cover, animated: false)
        await BrowserViewSupport.waitUntil { rig.host.topmost === cover }
        _ = try await rig.store.createFolder(named: "Arrived", in: rig.store.root)
        cover.dismiss(animated: false)
        await BrowserViewSupport.waitUntil { gridNames(of: rig.controller).contains("Arrived") }
        #expect(gridNames(of: rig.controller).contains("Arrived"))
    }

    @Test("Dismissing a full-screen navigation stack over the browser reloads the grid")
    func dismissFullScreenNavigationReloads() async throws {
        let rig = try await makeRig()
        let cover = UINavigationController(rootViewController: UIViewController())
        cover.modalPresentationStyle = .fullScreen
        rig.controller.present(cover, animated: false)
        await BrowserViewSupport.waitUntil { rig.host.topmost === cover }
        let beach = try storeItem("Beach.jpg", in: rig.store)
        try await rig.store.moveToTrash(beach)
        cover.dismiss(animated: false)
        await BrowserViewSupport.waitUntil { !gridNames(of: rig.controller).contains("Beach.jpg") }
        #expect(!gridNames(of: rig.controller).contains("Beach.jpg"))
    }

    // MARK: - First appearance and quiet reloads

    @Test("The first appearance loads the folder exactly once")
    func firstAppearanceLoadsOnce() async throws {
        let rig = try await makeRig()
        await BrowserViewSupport.settle()
        #expect(loadCount(rig.store) == 1)
    }

    @Test("Reappearing while the vault is locked shows no alert and keeps the grid")
    func reappearWhileLockedIsQuiet() async throws {
        let rig = try await makeRig()
        _ = try await pushFolder("Photos", from: rig, expecting: 2)
        let before = gridNames(of: rig.controller)
        rig.store.errorToThrow = .locked
        let loadsBefore = loadCount(rig.store)
        rig.host.navigation?.popViewController(animated: false)
        await BrowserViewSupport.waitUntil { loadCount(rig.store) > loadsBefore }
        #expect(await rig.host.noAlert())
        #expect(gridNames(of: rig.controller) == before)
    }
}
