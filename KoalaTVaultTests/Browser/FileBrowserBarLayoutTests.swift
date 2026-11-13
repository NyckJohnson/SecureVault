import Testing
import UIKit

@testable import KoalaTVault

/// Bar layout of the root's leading items (revised 2026-11-13): the gear keeps its own button; the "< lock"
/// Lock button stands apart from it, with no shared button background.
@MainActor
extension FileBrowserViewControllerTests {
    @Test("The Lock button hides the shared button background, standing apart from the gear", arguments: [false, true])
    func lockButtonHidesSharedBackground(encrypted: Bool) async throws {
        guard #available(iOS 26, *) else { return }
        let rig = try await makeRig(encryptedStore: encrypted)
        let items = try #require(rig.controller.navigationItem.leftBarButtonItems)
        let lock = try #require(items.first { $0.accessibilityIdentifier == "lockButton" })
        #expect(lock.hidesSharedBackground)
    }

    @Test("The gear keeps its own button background on the root")
    func gearKeepsItsBackground() async throws {
        guard #available(iOS 26, *) else { return }
        let rig = try await makeRig()
        let items = try #require(rig.controller.navigationItem.leftBarButtonItems)
        let gear = try #require(items.first { $0.accessibilityIdentifier == "settingsButton" })
        #expect(!gear.hidesSharedBackground)
    }

    @Test("The Lock item is not part of a group with the gear's item", arguments: [false, true])
    func lockItemNotGroupedWithGear(encrypted: Bool) async throws {
        guard #available(iOS 26, *) else { return }
        let rig = try await makeRig(encryptedStore: encrypted)
        let groups = rig.controller.navigationItem.leadingItemGroups
        let sharing = groups.filter { group in
            let ids = group.barButtonItems.map { $0.accessibilityIdentifier ?? "" }
            let lockShowsBackground = group.barButtonItems.contains {
                $0.accessibilityIdentifier == "lockButton" && !$0.hidesSharedBackground
            }
            return ids.contains("settingsButton") && lockShowsBackground
        }
        #expect(sharing.isEmpty)
    }

    @Test("The Lock button still calls onLock when tapped after the layout change")
    func lockButtonStillTappable() async throws {
        let rig = try await makeRig()
        rig.host.tap("lockButton")
        #expect(rig.lockCount.count == 1)
    }

}
