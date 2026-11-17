import Testing
import UIKit

@testable import KoalaTVault

/// The browser's title row (feature multiple-vaults-duress-password, device retest 2026-11-13): no bar title, a
/// pinned row under the bar with a back arrow left of the folder's name; "<" pops in a subfolder, "< lock" on a
/// vault's root locks. Replaces the earlier bar-button layout tests.
@MainActor
extension FileBrowserViewControllerTests {
    private func vaultName(_ encrypted: Bool) -> String { encrypted ? "Work" : "KoalaTVault" }

    private func pushPhotos(_ rig: Rig) async throws -> FileBrowserViewController {
        rig.tapCell("Photos")
        await BrowserViewSupport.waitUntil { (rig.host.navigation?.viewControllers.count ?? 0) == 2 }
        let pushed = try #require(rig.host.navigation?.viewControllers.last as? FileBrowserViewController)
        await BrowserViewSupport.waitUntil { TitleRow.shows("Photos", in: pushed) }
        return pushed
    }

    // MARK: - No bar title

    @Test("The root shows no navigation-bar title or large title", arguments: [false, true])
    func rootHasNoBarTitle(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        let item = rig.controller.navigationItem
        #expect(item.largeTitleDisplayMode == .never)
        #expect((item.title ?? "").isEmpty)
        #expect((rig.controller.title ?? "").isEmpty)
        #expect(item.titleView == nil)
    }

    @Test("A pushed folder shows no bar title and no system back button")
    func subfolderHasNoBarTitleOrBackButton() async throws {
        let rig = try await makeRig()
        let pushed = try await pushPhotos(rig)
        let item = pushed.navigationItem
        #expect(item.largeTitleDisplayMode == .never)
        #expect((item.title ?? "").isEmpty)
        #expect((pushed.title ?? "").isEmpty)
        #expect(item.titleView == nil)
        #expect(item.hidesBackButton)
        #expect(item.leftBarButtonItems?.isEmpty ?? true)
        #expect(!item.leftItemsSupplementBackButton)
    }

    // MARK: - The row shows the name, pinned above the grid

    @Test("The title row shows the vault's name on the root", arguments: [false, true])
    func rootTitleRowShowsVaultName(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        #expect(TitleRow.shows(vaultName(encrypted), in: rig.controller))
    }

    @Test("The title row shows the folder's name in a subfolder")
    func subfolderTitleRowShowsFolderName() async throws {
        let rig = try await makeRig(folder: "Photos")
        #expect(TitleRow.shows("Photos", in: rig.controller))
    }

    @Test("The name sits above the grid, outside the scrolling collection view", arguments: [false, true])
    func nameIsPinnedAboveGrid(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        let name = try #require(TitleRow.label(vaultName(encrypted), in: rig.controller))
        let grid = try #require(rig.grid)
        #expect(!name.isDescendant(of: grid))
        let nameFrame = TitleRow.frame(of: name, in: rig.controller)
        let gridFrame = TitleRow.frame(of: grid, in: rig.controller)
        #expect(nameFrame.maxY <= gridFrame.minY + 1)
    }

    @Test("The name stays put while the grid scrolls")
    func nameDoesNotScroll() async throws {
        let rig = try await makeRig()
        let name = try #require(TitleRow.label("KoalaTVault", in: rig.controller))
        let before = TitleRow.frame(of: name, in: rig.controller)
        rig.grid?.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
        rig.controller.view.layoutIfNeeded()
        #expect(TitleRow.frame(of: name, in: rig.controller) == before)
    }

    @Test("The name is one line, left-aligned, and truncates in the middle")
    func nameLabelStyle() async throws {
        let rig = try await makeRig()
        let name = try #require(TitleRow.label("KoalaTVault", in: rig.controller))
        #expect(name.numberOfLines == 1)
        #expect(name.lineBreakMode == .byTruncatingMiddle)
        #expect(name.textAlignment == .natural || name.textAlignment == .left)
    }

    // MARK: - Arrow beside the name

