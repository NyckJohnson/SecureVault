import Testing
import UIKit

@testable import KoalaTVault

@MainActor
@Suite struct AppLockCoordinatorTests {
    private struct Harness {
        let coordinator: AppLockCoordinator
        let lock: MockVaultLocking
        let preferences: MockPreferencesStoring
        let masterKeys: MockMasterKeyStoring
        let presenter: RecordingLockPresenter
        let window: UIWindow
    }

    private func makeHarness(
        lockMode: LockMode = .password,
        pending: PendingMigration? = nil,
        preferencesLockMode: LockMode? = nil,
        hasBlob: Bool = true,
        biometricsAvailable: Bool = true
    ) -> Harness {
        let lock = MockVaultLocking(lockMode: lockMode, biometricsAvailable: biometricsAvailable)
        let preferences = MockPreferencesStoring(
            lockMode: preferencesLockMode ?? lockMode, pendingMigration: pending)
        let masterKeys = MockMasterKeyStoring(password: hasBlob ? "correct horse" : nil)
        let presenter = RecordingLockPresenter()
        let coordinator = AppLockCoordinator(
            lock: lock, preferences: preferences, masterKeys: masterKeys, presenter: presenter)
        return Harness(
            coordinator: coordinator, lock: lock, preferences: preferences,
            masterKeys: masterKeys, presenter: presenter, window: UIWindow())
    }

    /// A pending encrypt, no password blob, and a stale saved lock mode.
    private func makeUnfinishableHarness() -> Harness {
        makeHarness(lockMode: .none, pending: pendingEncrypt(), preferencesLockMode: .password, hasBlob: false)
    }

    private func pendingEncrypt() -> PendingMigration {
        PendingMigration(kind: .encrypt, targetLockMode: .password)
    }

    // MARK: Connect

