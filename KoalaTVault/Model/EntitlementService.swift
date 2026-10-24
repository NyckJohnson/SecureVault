import Combine
import StoreKit
import UIKit
import os

enum EntitlementError: LocalizedError {
    case purchaseFailed
    case productUnavailable
    case purchasePending
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .purchaseFailed:     return "Purchase could not be completed."
        case .productUnavailable: return "Pro upgrade is currently unavailable."
        case .purchasePending:    return "Purchase is pending approval."
        case .verificationFailed: return "Could not verify purchase."
        }
    }
}

/// Owns the one-time "Unlock Pro" purchase and its entitlement state.
/// Entitlement syncs automatically across devices via the user's Apple ID.
@MainActor
final class EntitlementService: ObservableObject {
    static let shared = EntitlementService()

    nonisolated static let unlockProductID = "nej.KoalaTVault.unlockpro"
    nonisolated static let freeFileLimit = 100

    @Published private(set) var isUnlocked: Bool = false {
        didSet { updateSyncCache() }
    }

    nonisolated private static let syncCache = OSAllocatedUnfairLock(initialState: false)
    nonisolated private static let isUnlockedCacheKey = "entitlement.isUnlocked"

    /// Thread-safe, synchronous snapshot of `isUnlocked` for callers off the main
    /// actor (e.g. FileSystem's background import queue) that can't await this property.
    nonisolated static var isUnlockedSync: Bool {
#if DEBUG
        if let forced = Self.testForcedUnlocked { return forced }
#endif
        return syncCache.withLock { $0 }
    }

#if DEBUG
    // Test-only override for `isUnlockedSync`, bypassing StoreKit entirely.
    // nil = no override (Bool? is intentional here: nil means "not set", not "false").
    // swiftlint:disable:next discouraged_optional_boolean
    nonisolated(unsafe) static var testForcedUnlocked: Bool?
#endif

    private func updateSyncCache() {
        let value = isUnlocked
        Self.syncCache.withLock { $0 = value }
        LegacyStorage.current.defaults.set(value, forKey: Self.isUnlockedCacheKey)
    }

    private var updateListenerTask: Task<Void, Never>?

    private init() {
        // Pre-seed the sync cache from the last persisted value so isUnlockedSync is
        // correct immediately, before the async StoreKit refresh completes.
        let persisted = LegacyStorage.current.defaults.bool(forKey: Self.isUnlockedCacheKey)
        Self.syncCache.withLock { $0 = persisted }

        updateListenerTask = listenForTransactionUpdates()
        Task { await refreshEntitlementStatus() }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    /// Initiates the purchase flow. Updates `isUnlocked` on success.
    func purchaseUnlock(confirmIn scene: UIScene? = nil) async throws {
        let products = try await Product.products(for: [Self.unlockProductID])
        guard let product = products.first else { throw EntitlementError.productUnavailable }

        let result: Product.PurchaseResult
        if #available(iOS 17.0, *), let scene {
            result = try await product.purchase(confirmIn: scene)
        } else {
            result = try await product.purchase()
        }

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            isUnlocked = true
        case .userCancelled:
            break
        case .pending:
            throw EntitlementError.purchasePending
        @unknown default:
            throw EntitlementError.purchaseFailed
        }
    }

    /// Manual restore entry point (still expected by users alongside auto-sync).
    func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlementStatus()
    }

    /// Re-checks all current entitlements for this Apple ID, including
    /// purchases made on other devices.
    func refreshEntitlementStatus() async {
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == Self.unlockProductID {
                isUnlocked = true
                return
            }
        }
        isUnlocked = false
    }

    /// Long-running listener for transactions arriving from other devices
    /// or Ask-to-Buy approvals while the app is open.
    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self, let transaction = try? self.checkVerified(result) else { continue }
                await transaction.finish()
                await self.refreshEntitlementStatus()
            }
        }
    }

    nonisolated private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw EntitlementError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }
}
