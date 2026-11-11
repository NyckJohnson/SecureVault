import Testing
import UIKit

@testable import KoalaTVault

@MainActor
@Suite struct AppLockCoordinatorTests {
    private struct Harness {
        let coordinator: AppLockCoordinator
        let lock: MockVaultLocking
        let screens: MockVaultsScreenFactory
        let presenter: RecordingLockPresenter
        let window: UIWindow
        let needsProRequests: NeedsProRecorder
    }

    @MainActor
    private final class NeedsProRecorder {
        var controllers: [UIViewController] = []
    }

    private func makeHarness(encryptedOpen: Bool = false) async throws -> Harness {
        let lock = MockVaultLocking()
        if encryptedOpen { try await lock.open(password: "correct horse") }
        let screens = MockVaultsScreenFactory()
        let presenter = RecordingLockPresenter()
        let recorder = NeedsProRecorder()
        let coordinator = AppLockCoordinator(
            lock: lock, screens: screens, presenter: presenter,
            onNeedsPro: { recorder.controllers.append($0) })
        return Harness(
            coordinator: coordinator, lock: lock, screens: screens, presenter: presenter,
            window: UIWindow(), needsProRequests: recorder)
    }

    // MARK: Connect

    @Test("Connecting presents the lock screen once, in the window")
    func connectPresentsLockScreen() async throws {
        let harness = try await makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window)
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
        #expect(harness.screens.makeLockScreenCount == 1)
        #expect(harness.presenter.windows.first === harness.window)
        #expect(harness.presenter.presentedScreens.first === harness.screens.lastScreen)
    }

    @Test("Connecting shows the lock screen even when the unencrypted vault is open")
    func connectShowsLockScreenForUnencryptedVault() async throws {
        let harness = try await makeHarness(encryptedOpen: false)
        harness.coordinator.sceneDidConnect(window: harness.window)
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
    }

    @Test("Connecting does not show the privacy cover")
    func connectDoesNotShowCover() async throws {
        let harness = try await makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window)
        #expect(harness.presenter.count(of: .showPrivacyCover) == 0)
    }

    // MARK: Resign active

    @Test("Resigning active with an encrypted vault open shows the privacy cover")
    func resignActiveEncryptedShowsCover() async throws {
        let harness = try await makeHarness(encryptedOpen: true)
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.coordinator.sceneWillResignActive()
        #expect(harness.lock.calls.contains(.appWillResignActive))
        #expect(harness.presenter.count(of: .showPrivacyCover) == 1)
    }

    @Test("Resigning active with the unencrypted vault open shows no cover")
    func resignActiveUnencryptedShowsNoCover() async throws {
        let harness = try await makeHarness(encryptedOpen: false)
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.coordinator.sceneWillResignActive()
        #expect(harness.lock.calls.contains(.appWillResignActive))
        #expect(harness.presenter.count(of: .showPrivacyCover) == 0)
    }

    // MARK: Background

    @Test("Going to the background tells the lock and presents the lock screen")
    func backgroundPresentsLockScreen() async throws {
        let harness = try await makeHarness(encryptedOpen: true)
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.screens.simulateDone()
        let before = harness.presenter.count(of: .presentLockScreen)
        harness.coordinator.sceneDidEnterBackground()
        #expect(harness.lock.calls.contains(.appDidEnterBackground))
        #expect(harness.presenter.count(of: .presentLockScreen) == before + 1)
    }

    @Test("Going to the background with the unencrypted vault open still presents the lock screen")
    func backgroundUnencryptedPresentsLockScreen() async throws {
        let harness = try await makeHarness(encryptedOpen: false)
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.screens.simulateDone()
        harness.coordinator.sceneDidEnterBackground()
        #expect(harness.lock.calls.contains(.appDidEnterBackground))
        #expect(harness.presenter.count(of: .presentLockScreen) == 2)
    }

    @Test("Going to the background with the lock screen already up tells the lock but presents no second screen")
    func backgroundWithLockScreenUpPresentsNoSecond() async throws {
        let harness = try await makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.coordinator.sceneDidEnterBackground()
        #expect(harness.lock.calls.contains(.appDidEnterBackground))
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
        #expect(harness.screens.makeLockScreenCount == 1)
    }

    // MARK: Become active

    @Test("Becoming active hides the cover and leaves the lock screen up")
    func becomeActiveHidesCoverKeepsLockScreen() async throws {
        let harness = try await makeHarness(encryptedOpen: true)
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.coordinator.sceneWillResignActive()
        harness.coordinator.sceneDidBecomeActive()
        #expect(harness.presenter.count(of: .hidePrivacyCover) == 1)
        #expect(harness.presenter.count(of: .dismissLockScreen) == 0)
    }

    // MARK: Lock

    @Test("Lock closes the vault and presents the lock screen")
    func lockClosesAndPresents() async throws {
        let harness = try await makeHarness(encryptedOpen: true)
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.screens.simulateDone()
        let before = harness.presenter.count(of: .presentLockScreen)
        harness.coordinator.lock()
        #expect(harness.lock.calls.contains(.close))
        #expect(harness.lock.current.isEncrypted == false)
        #expect(harness.presenter.count(of: .presentLockScreen) == before + 1)
    }

    @Test("Lock twice presents only one lock screen")
    func lockTwicePresentsOnce() async throws {
        let harness = try await makeHarness(encryptedOpen: true)
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.screens.simulateDone()
        let before = harness.presenter.count(of: .presentLockScreen)
        harness.coordinator.lock()
        harness.coordinator.lock()
        #expect(harness.presenter.count(of: .presentLockScreen) == before + 1)
    }

    @Test("Lock with the lock screen already up from connect presents no second screen")
    func lockAfterConnectPresentsNoSecond() async throws {
        let harness = try await makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.coordinator.lock()
        #expect(harness.lock.calls.contains(.close))
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
    }

    // MARK: Done

    @Test("The lock screen's onDone dismisses it")
    func doneDismissesLockScreen() async throws {
        let harness = try await makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window)
        let screen = harness.screens.lastScreen
        harness.screens.simulateDone()
        #expect(harness.presenter.count(of: .dismissLockScreen) == 1)
        #expect(harness.presenter.dismissedScreens.first === screen)
    }

    @Test("After the lock screen is done, a later background presents a new one")
    func backgroundAfterDonePresentsNew() async throws {
        let harness = try await makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.screens.simulateDone()
        harness.coordinator.sceneDidEnterBackground()
        #expect(harness.presenter.count(of: .presentLockScreen) == 2)
        #expect(harness.screens.makeLockScreenCount == 2)
    }

    // MARK: At most one

    @Test("Connect then background presents one lock screen")
    func connectThenBackgroundPresentsOne() async throws {
        let harness = try await makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.coordinator.sceneDidEnterBackground()
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
    }

    @Test("Background then lock presents one lock screen")
    func backgroundThenLockPresentsOne() async throws {
        let harness = try await makeHarness(encryptedOpen: true)
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.screens.simulateDone()
        let before = harness.presenter.count(of: .presentLockScreen)
        harness.coordinator.sceneDidEnterBackground()
        harness.coordinator.lock()
        #expect(harness.presenter.count(of: .presentLockScreen) == before + 1)
    }

    // MARK: Paywall

    @Test("The lock screen's onNeedsPro is passed to the shell with the screen")
    func needsProPassedToShell() async throws {
        let harness = try await makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window)
        harness.screens.simulateNeedsPro()
        #expect(harness.needsProRequests.controllers.count == 1)
        #expect(harness.needsProRequests.controllers.first === harness.screens.lastScreen)
    }
}