    @Test("The arrow is just left of the name on the same line", arguments: [false, true])
    func rootArrowLeftOfName(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        let name = try #require(TitleRow.label(vaultName(encrypted), in: rig.controller))
        let arrow = try #require(TitleRow.visibleArrow("lockButton", in: rig.controller))
        let nameFrame = TitleRow.frame(of: name, in: rig.controller)
        let arrowFrame = TitleRow.frame(of: arrow, in: rig.controller)
        #expect(arrowFrame.maxX <= nameFrame.minX + 0.5)
        #expect(arrowFrame.minY <= nameFrame.midY && nameFrame.midY <= arrowFrame.maxY)
    }

    @Test("In a subfolder the arrow is left of the name on the same line")
    func subfolderArrowLeftOfName() async throws {
        let rig = try await makeRig(folder: "Photos")
        let name = try #require(TitleRow.label("Photos", in: rig.controller))
        let arrow = try #require(TitleRow.visibleArrow("browser.backButton", in: rig.controller))
        let nameFrame = TitleRow.frame(of: name, in: rig.controller)
        let arrowFrame = TitleRow.frame(of: arrow, in: rig.controller)
        #expect(arrowFrame.maxX <= nameFrame.minX + 0.5)
        #expect(arrowFrame.minY <= nameFrame.midY && nameFrame.midY <= arrowFrame.maxY)
    }

    @Test("The arrow is at least 44 pt tall on the root and in a subfolder", arguments: [false, true])
    func arrowIsTallEnough(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        let lock = try #require(TitleRow.visibleArrow("lockButton", in: rig.controller))
        #expect(TitleRow.frame(of: lock, in: rig.controller).height >= 44 - 0.01)
        let sub = try await makeRig(folder: "Photos", encryptedStore: encrypted)
        let back = try #require(TitleRow.visibleArrow("browser.backButton", in: sub.controller))
        #expect(TitleRow.frame(of: back, in: sub.controller).height >= 44 - 0.01)
    }

    @Test("In a right-to-left layout the arrow moves to the right of the name, pointing the reading direction")
    func arrowFollowsReadingDirection() async throws {
        let rig = try await makeRig()
        rig.controller.view.semanticContentAttribute = .forceRightToLeft
        rig.controller.view.setNeedsLayout()
        rig.controller.view.layoutIfNeeded()
        await BrowserViewSupport.settle()
        let name = try #require(TitleRow.label("KoalaTVault", in: rig.controller))
        let arrow = try #require(TitleRow.visibleArrow("lockButton", in: rig.controller))
        let nameFrame = TitleRow.frame(of: name, in: rig.controller)
        let arrowFrame = TitleRow.frame(of: arrow, in: rig.controller)
        #expect(arrowFrame.minX >= nameFrame.maxX - 0.5)
    }

    // MARK: - Subfolder arrow

    @Test("In a subfolder the arrow is the Back button, and there is no Lock button anywhere")
    func subfolderArrowIsBack() async throws {
        let rig = try await makeRig(folder: "Photos")
        let arrow = try #require(TitleRow.visibleArrow("browser.backButton", in: rig.controller))
        #expect(arrow.accessibilityLabel == "Back")
        #expect(TitleRow.arrow("lockButton", in: rig.controller) == nil)
        #expect(!TitleRow.barIdentifiers(of: rig.controller).contains("lockButton"))
        #expect(!TitleRow.barIdentifiers(of: rig.controller).contains("browser.backButton"))
    }

    @Test("Tapping a pushed folder's arrow goes back to the parent folder", arguments: [false, true])
    func subfolderArrowPops(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        let pushed = try await pushPhotos(rig)
        #expect(TitleRow.arrow("lockButton", in: pushed) == nil)
        let arrow = try #require(TitleRow.visibleArrow("browser.backButton", in: pushed) as? UIControl)
        arrow.sendActions(for: .touchUpInside)
        await BrowserViewSupport.waitUntil { rig.host.navigation?.viewControllers.count == 1 }
        #expect(rig.host.navigation?.viewControllers.count == 1)
        #expect(rig.host.navigation?.topViewController === rig.controller)
        #expect(rig.lockCount.count < 1)
    }

    @Test("The edge-swipe back gesture stays enabled in a pushed folder")
    func edgeSwipeBackStaysEnabled() async throws {
        let rig = try await makeRig()
        _ = try await pushPhotos(rig)
        await BrowserViewSupport.settle()
        let gesture = try #require(rig.host.navigation?.interactivePopGestureRecognizer)
        #expect(gesture.isEnabled)
        let delegate = gesture.delegate
        let allowed = delegate?.gestureRecognizerShouldBegin?(gesture) ?? true
        #expect(allowed)
    }