    @Test("Connecting when setup is needed presents the wizard and no lock screen")
    func connectNeedingSetupPresentsWizard() {
        let harness = makeHarness(lockMode: .none)
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: true)
        #expect(harness.presenter.count(of: .presentSetupWizard) == 1)
        #expect(harness.presenter.count(of: .presentLockScreen) == 0)
    }

    @Test("Connecting with a lock presents the lock screen once and no wizard")
    func connectWithLockPresentsLockScreen() {
        let harness = makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
        #expect(harness.presenter.count(of: .presentSetupWizard) == 0)
    }

    @Test("Connecting again with a new window while locked presents a fresh lock screen")
    func reconnectWhileLockedPresentsLockScreenAgain() {
        let harness = makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        harness.coordinator.sceneDidConnect(window: UIWindow(), needsSetup: false)
        #expect(harness.presenter.count(of: .presentLockScreen) == 2)
    }

    @Test("Connecting with no lock and setup done presents nothing")
    func connectWithoutLockPresentsNothing() {
        let harness = makeHarness(lockMode: .none)
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        #expect(harness.presenter.requests.isEmpty)
    }

    @Test("Finishing the wizard dismisses the wizard only")
    func finishingWizardDismissesWizard() async {
        let harness = makeHarness(lockMode: .none)
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: true)
        guard let wizard = harness.presenter.setupViewModels.first else {
            Issue.record("The wizard was not presented")
            return
        }
        await wizard.continueTapped()
        #expect(harness.presenter.count(of: .dismissSetupWizard) == 1)
        #expect(harness.presenter.count(of: .dismissLockScreen) == 0)
    }

    // MARK: Privacy cover and scene events

    @Test("Resigning active while unlocked with a lock shows the privacy cover")
    func resignActiveWhileUnlockedShowsCover() async throws {
        let harness = makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        try await harness.lock.unlock(password: "correct horse")
        harness.coordinator.sceneWillResignActive()
        #expect(harness.presenter.count(of: .showPrivacyCover) == 1)
        #expect(harness.lock.calls.contains(.appWillResignActive))
    }

    @Test("Resigning active with no lock shows no privacy cover")
    func resignActiveWithoutLockShowsNoCover() {
        let harness = makeHarness(lockMode: .none)
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        harness.coordinator.sceneWillResignActive()
        #expect(harness.presenter.count(of: .showPrivacyCover) == 0)
    }

    @Test("Resigning active while locked shows no privacy cover")
    func resignActiveWhileLockedShowsNoCover() {
        let harness = makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        harness.coordinator.sceneWillResignActive()
        #expect(harness.presenter.count(of: .showPrivacyCover) == 0)
    }

    @Test("Entering the background tells the lock appDidEnterBackground")
    func backgroundTellsLock() {
        let harness = makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        harness.coordinator.sceneDidEnterBackground()
        #expect(harness.lock.calls.contains(.appDidEnterBackground))
    }

    @Test("Becoming active tells the lock appWillEnterForeground before presenting the lock screen")
    func activeTellsLockThenPresents() async throws {
        let harness = makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        try await harness.lock.unlock(password: "correct horse")
        harness.coordinator.sceneDidEnterBackground()
        harness.coordinator.sceneDidBecomeActive()
        #expect(harness.lock.calls.last == .appWillEnterForeground)
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
    }

    @Test("The lock screen is presented after the lock was told it is returning")
    func lockToldBeforeLockScreenPresented() async {
        let harness = makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        await unlockThroughLockScreen(harness)
        harness.coordinator.sceneDidEnterBackground()
        var lastCallAtPresentation: MockVaultLocking.Call?
        harness.presenter.onPresentLockScreen = { lastCallAtPresentation = harness.lock.calls.last }
        harness.coordinator.sceneDidBecomeActive()
        #expect(lastCallAtPresentation == .appWillEnterForeground)
    }

    @Test("Becoming active while locked presents the lock screen only once")
    func lockScreenPresentedOnce() {
        let harness = makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        harness.coordinator.sceneDidBecomeActive()
        harness.coordinator.sceneDidBecomeActive()
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
    }

    @Test("Becoming active while locked, after the cover was shown, hides the cover and presents the lock screen")
    func activeWhileLockedAfterCoverHidesCoverAndPresentsLockScreen() async {
        let harness = makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        await unlockThroughLockScreen(harness)
        harness.coordinator.sceneWillResignActive()
        #expect(harness.presenter.count(of: .showPrivacyCover) == 1)
        harness.coordinator.sceneDidEnterBackground()
        #expect(harness.lock.state == .locked)
        let presentationsBefore = harness.presenter.count(of: .presentLockScreen)
        let hidesBefore = harness.presenter.count(of: .hidePrivacyCover)
        harness.coordinator.sceneDidBecomeActive()
        #expect(harness.presenter.count(of: .hidePrivacyCover) == hidesBefore + 1)
        #expect(harness.presenter.count(of: .presentLockScreen) == presentationsBefore + 1)
    }

    @Test("Becoming active with no lock hides the cover and presents nothing")
    func activeWithoutLockHidesCover() {
        let harness = makeHarness(lockMode: .none)
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        harness.coordinator.sceneDidBecomeActive()
        #expect(harness.lock.calls.contains(.appWillEnterForeground))
        #expect(harness.presenter.count(of: .presentLockScreen) == 0)
        #expect(harness.presenter.count(of: .hidePrivacyCover) == 1)
    }

    @Test("The lock screen is presented again after an unlock and a new background")
    func lockScreenPresentedAgainAfterBackground() async {
        let harness = makeHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        await unlockThroughLockScreen(harness)
        harness.coordinator.sceneDidEnterBackground()
        harness.coordinator.sceneDidBecomeActive()
        #expect(harness.presenter.count(of: .presentLockScreen) == 2)
    }

    // MARK: After unlock

    private func unlockThroughLockScreen(_ harness: Harness) async {
        guard let lockScreen = harness.presenter.lockViewModels.last else {
            Issue.record("The lock screen was not presented")
            return
        }
        lockScreen.passwordEdited("correct horse")
        await lockScreen.unlockTapped()
    }

    @Test("After unlock only the lock screen is dismissed, the cover is hidden and onUnlocked runs")
    func afterUnlockDismissesLockScreenOnly() async {
        let harness = makeHarness()
        var unlockedCount = 0
        harness.coordinator.onUnlocked = { unlockedCount += 1 }
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        await unlockThroughLockScreen(harness)
        #expect(harness.presenter.count(of: .dismissLockScreen) == 1)
        #expect(harness.presenter.count(of: .dismissSetupWizard) == 0)
        #expect(harness.presenter.count(of: .hidePrivacyCover) >= 1)
        #expect(unlockedCount == 1)
    }

    @Test("After unlock, the cover and onUnlocked wait until the lock screen dismissal completes")
    func afterUnlockWaitsForDismissalCompletion() async {
        let harness = makeHarness()
        harness.presenter.holdsDismissalCompletion = true
        var unlockedCount = 0
        harness.coordinator.onUnlocked = { unlockedCount += 1 }
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        await unlockThroughLockScreen(harness)
        #expect(harness.presenter.count(of: .dismissLockScreen) == 1)
        #expect(harness.presenter.hasPendingDismissal)
        #expect(harness.presenter.count(of: .hidePrivacyCover) == 0)
        #expect(unlockedCount == 0)
        harness.presenter.completeDismissal()
        #expect(harness.presenter.count(of: .hidePrivacyCover) >= 1)
        #expect(unlockedCount == 1)
        let dismissIndex = harness.presenter.requests.firstIndex(of: .dismissLockScreen)
        let hideIndex = harness.presenter.requests.firstIndex(of: .hidePrivacyCover)
        if let dismissIndex, let hideIndex {
            #expect(dismissIndex < hideIndex)
        } else {
            Issue.record("Expected both a dismissal and a cover hide")
        }
    }

    @Test("onUnlocked does not run before the user unlocks")
    func onUnlockedNotRunBeforeUnlock() {
        let harness = makeHarness()
        var unlockedCount = 0
        harness.coordinator.onUnlocked = { unlockedCount += 1 }
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        harness.coordinator.sceneDidBecomeActive()
        #expect(unlockedCount == 0)
    }

    @Test("A biometric lock screen tries Face ID only once the scene becomes active")
    func biometricAttemptWaitsForActive() async {
        let lock = MockVaultLocking(lockMode: .passwordAndBiometrics)
        let preferences = MockPreferencesStoring(lockMode: .passwordAndBiometrics)
        let presenter = RecordingLockPresenter()
        let coordinator = AppLockCoordinator(
            lock: lock, preferences: preferences, masterKeys: MockMasterKeyStoring(), presenter: presenter)
        coordinator.sceneDidConnect(window: UIWindow(), needsSetup: false)
        #expect(!lock.calls.contains(.unlockWithBiometrics))
        coordinator.sceneDidBecomeActive()
        #expect(await waitForCondition { lock.calls.contains(.unlockWithBiometrics) })
    }

    // MARK: Launch recovery

    @Test("A pending encrypt with no password blob is dropped and the app opens without a lock screen")
    func pendingEncryptWithoutBlobIsDropped() {
        let harness = makeUnfinishableHarness()
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        #expect(harness.preferences.pendingMigration == nil)
        #expect(harness.preferences.lockMode == .none)
        #expect(harness.lock.calls.contains(.appWillEnterForeground))
        #expect(harness.presenter.count(of: .presentLockScreen) == 0)
    }

    @Test("A pending encrypt with a blob and lockMode .none asks for the password and keeps the record")
    func pendingEncryptWithBlobAsksForPassword() {
        let pending = pendingEncrypt()
        let harness = makeHarness(lockMode: .none, pending: pending)
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
        #expect(harness.preferences.pendingMigration == pending)
        #expect(harness.preferences.lockMode == .none)
    }

    @Test("A Keychain error reading the blob counts as a blob: everything is kept and the password is asked")
    func keychainErrorCountsAsBlob() {
        let pending = pendingEncrypt()
        let harness = makeHarness(lockMode: .none, pending: pending)
        harness.masterKeys.errorToThrow = .keychain(-25300)
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
        #expect(harness.preferences.pendingMigration == pending)
        #expect(harness.preferences.lockMode == .none)
    }

    @Test("With no pending encrypt, the normal rule applies: a lock shows the lock screen")
    func nonePendingWithLockShowsLockScreen() {
        let harness = makeHarness(hasBlob: false)
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        #expect(harness.presenter.count(of: .presentLockScreen) == 1)
        #expect(harness.preferences.lockMode == .password)
    }

    @Test("With no pending encrypt and no lock, nothing is shown and nothing is changed")
    func nonePendingWithoutLockShowsNothing() {
        let harness = makeHarness(lockMode: .none, hasBlob: false)
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        #expect(harness.presenter.requests.isEmpty)
        #expect(harness.preferences.writes.isEmpty)
    }

    @Test("A pending decrypt with no blob is not dropped")
    func pendingDecryptWithoutBlobIsKept() {
        let pending = PendingMigration(kind: .decrypt, targetLockMode: nil)
        let harness = makeHarness(lockMode: .none, pending: pending, hasBlob: false)
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        #expect(harness.preferences.pendingMigration == pending)
    }

    @Test("Recovery runs at connect before onUnlocked can observe the pending record")
    func recoveryRunsBeforeOnUnlocked() {
        let harness = makeUnfinishableHarness()
        var pendingSeenByOnUnlocked: [PendingMigration?] = []
        harness.coordinator.onUnlocked = { pendingSeenByOnUnlocked.append(harness.preferences.pendingMigration) }
        harness.coordinator.sceneDidConnect(window: harness.window, needsSetup: false)
        #expect(pendingSeenByOnUnlocked.allSatisfy { $0 == nil })
        #expect(harness.preferences.pendingMigration == nil)
    }
}
