import UIKit

/// Constants of the "Unlock Pro" purchase.
enum ProUnlock {
    /// The non-consumable's App Store product identifier.
    static let productID = "nej.KoalaTVault.unlockpro"
    /// How many files the free tier may store.
    static let freeFileLimit = 100
}

/// The result of a purchase that didn't fail.
enum PurchaseOutcome: Sendable, Equatable {
    case unlocked, cancelled, pending
}

/// Errors thrown by a purchase.
enum ProUnlockError: Error, Equatable, Sendable {
    case productUnavailable, verificationFailed, purchaseFailed
}

extension ProUnlockError: LocalizedError {
    /// The text the user sees; alerts show `localizedDescription`.
    var errorDescription: String? {
        switch self {
        case .productUnavailable: "Pro upgrade is currently unavailable."
        case .verificationFailed: "Could not verify purchase."
        case .purchaseFailed: "Purchase could not be completed."
        }
    }
}

/// The "Unlock Pro" entitlement through StoreKit 2.
@MainActor
protocol ProUnlocking: AnyObject, Sendable {
    /// Whether Pro is unlocked.
    var isUnlocked: Bool { get }
    /// Thread-safe cached value for non-main callers (the import limit).
    nonisolated var isUnlockedNow: Bool { get }
    /// The product's display price, or nil when unavailable.
    func displayPrice() async -> String?
    /// Buys Pro, confirming in `scene` where supported.
    func purchase(confirmIn scene: UIScene?) async throws -> PurchaseOutcome
    /// Restores purchases; returns whether Pro is unlocked afterwards.
    func restore() async throws -> Bool
    /// Re-reads the current entitlement from StoreKit.
    func refresh() async
    /// Each change of `isUnlocked`.
    func unlockedUpdates() -> AsyncStream<Bool>
}
