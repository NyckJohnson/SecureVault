//
//  SecuritySettingsProTests.swift
//  KoalaTVault
//

import XCTest
@testable import KoalaTVault

@MainActor
final class SecuritySettingsProTests: XCTestCase {

    private var window: UIWindow?

    /// Hosts the SUT in a real window so UIKit's presentation machinery
    /// populates `presentedViewController`.
    private func makeHostedSUT() throws -> LegacySecuritySettingsViewController {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.first as? UIWindowScene
        )
        let sut = LegacySecuritySettingsViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = sut
        window.makeKeyAndVisible()
        self.window = window
        return sut
    }

    override func tearDown() async throws {
        window?.rootViewController?.dismiss(animated: false)
        window?.isHidden = true
        window = nil
        AuthService.shared.lockMode = .none
        EntitlementService.testForcedUnlocked = nil
        try await super.tearDown()
    }

    // MARK: - Cell content
    func testProCellShowsUpgradeWhenLocked() {
        EntitlementService.testForcedUnlocked = false
        let sut = LegacySecuritySettingsViewController()
        sut.loadViewIfNeeded()

        let cell = sut.tableView(sut.testTableView, cellForRowAt: IndexPath(row: 0, section: 0))

        XCTAssertEqual(cell.textLabel?.text, "Upgrade to Pro")
        XCTAssertEqual(cell.accessoryType, .disclosureIndicator)
    }

    func testProCellShowsUnlockedStateWhenUnlocked() {
        EntitlementService.testForcedUnlocked = true
        let sut = LegacySecuritySettingsViewController()
        sut.loadViewIfNeeded()

        let cell = sut.tableView(sut.testTableView, cellForRowAt: IndexPath(row: 0, section: 0))

        XCTAssertEqual(cell.textLabel?.text, "Pro Unlocked")
        XCTAssertEqual(cell.accessoryType, .checkmark)
    }

    // MARK: - Tap behavior
    func testTappingUpgradeRowPresentsPaywallWhenLocked() throws {
        EntitlementService.testForcedUnlocked = false
        let sut = try makeHostedSUT()

        sut.tableView(sut.testTableView, didSelectRowAt: IndexPath(row: 0, section: 0))

        XCTAssertTrue(sut.presentedViewController is LegacyPaywallViewController)
    }

    func testTappingUpgradeRowDoesNothingWhenAlreadyUnlocked() throws {
        EntitlementService.testForcedUnlocked = true
        let sut = try makeHostedSUT()

        sut.tableView(sut.testTableView, didSelectRowAt: IndexPath(row: 0, section: 0))

        XCTAssertNil(sut.presentedViewController)
    }
}
