import Testing
import UIKit

@testable import KoalaTVault

/// Contract for the view (the code-writer must match it):
/// `PaywallViewController(pro: any ProUnlocking, onUnlock: @escaping @MainActor () -> Void)`.
/// Identifiers follow the journey tests: `paywall.titleLabel`, `paywall.descriptionLabel`, `paywall.priceLabel`,
/// `paywallUnlockButton`, `restoreButton`, `paywall.closeButton`, `paywall.activityIndicator`.
@MainActor
@Suite struct PaywallViewControllerTests {
    private struct Rig {
        let host: SettingsViewHost
        let pro: SettingsScriptedPro
        let unlocked: SettingsRecorder<Void>
    }

    private func makeRig(
        price: String? = "$4.99", outcome: PurchaseOutcome = .unlocked, restores: Bool = false
    ) async -> Rig {
        let mock = MockProUnlocking(isUnlocked: false, price: price)
        mock.purchaseOutcome = outcome
        mock.restoreFindsPurchase = restores
        let pro = SettingsScriptedPro(inner: mock)
        let unlocked = SettingsRecorder<Void>()
        let controller = PaywallViewController(pro: pro, onUnlock: { unlocked.record(()) })
        let host = SettingsViewHost.presenting(controller)
        return Rig(host: host, pro: pro, unlocked: unlocked)
    }

    private func text(_ id: String, _ rig: Rig) -> String? {
        (rig.host.element(id) as? UILabel)?.text
    }

    @Test("The paywall shows its title, the 100-file message and the three controls")
    func staticContent() async {
        let rig = await makeRig()
        #expect(text("paywall.titleLabel", rig) == "Unlock Pro")
        #expect(
            text("paywall.descriptionLabel", rig)
                == "Store more than 100 files in a vault and keep more than one encrypted vault.")
        #expect(rig.host.element("paywallUnlockButton") is UIButton)
        #expect(rig.host.element("restoreButton") is UIButton)
        #expect(rig.host.element("paywall.closeButton") != nil)
    }

    @Test("The price label shows the store's price once loaded")
    func priceShown() async {
        let rig = await makeRig(price: "$4.99")
        await SettingsTestSupport.waitUntil { self.text("paywall.priceLabel", rig) == "$4.99" }
        #expect(text("paywall.priceLabel", rig) == "$4.99")
    }

    @Test("A price that cannot load shows Price unavailable")
    func priceUnavailable() async {
        let rig = await makeRig(price: nil)
        await SettingsTestSupport.waitUntil { self.text("paywall.priceLabel", rig) == "Price unavailable" }
        #expect(text("paywall.priceLabel", rig) == "Price unavailable")
    }

    @Test("Unlock buys Pro, calls onUnlock once and closes the paywall")
    func unlockSucceeds() async {
        let rig = await makeRig(outcome: .unlocked)
        rig.host.tap("paywallUnlockButton")
        await SettingsTestSupport.waitUntil { rig.host.root.presentedViewController == nil }
        #expect(rig.pro.inner.calls.contains(.purchase))
        #expect(rig.unlocked.values.count == 1)
        #expect(rig.host.root.presentedViewController == nil)
    }

    @Test("A cancelled purchase leaves the paywall up, with no alert and no onUnlock")
    func unlockCancelled() async {
        let rig = await makeRig(outcome: .cancelled)
        rig.host.tap("paywallUnlockButton")
        await SettingsTestSupport.waitUntil { rig.pro.inner.calls.contains(.purchase) }
        #expect(await rig.host.noAlert())
        #expect(rig.unlocked.values.isEmpty)
        #expect(rig.host.element("paywallUnlockButton") != nil)
    }

    @Test("A pending purchase shows Purchase pending approval. and stays")
    func unlockPending() async {
        let rig = await makeRig(outcome: .pending)
        rig.host.tap("paywallUnlockButton")
        let alert = await rig.host.alert()
        #expect(alert?.message == "Purchase pending approval.")
        #expect(rig.unlocked.values.isEmpty)
    }

    @Test("Restore with a previous purchase calls onUnlock and closes")
    func restoreSucceeds() async {
        let rig = await makeRig(restores: true)
        rig.host.tap("restoreButton")
        await SettingsTestSupport.waitUntil { rig.host.root.presentedViewController == nil }
        #expect(rig.unlocked.values.count == 1)
        #expect(rig.host.root.presentedViewController == nil)
    }

    @Test("Restore without a purchase shows No previous purchase found to restore. and stays")
    func restoreFindsNothing() async {
        let rig = await makeRig(restores: false)
        rig.host.tap("restoreButton")
        let alert = await rig.host.alert()
        #expect(alert?.message == "No previous purchase found to restore.")
        #expect(rig.unlocked.values.isEmpty)
    }

    @Test("Close dismisses the paywall without calling onUnlock")
    func closeDismisses() async {
        let rig = await makeRig()
        rig.host.tap("paywall.closeButton")
        await SettingsTestSupport.waitUntil { rig.host.root.presentedViewController == nil }
        #expect(rig.host.root.presentedViewController == nil)
        #expect(rig.unlocked.values.isEmpty)
    }

    @Test("While a purchase is in progress Unlock and Restore are disabled and the spinner shows")
    func busyState() async {
        let rig = await makeRig()
        rig.pro.holdsCalls = true
        rig.host.tap("paywallUnlockButton")
        await SettingsTestSupport.waitUntil { rig.pro.gate.isWaiting }
        #expect(rig.host.isEnabled("paywallUnlockButton") == false)
        #expect(rig.host.isEnabled("restoreButton") == false)
        let spinner = rig.host.element("paywall.activityIndicator") as? UIActivityIndicatorView
        #expect(spinner?.isAnimating == true)
        rig.pro.gate.release()
        await SettingsTestSupport.waitUntil { rig.host.root.presentedViewController == nil }
    }
}
