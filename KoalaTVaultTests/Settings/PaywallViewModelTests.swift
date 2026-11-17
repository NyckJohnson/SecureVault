import Foundation
import StoreKit
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct PaywallViewModelTests {
    private struct Rig {
        let viewModel: PaywallViewModel
        let pro: SettingsScriptedPro
        let alerts: MockAlertPresenting
        let unlocked: SettingsRecorder<Void>
        let closed: SettingsRecorder<Void>

        var mock: MockProUnlocking { pro.inner }
    }

    private func makeRig(price: String? = "$4.99") -> Rig {
        let pro = SettingsScriptedPro(inner: MockProUnlocking(isUnlocked: false, price: price))
        let alerts = MockAlertPresenting()
        let unlocked = SettingsRecorder<Void>()
        let closed = SettingsRecorder<Void>()
        let viewModel = PaywallViewModel(
            pro: pro, alerts: alerts, onUnlock: { unlocked.record(()) }, onClose: { closed.record(()) })
        return Rig(viewModel: viewModel, pro: pro, alerts: alerts, unlocked: unlocked, closed: closed)
    }

    // MARK: - Strings and price

    @Test("The paywall is titled Unlock Pro and mentions both Pro limits")
    func strings() {
        let viewModel = makeRig().viewModel
        #expect(viewModel.title == "Unlock Pro")
        #expect(viewModel.message == "Store more than 100 files in a vault and keep more than one encrypted vault.")
    }

    @Test("The price shown is the store's display price")
    func priceShown() async {
        let rig = makeRig(price: "$4.99")
        await rig.viewModel.loadPrice()
        #expect(rig.viewModel.priceText == "$4.99")
    }

    @Test("A price that cannot be loaded shows Price unavailable")
    func priceUnavailable() async {
        let rig = makeRig(price: nil)
        await rig.viewModel.loadPrice()
        #expect(rig.viewModel.priceText == "Price unavailable")
    }

    // MARK: - Unlock

    @Test("An unlocked purchase closes the paywall and calls onUnlock once")
    func purchaseUnlocked() async {
        let rig = makeRig()
        rig.mock.purchaseOutcome = .unlocked
        await rig.viewModel.unlockTapped()
        #expect(rig.unlocked.values.count == 1)
        #expect(rig.closed.values.count == 1)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A cancelled purchase keeps the paywall open and says nothing")
    func purchaseCancelled() async {
        let rig = makeRig()
        rig.mock.purchaseOutcome = .cancelled
        await rig.viewModel.unlockTapped()
        #expect(rig.unlocked.values.isEmpty)
        #expect(rig.closed.values.isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A pending purchase shows Purchase pending approval. and stays open")
    func purchasePending() async {
        let rig = makeRig()
        rig.mock.purchaseOutcome = .pending
        await rig.viewModel.unlockTapped()
        #expect(rig.alerts.alerts == [.error("Purchase pending approval.")])
        #expect(rig.unlocked.values.isEmpty)
        #expect(rig.closed.values.isEmpty)
    }

    @Test("A StoreKit cancel during purchase is silent")
    func storeKitCancelDuringPurchase() async {
        let rig = makeRig()
        rig.pro.purchaseError = StoreKitError.userCancelled
        await rig.viewModel.unlockTapped()
        #expect(rig.alerts.alerts.isEmpty)
        #expect(rig.unlocked.values.isEmpty)
        #expect(rig.closed.values.isEmpty)
        #expect(!rig.viewModel.isBusy)
    }

    @Test("Any other purchase error is shown and the paywall stays open")
    func purchaseError() async {
        let rig = makeRig()
        rig.mock.errorToThrow = .purchaseFailed
        await rig.viewModel.unlockTapped()
        #expect(rig.alerts.alerts == [.error("Purchase could not be completed.")])
        #expect(rig.unlocked.values.isEmpty)
        #expect(rig.closed.values.isEmpty)
        #expect(!rig.viewModel.isBusy)
    }

    // MARK: - Restore

    @Test("A restore that finds a purchase closes the paywall and calls onUnlock")
    func restoreFound() async {
        let rig = makeRig()
        rig.mock.restoreFindsPurchase = true
        await rig.viewModel.restoreTapped()
        #expect(rig.unlocked.values.count == 1)
        #expect(rig.closed.values.count == 1)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A restore that finds nothing shows No previous purchase found to restore.")
    func restoreNothing() async {
        let rig = makeRig()
        rig.mock.restoreFindsPurchase = false
        await rig.viewModel.restoreTapped()
        #expect(rig.alerts.alerts == [.error("No previous purchase found to restore.")])
        #expect(rig.unlocked.values.isEmpty)
        #expect(rig.closed.values.isEmpty)
    }

    @Test("A StoreKit cancel during restore is silent")
    func storeKitCancelDuringRestore() async {
        let rig = makeRig()
        rig.pro.restoreError = StoreKitError.userCancelled
        await rig.viewModel.restoreTapped()
        #expect(rig.alerts.alerts.isEmpty)
        #expect(rig.closed.values.isEmpty)
        #expect(!rig.viewModel.isBusy)
    }

    @Test("Any other restore error is shown and the paywall stays open")
    func restoreError() async {
        let rig = makeRig()
        rig.mock.errorToThrow = .verificationFailed
        await rig.viewModel.restoreTapped()
        #expect(rig.alerts.alerts == [.error("Could not verify purchase.")])
        #expect(rig.closed.values.isEmpty)
        #expect(!rig.viewModel.isBusy)
    }

    // MARK: - Busy

    @Test("The paywall is busy while a purchase is in progress and idle afterwards")
    func busyDuringPurchase() async {
        let rig = makeRig()
        rig.pro.holdsCalls = true
        #expect(!rig.viewModel.isBusy)
        let viewModel = rig.viewModel
        let working = Task { await viewModel.unlockTapped() }
        await SettingsTestSupport.waitUntil { rig.pro.gate.isWaiting }
        #expect(rig.viewModel.isBusy)
        rig.pro.gate.release()
        await working.value
        #expect(!rig.viewModel.isBusy)
    }

    @Test("The paywall is busy while a restore is in progress and idle afterwards")
    func busyDuringRestore() async {
        let rig = makeRig()
        rig.pro.holdsCalls = true
        let viewModel = rig.viewModel
        let working = Task { await viewModel.restoreTapped() }
        await SettingsTestSupport.waitUntil { rig.pro.gate.isWaiting }
        #expect(rig.viewModel.isBusy)
        rig.pro.gate.release()
        await working.value
        #expect(!rig.viewModel.isBusy)
    }
}
