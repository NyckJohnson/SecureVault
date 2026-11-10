import Combine
import Foundation
import StoreKit
import UIKit

/// The logic of the paywall: the price, Unlock and Restore.
@MainActor
final class PaywallViewModel: ObservableObject {
    /// The paywall's title.
    let title = "Unlock Pro"
    /// What Pro gives. The old copy, kept until Settings' build updates its tests and journey 9; the spec's is
    /// "Store more than 100 files in a vault and keep more than one encrypted vault."
    let message = "Store more than \(ProUnlock.freeFileLimit) files."
    /// The price; a blank line until it loads, so the layout doesn't move.
    @Published private(set) var priceText = " "
    /// True while a purchase or restore is in progress.
    @Published private(set) var isBusy = false

    private let pro: any ProUnlocking
    private weak var alerts: (any AlertPresenting)?
    private let onUnlock: @MainActor () -> Void
    private let onClose: @MainActor () -> Void

    /// - Parameters:
    ///   - pro: the "Unlock Pro" entitlement.
    ///   - alerts: shows errors (held weakly; usually the view controller that owns this).
    ///   - onUnlock: called after Pro is unlocked, before closing.
    ///   - onClose: closes the paywall.
    init(
        pro: any ProUnlocking, alerts: any AlertPresenting, onUnlock: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.pro = pro
        self.alerts = alerts
        self.onUnlock = onUnlock
        self.onClose = onClose
    }

    /// Loads the price.
    func loadPrice() async {
        priceText = await pro.displayPrice() ?? "Price unavailable"
    }

    /// The user tapped Unlock.
    /// - Parameter scene: where the store confirms the purchase, where supported.
    func unlockTapped(confirmIn scene: UIScene? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            switch try await pro.purchase(confirmIn: scene) {
            case .unlocked: finish()
            case .cancelled: break
            case .pending: alerts?.showError("Purchase pending approval.")
            }
        } catch StoreKitError.userCancelled {
            // The user backed out: nothing to say.
        } catch {
            alerts?.showError(error)
        }
    }

    /// The user tapped Restore.
    func restoreTapped() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if try await pro.restore() {
                finish()
            } else {
                alerts?.showError("No previous purchase found to restore.")
            }
        } catch StoreKitError.userCancelled {
            // The user backed out: nothing to say.
        } catch {
            alerts?.showError(error)
        }
    }

    private func finish() {
        onUnlock()
        onClose()
    }
}