    /// Taps a bar item of this very controller (the host's lookup finds the first controller in the stack).
    private func tapBarItem(_ id: String, in controller: UIViewController) {
        let item = controller.navigationItem
        let items = (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
        guard let button = items.first(where: { $0.accessibilityIdentifier == id }) else { return }
        if let action = button.primaryAction {
            action.performWithSender(button, target: nil)
        } else if let selector = button.action {
            UIApplication.shared.sendAction(selector, to: button.target, from: button, for: nil)
        }
    }

    private func popGestureAllows(_ rig: Rig) throws -> Bool {
        let gesture = try #require(rig.host.navigation?.interactivePopGestureRecognizer)
        return gesture.delegate?.gestureRecognizerShouldBegin?(gesture) ?? true
    }

    @Test("The edge-swipe back gesture does not begin on the root")
    func edgeSwipeBlockedOnRoot() async throws {
        let rig = try await makeRig()
        await BrowserViewSupport.settle()
        #expect(rig.host.navigation?.viewControllers.count == 1)
        #expect(try !popGestureAllows(rig))
    }

    @Test("The edge-swipe back gesture does not begin while a push is still animating")
    func edgeSwipeBlockedMidPush() async throws {
        let rig = try await makeRig()
        rig.tapCell("Photos")
        #expect(rig.host.navigation?.viewControllers.count == 2)
        #expect(rig.host.navigation?.transitionCoordinator != nil)
        #expect(try !popGestureAllows(rig))
        await BrowserViewSupport.waitUntil { rig.host.navigation?.transitionCoordinator == nil }
        await BrowserViewSupport.settle()
        #expect(try popGestureAllows(rig))
    }

    @Test("The edge-swipe back gesture does not begin in select mode in a subfolder")
    func edgeSwipeBlockedInSelectMode() async throws {
        let rig = try await makeRig()
        let pushed = try await pushPhotos(rig)
        await BrowserViewSupport.waitUntil { rig.host.navigation?.transitionCoordinator == nil }
        await BrowserViewSupport.settle()
        #expect(try popGestureAllows(rig))
        tapBarItem("selectButton", in: pushed)
        await BrowserViewSupport.waitUntil { TitleRow.shows("Select Items", in: pushed) }
        #expect(TitleRow.shows("Select Items", in: pushed))
        #expect(try !popGestureAllows(rig))
        tapBarItem("browser.cancelSelectButton", in: pushed)
        await BrowserViewSupport.waitUntil { TitleRow.shows("Photos", in: pushed) }
        #expect(try popGestureAllows(rig))
    }

    @Test("The select title starts at the same left edge as the folder name", arguments: [false, true])
    func selectTitleKeepsLeftEdge(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        let name = try #require(TitleRow.label(vaultName(encrypted), in: rig.controller))
        let before = TitleRow.frame(of: name, in: rig.controller).minX
        rig.host.tap("selectButton")
        await BrowserViewSupport.waitUntil { TitleRow.shows("Select Items", in: rig.controller) }
        let select = try #require(TitleRow.label("Select Items", in: rig.controller))
        #expect(abs(TitleRow.frame(of: select, in: rig.controller).minX - before) <= 0.5)
    }

    @Test("In a subfolder the select title starts at the same left edge as the folder name")
    func selectTitleKeepsLeftEdgeInSubfolder() async throws {
        let rig = try await makeRig()
        let pushed = try await pushPhotos(rig)
        let name = try #require(TitleRow.label("Photos", in: pushed))
        let before = TitleRow.frame(of: name, in: pushed).minX
        tapBarItem("selectButton", in: pushed)
        await BrowserViewSupport.waitUntil { TitleRow.shows("Select Items", in: pushed) }
        let select = try #require(TitleRow.label("Select Items", in: pushed))
        #expect(abs(TitleRow.frame(of: select, in: pushed).minX - before) <= 0.5)
    }

    // MARK: - Root arrow

    @Test("On a vault's root the arrow is the Lock button, labelled Lock", arguments: [false, true])
    func rootArrowIsLock(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        let arrow = try #require(TitleRow.visibleArrow("lockButton", in: rig.controller))
        #expect(arrow.accessibilityLabel == "Lock")
        #expect(TitleRow.arrow("browser.backButton", in: rig.controller) == nil)
    }

    @Test("Tapping the root's arrow calls onLock once", arguments: [false, true])
    func rootArrowCallsOnLock(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        let arrow = try #require(TitleRow.visibleArrow("lockButton", in: rig.controller) as? UIControl)
        arrow.sendActions(for: .touchUpInside)
        #expect(rig.lockCount.count == 1)
        #expect(rig.host.navigation?.viewControllers.count == 1)
    }

    @Test("The Lock button is not a navigation bar item", arguments: [false, true])
    func lockIsNotABarItem(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        #expect(!TitleRow.barIdentifiers(of: rig.controller).contains("lockButton"))
        #expect(!TitleRow.barIdentifiers(of: rig.controller).contains("browser.backButton"))
    }

    @Test("The root's bar has only the settings gear on the left", arguments: [false, true])
    func rootLeftItemsAreOnlyGear(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        let ids = (rig.controller.navigationItem.leftBarButtonItems ?? []).map { $0.accessibilityIdentifier }
        #expect(ids == ["settingsButton"])
    }

    @Test("The root's right side holds Select and the actions menu button")
    func rightItemsUnchanged() async throws {
        let rig = try await makeRig()
        let ids = TitleRow.barIdentifiers(of: rig.controller)
        for id in ["selectButton", "browser.actionsMenuButton"] {
            #expect(ids.contains(id), "missing \(id)")
        }
        for id in ["sortButton", "newFolderButton", "browser.newDocumentButton", "importButton"] {
            #expect(!ids.contains(id), "\(id) should be a menu entry now")
        }
    }

    // MARK: - Select mode

    @Test("Select mode puts Select Items in the title row, hides the arrow and keeps Cancel in the bar")
    func selectModeTitleRow() async throws {
        let rig = try await makeRig()
        rig.host.tap("selectButton")
        await BrowserViewSupport.waitUntil { TitleRow.shows("Select Items", in: rig.controller) }
        #expect(TitleRow.shows("Select Items", in: rig.controller))
        #expect(!TitleRow.shows("KoalaTVault", in: rig.controller))
        #expect(TitleRow.visibleArrow("lockButton", in: rig.controller) == nil)
        #expect(TitleRow.barIdentifiers(of: rig.controller).contains("browser.cancelSelectButton"))
        #expect((rig.controller.navigationItem.title ?? "").isEmpty)
    }

    @Test("Select mode counts the selection in the title row")
    func selectModeCount() async throws {
        let rig = try await makeRig()
        rig.host.tap("selectButton")
        rig.tapCell("Beach.jpg")
        rig.tapCell("Notes.rtf")
        await BrowserViewSupport.waitUntil { TitleRow.shows("2 Selected", in: rig.controller) }
        #expect(TitleRow.shows("2 Selected", in: rig.controller))
        #expect(!TitleRow.shows("Select Items", in: rig.controller))
    }

    @Test("In a subfolder, select mode hides the back arrow")
    func selectModeHidesBackArrow() async throws {
        let rig = try await makeRig(folder: "Photos")
        rig.host.tap("selectButton")
        await BrowserViewSupport.waitUntil { TitleRow.shows("Select Items", in: rig.controller) }
        #expect(TitleRow.visibleArrow("browser.backButton", in: rig.controller) == nil)
    }

    @Test("Leaving select mode restores the arrow and the name", arguments: [false, true])
    func leavingSelectModeRestores(encrypted: Bool) async throws {
        let rig = try await makeRig(encryptedStore: encrypted)
        rig.host.tap("selectButton")
        rig.tapCell("Beach.jpg")
        await BrowserViewSupport.waitUntil { TitleRow.shows("1 Selected", in: rig.controller) }
        rig.host.tap("browser.cancelSelectButton")
        await BrowserViewSupport.waitUntil { TitleRow.shows(vaultName(encrypted), in: rig.controller) }
        #expect(TitleRow.shows(vaultName(encrypted), in: rig.controller))
        #expect(!TitleRow.shows("1 Selected", in: rig.controller))
        #expect(!TitleRow.shows("Select Items", in: rig.controller))
        #expect(TitleRow.visibleArrow("lockButton", in: rig.controller) != nil)
    }
}
