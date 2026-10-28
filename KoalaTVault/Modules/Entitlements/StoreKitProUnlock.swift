import Foundation
import StoreKit
import UIKit
import os

/// The live `ProUnlocking`: the "Unlock Pro" non-consumable through StoreKit 2.
///
/// `isUnlocked` starts from the value cached under `entitlement.isUnlocked` (a key earlier app versions
/// wrote), so it is right before StoreKit answers; `refresh()` then sets it from the current entitlements.
/// A listener on `Transaction.updates` finishes verified updates and refreshes, so a purchase or refund
/// made elsewhere applies live. `isUnlockedNow` mirrors `isUnlocked` behind a lock for non-main callers.
@MainActor
final class StoreKitProUnlock: ProUnlocking {
    private static let cacheKey = "entitlement.isUnlocked"

    private let defaults: UserDefaults
    private let productID: String
    private let verificationTransform: @Sendable (VerificationResult<Transaction>) -> VerificationResult<Transaction>
    private let purchaseSeam: @MainActor (Product, UIScene?) async throws -> Product.PurchaseResult
    private let syncSeam: @MainActor () async throws -> Void
    private let unlockedNow: OSAllocatedUnfairLock<Bool>
    private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var updatesListener: Task<Void, Never>?
    /// The most recently started refresh. Each refresh waits for the one before it, so refreshes apply
    /// in the order they started: an older one can't finish late and overwrite a newer answer.
    private var lastRefresh: Task<Void, Never>?

    private(set) var isUnlocked: Bool

    nonisolated var isUnlockedNow: Bool { unlockedNow.withLock { $0 } }

    /// An entitlement for `productID`, cached in `defaults`.
    ///
    /// - Parameters:
    ///   - verificationTransform: applied to every `VerificationResult` before it is checked
    ///     (identity in the app; tests use it to simulate failed verification).
    ///   - purchase: buys a product, confirming in the scene when given (the app uses the default, the real
    ///     StoreKit call; unit tests inject outcomes, since hosted-test purchases fail on the simulator).
    ///   - sync: syncs with the App Store (default `AppStore.sync()`).
    init(
        defaults: UserDefaults,
        productID: String = ProUnlock.productID,
        verificationTransform:
            @escaping @Sendable (VerificationResult<Transaction>) -> VerificationResult<Transaction> = { $0 },
        // coverage-exempt-begin: real StoreKit purchase fails in the hosted unit-test process (AMS 305); journey J9 covers it
        purchase: @escaping @MainActor (Product, UIScene?) async throws -> Product.PurchaseResult = { product, scene in
            if #available(iOS 17.0, *), let scene {
                return try await product.purchase(confirmIn: scene)
            }
            return try await product.purchase()
        },
        // coverage-exempt-end
        sync: @escaping @MainActor () async throws -> Void = { try await AppStore.sync() }
    ) {
        self.defaults = defaults
        self.productID = productID
        self.verificationTransform = verificationTransform
        purchaseSeam = purchase
        syncSeam = sync
        let cached = defaults.bool(forKey: Self.cacheKey)
        isUnlocked = cached
        unlockedNow = OSAllocatedUnfairLock(initialState: cached)
        updatesListener = listenForTransactionUpdates()
        Task { [weak self] in await self?.refresh() }
    }

    deinit {
        updatesListener?.cancel()
    }

    func displayPrice() async -> String? {
        let products = try? await Product.products(for: [productID])
        return products?.first?.displayPrice
    }

    func purchase(confirmIn scene: UIScene?) async throws -> PurchaseOutcome {
        let product: Product
        do {
            guard let found = try await Product.products(for: [productID]).first else {
                throw ProUnlockError.productUnavailable
            }
            product = found
        } catch let error as ProUnlockError {
            throw error
        } catch {
            throw ProUnlockError.purchaseFailed
        }

        let result: Product.PurchaseResult
        do {
            result = try await purchaseSeam(product, scene)
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            throw ProUnlockError.purchaseFailed
        }

        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verificationTransform(verification) else {
                throw ProUnlockError.verificationFailed
            }
            await transaction.finish()
            setUnlocked(true)
            // Queue a refresh behind any already in flight, so an older refresh that read the entitlements
            // before this purchase can't leave the entitlement re-locked: the ordered queue has the last word.
            await refresh()
            return .unlocked
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            throw ProUnlockError.purchaseFailed  // coverage-exempt: @unknown default cannot be constructed in a test
        }
    }

    /// Syncs with the App Store, then refreshes. StoreKit's errors (including a user cancel) are rethrown.
    func restore() async throws -> Bool {
        try await syncSeam()
        await refresh()
        return isUnlocked
    }

    func refresh() async {
        let previous = lastRefresh
        let current = Task {
            await previous?.value
            setUnlocked(await hasVerifiedEntitlement())
        }
        lastRefresh = current
        await current.value
    }

    /// Whether `Transaction.currentEntitlements` holds a verified transaction for the product.
    private func hasVerifiedEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = verificationTransform(result), transaction.productID == productID {
                return true
            }
        }
        return false
    }

    func unlockedUpdates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }

    /// Applies a new value: on a change, updates the lock-guarded mirror and the cache and tells observers.
    private func setUnlocked(_ value: Bool) {
        guard value != isUnlocked else { return }
        isUnlocked = value
        unlockedNow.withLock { $0 = value }
        defaults.set(value, forKey: Self.cacheKey)
        for continuation in observers.values {
            continuation.yield(value)
        }
    }

    /// Finishes each verified update and refreshes; unverified updates are ignored and left unfinished.
    /// Holds `self` weakly so the instance can be released, which cancels the listener.
    /// Once cancelled or released, the listener stops before finishing anything, so a leftover
    /// listener never finishes a transaction that a live instance should handle.
    private func listenForTransactionUpdates() -> Task<Void, Never> {
        let transform = verificationTransform
        return Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = transform(update) else { continue }
                guard !Task.isCancelled, let self else { return }
                await transaction.finish()
                await self.refresh()
            }
        }
    }
}
