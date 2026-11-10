import Foundation
import UIKit
import os

/// An "Unlock Pro" entitlement held in memory; records every call.
@MainActor
final class MockProUnlocking: ProUnlocking {
    /// A recorded call.
    enum Call: Equatable, Sendable { case displayPrice, purchase, restore, refresh, unlockedUpdates }

    /// Every call so far, in order.
    private(set) var calls: [Call] = []
    /// The price `displayPrice()` returns.
    var price: String?
    /// What `purchase(confirmIn:)` returns; `.unlocked` also unlocks.
    var purchaseOutcome: PurchaseOutcome = .unlocked
    /// Whether `restore()` finds a previous purchase.
    var restoreFindsPurchase = false
    /// When set, `purchase(confirmIn:)` and `restore()` throw this error.
    var errorToThrow: ProUnlockError?

    var isUnlocked: Bool {
        didSet {
            let value = isUnlocked
            cachedUnlocked.withLock { $0 = value }
            if value != oldValue {
                for continuation in continuations.values { continuation.yield(value) }
            }
        }
    }

    private let cachedUnlocked: OSAllocatedUnfairLock<Bool>
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    /// An entitlement that starts unlocked or not, with a display price.
    init(isUnlocked: Bool = false, price: String? = "$4.99") {
        self.isUnlocked = isUnlocked
        self.price = price
        cachedUnlocked = OSAllocatedUnfairLock(initialState: isUnlocked)
    }

    nonisolated var isUnlockedNow: Bool { cachedUnlocked.withLock { $0 } }

    func displayPrice() async -> String? {
        calls.append(.displayPrice)
        return price
    }

    func purchase(confirmIn scene: UIScene?) async throws -> PurchaseOutcome {
        calls.append(.purchase)
        if let errorToThrow { throw errorToThrow }
        if purchaseOutcome == .unlocked { isUnlocked = true }
        return purchaseOutcome
    }

    func restore() async throws -> Bool {
        calls.append(.restore)
        if let errorToThrow { throw errorToThrow }
        if restoreFindsPurchase { isUnlocked = true }
        return isUnlocked
    }

    func refresh() async {
        calls.append(.refresh)
    }

    func unlockedUpdates() -> AsyncStream<Bool> {
        calls.append(.unlockedUpdates)
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.continuations[id] = nil }
            }
        }
    }
}
