import Foundation
import StoreKit
import StoreKitTest
import Testing
import UIKit

@testable import KoalaTVault

/// The key the cached entitlement is stored under (a documented, kept-as-is key).
private let cacheKey = "entitlement.isUnlocked"

/// Marks every verified result unverified; used to simulate a failed signature check.
private let makeUnverified: @Sendable (VerificationResult<Transaction>) -> VerificationResult<Transaction> = { result in
    switch result {
    case .verified(let transaction): return .unverified(transaction, .invalidSignature)
    case .unverified: return result
    }
}

/// Collects every value a stream yields.
@MainActor
private final class Collector {
    private(set) var values: [Bool] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Bool>) {
        task = Task { [weak self] in
            for await value in stream { self?.values.append(value) }
        }
    }

    func stop() { task?.cancel() }

    func reset() { values = [] }
}

/// A purchase seam that returns a canned result (or throws) and records what it was called with.
@MainActor
private final class PurchaseSeam {
    private(set) var productIDs: [String] = []
    private(set) var scenes: [UIScene?] = []
    private let outcome: Result<Product.PurchaseResult, Error>

    init(_ outcome: Result<Product.PurchaseResult, Error>) { self.outcome = outcome }

    var callCount: Int { productIDs.count }

    var closure: @MainActor (Product, UIScene?) async throws -> Product.PurchaseResult {
        { [self] product, scene in
            productIDs.append(product.id)
            scenes.append(scene)
            return try outcome.get()
        }
    }
}

private struct SeamError: Error {}

/// Holds the instance and the older refresh task a seam needs to reach.
@MainActor
private final class RefreshHolder {
    var unlock: StoreKitProUnlock?
    var staleRefresh: Task<Void, Never>?
}

/// Counts how often the verification transform runs (once per entitlement or purchase result checked).
private final class TransformCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.lock(); defer { lock.unlock() }; return count }

    var transform: @Sendable (VerificationResult<Transaction>) -> VerificationResult<Transaction> {
        { [self] result in
            lock.lock()
            count += 1
            lock.unlock()
            return result
        }
    }
}

/// A StoreKit test session, a throwaway UserDefaults suite, and a factory for the unit under test.
@MainActor
@available(iOS 17.0, *)
private final class Fixture {
    let session: SKTestSession
    let suiteName = "StoreKitProUnlockTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    static func make() async throws -> Fixture { try Fixture() }

    private init() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("premiumTesting.storekit")
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.failTransactionsEnabled = false
        guard let suite = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("cannot create suite")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeUnlock(
        productID: String = ProUnlock.productID,
        transform: @escaping @Sendable (VerificationResult<Transaction>) -> VerificationResult<Transaction> = { $0 },
        purchase: PurchaseSeam? = nil,
        sync: (@MainActor () async throws -> Void)? = nil
    ) -> StoreKitProUnlock {
        switch (purchase, sync) {
        case (nil, nil):
            return StoreKitProUnlock(defaults: defaults, productID: productID, verificationTransform: transform)
        case (let purchase?, nil):
            return StoreKitProUnlock(
                defaults: defaults, productID: productID, verificationTransform: transform,
                purchase: purchase.closure)
        case (nil, let sync?):
            return StoreKitProUnlock(
                defaults: defaults, productID: productID, verificationTransform: transform, sync: sync)
        case (let purchase?, let sync?):
            return StoreKitProUnlock(
                defaults: defaults, productID: productID, verificationTransform: transform,
                purchase: purchase.closure, sync: sync)
        }
    }

    /// Buys the product outside any `StoreKitProUnlock` and returns the resulting real transaction.
    func boughtTransaction() async throws -> VerificationResult<Transaction> {
        try await buyExternally()
        return try #require(await Transaction.latest(for: ProUnlock.productID))
    }

    var cached: Bool { defaults.bool(forKey: cacheKey) }

    /// Buys the product outside any `StoreKitProUnlock`, as another device or the App Store would.
    func buyExternally() async throws {
        try await session.buyProduct(identifier: ProUnlock.productID)
    }

    func cleanup() {
        session.clearTransactions()
        session.resetToDefaultState()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Ids of the product's transactions StoreKit still considers unfinished.
private func unfinishedTransactionIDs() async -> [UInt64] {
    var ids: [UInt64] = []
    for await result in Transaction.unfinished {
        switch result {
        case .verified(let transaction), .unverified(let transaction, _):
            if transaction.productID == ProUnlock.productID { ids.append(transaction.id) }
        }
    }
    return ids
}

/// Polls until `condition` holds or about ten seconds pass; returns whether it held.
@MainActor
private func waitUntil(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

// SKTestSession is process-wide state, so these tests run one at a time.
@MainActor
@Suite(.serialized) struct StoreKitProUnlockTests {
    // MARK: Start

    @Test("Starts unlocked from the cached value before any refresh")
    @available(iOS 17.0, *)
    func startsFromCachedUnlocked() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: cacheKey)
        let unlock = fixture.makeUnlock()
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
    }

    @Test("Starts locked when nothing is cached")
    @available(iOS 17.0, *)
    func startsLockedWithoutCache() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
    }

    @Test("A refresh after starting from a stale unlocked cache sets both values from StoreKit")
    @available(iOS 17.0, *)
    func refreshCorrectsStaleCache() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: cacheKey)
        let unlock = fixture.makeUnlock()
        await unlock.refresh()
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
    }

    @Test("A refresh after starting from a stale locked cache unlocks when StoreKit has the purchase")
    @available(iOS 17.0, *)
    func refreshCorrectsStaleLockedCache() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        try await fixture.buyExternally()
        let unlock = fixture.makeUnlock()
        // The entitlement lands asynchronously after the buy; refresh until it shows.
        _ = await waitUntil {
            await unlock.refresh()
            return unlock.isUnlocked
        }
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
    }

    // MARK: Refresh

    @Test("Refresh with a verified entitlement unlocks and caches it")
    @available(iOS 17.0, *)
    func refreshUnlocks() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        try await fixture.buyExternally()
        await unlock.refresh()
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
        #expect(fixture.cached)
    }

    @Test("Refresh with no entitlement leaves it locked and the cache false")
    @available(iOS 17.0, *)
    func refreshLocked() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        await unlock.refresh()
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
    }

    @Test("Refresh after a revocation locks again and the cache follows")
    @available(iOS 17.0, *)
    func refreshAfterRevocation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        try await fixture.buyExternally()
        await unlock.refresh()
        #expect(unlock.isUnlocked)

        let transactions = fixture.session.allTransactions()
        let purchase = try #require(transactions.first { $0.productIdentifier == ProUnlock.productID })
        try fixture.session.refundTransaction(identifier: purchase.identifier)

        // The refund reaches StoreKit's entitlements asynchronously; refresh until it shows.
        _ = await waitUntil {
            await unlock.refresh()
            return unlock.isUnlocked == false
        }
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
    }

    @Test("Refresh treats an unverified entitlement as not unlocked")
    @available(iOS 17.0, *)
    func refreshIgnoresUnverifiedEntitlement() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        try await fixture.buyExternally()
        let unlock = fixture.makeUnlock(transform: makeUnverified)
        await unlock.refresh()
        #expect(unlock.isUnlocked == false)
        #expect(fixture.cached == false)
    }

    @Test("Refresh for an unknown product id stays locked")
    @available(iOS 17.0, *)
    func refreshOtherProductStaysLocked() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        try await fixture.buyExternally()
        let unlock = fixture.makeUnlock(productID: "nej.KoalaTVault.nothing")
        await unlock.refresh()
        #expect(unlock.isUnlocked == false)
    }

    @Test("Each change reaches unlockedUpdates once, in order, and an unchanged refresh adds nothing")
    @available(iOS 17.0, *)
    func updatesDeliverEachChangeOnce() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        let collector = Collector(unlock.unlockedUpdates())
        defer { collector.stop() }

        await unlock.refresh()  // still locked: no change
        try await fixture.buyExternally()
        await unlock.refresh()
        await unlock.refresh()  // already unlocked: no change
        #expect(await waitUntil { collector.values == [true] })

        let purchase = try #require(
            fixture.session.allTransactions().first { $0.productIdentifier == ProUnlock.productID })
        try fixture.session.refundTransaction(identifier: purchase.identifier)
        await unlock.refresh()
        #expect(await waitUntil { collector.values == [true, false] })

        // Let any late duplicate arrive before asserting there is none.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(collector.values == [true, false])
    }

    @Test("Every observer of unlockedUpdates gets the change")
    @available(iOS 17.0, *)
    func updatesReachEveryObserver() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        let first = Collector(unlock.unlockedUpdates())
        let second = Collector(unlock.unlockedUpdates())
        defer { first.stop(); second.stop() }
        try await fixture.buyExternally()
        await unlock.refresh()
        #expect(await waitUntil { first.values == [true] && second.values == [true] })
    }

    // MARK: Display price

    @Test("displayPrice returns the product's formatted price")
    @available(iOS 17.0, *)
    func displayPriceReturnsPrice() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        #expect(await unlock.displayPrice() == "$19.99")
    }

    @Test("displayPrice is nil when the product does not exist")
    @available(iOS 17.0, *)
    func displayPriceNilWithoutProduct() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock(productID: "nej.KoalaTVault.nothing")
        #expect(await unlock.displayPrice() == nil)
    }

    // MARK: Purchase

    @Test("A verified purchase unlocks, returns .unlocked, caches, and finishes the transaction")
    @available(iOS 17.0, *)
    func purchaseUnlocks() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let verification = try await fixture.boughtTransaction()
        let id = verification.unsafePayloadValue.id
        let seam = PurchaseSeam(.success(.success(verification)))
        let unlock = fixture.makeUnlock(purchase: seam)
        let outcome = try await unlock.purchase(confirmIn: nil)
        #expect(outcome == .unlocked)
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
        #expect(fixture.cached)
        #expect(seam.callCount == 1)
        #expect(seam.productIDs == [ProUnlock.productID])
        #expect(await waitUntil { await unfinishedTransactionIDs().contains(id) == false })
    }

    @Test("A purchase notifies unlockedUpdates observers once")
    @available(iOS 17.0, *)
    func purchaseNotifiesObservers() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let verification = try await fixture.boughtTransaction()
        let unlock = fixture.makeUnlock(purchase: PurchaseSeam(.success(.success(verification))))
        let collector = Collector(unlock.unlockedUpdates())
        defer { collector.stop() }
        _ = try await unlock.purchase(confirmIn: nil)
        #expect(await waitUntil { collector.values == [true] })
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(collector.values == [true])
    }

    @Test("A successful purchase ends with a refresh, so an older in-flight refresh cannot leave it locked")
    @available(iOS 17.0, *)
    func purchaseEndsWithRefreshAfterEarlierRefresh() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let verification = try await fixture.boughtTransaction()
        let counter = TransformCounter()
        // The seam lets an older refresh get under way before the purchase result is returned.
        let holder = RefreshHolder()
        let seam: @MainActor (Product, UIScene?) async throws -> Product.PurchaseResult = { _, _ in
            if let unlock = holder.unlock {
                holder.staleRefresh = Task { @MainActor in await unlock.refresh() }
                for _ in 0..<5 { await Task.yield() }
            }
            return .success(verification)
        }
        let unlock = StoreKitProUnlock(
            defaults: fixture.defaults, verificationTransform: counter.transform, purchase: seam)
        holder.unlock = unlock
        let collector = Collector(unlock.unlockedUpdates())
        defer { collector.stop() }
        // Let the refresh that runs at start finish, so the reads below belong to the purchase.
        #expect(await waitUntil { unlock.isUnlocked })
        try await Task.sleep(nanoseconds: 500_000_000)
        let baseline = counter.value
        collector.reset()

        #expect(try await unlock.purchase(confirmIn: nil) == .unlocked)
        await holder.staleRefresh?.value

        // A refresh ran after the purchase result was checked: the purchase check is one read, each
        // refresh of the (single) entitlement is another, and the older refresh is at most one of them.
        #expect(await waitUntil { counter.value >= baseline + 3 })
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
        #expect(fixture.cached)
        #expect(collector.values.contains(false) == false)
    }

    @Test("The scene given to purchase(confirmIn:) reaches the purchase call; nil stays nil")
    @available(iOS 17.0, *)
    func purchasePassesSceneThrough() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let seam = PurchaseSeam(.success(.pending))
        let unlock = fixture.makeUnlock(purchase: seam)
        _ = try await unlock.purchase(confirmIn: nil)
        #expect(seam.scenes.count == 1)
        #expect(seam.scenes.first.map { $0 == nil } == true)
    }

    @Test("A user cancel returns .cancelled and changes nothing")
    @available(iOS 17.0, *)
    func purchaseCancelled() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock(purchase: PurchaseSeam(.success(.userCancelled)))
        let collector = Collector(unlock.unlockedUpdates())
        defer { collector.stop() }
        let outcome = try await unlock.purchase(confirmIn: nil)
        #expect(outcome == .cancelled)
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(collector.values.isEmpty)
    }

    @Test("A cancel while unlocked leaves it unlocked")
    @available(iOS 17.0, *)
    func purchaseCancelledKeepsUnlocked() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: cacheKey)
        let unlock = fixture.makeUnlock(purchase: PurchaseSeam(.success(.userCancelled)))
        #expect(try await unlock.purchase(confirmIn: nil) == .cancelled)
        #expect(unlock.isUnlocked)
        #expect(fixture.cached)
    }

    @Test("A purchase that needs approval returns .pending and stays locked")
    @available(iOS 17.0, *)
    func purchasePending() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock(purchase: PurchaseSeam(.success(.pending)))
        let outcome = try await unlock.purchase(confirmIn: nil)
        #expect(outcome == .pending)
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
    }

    @Test("An unverified purchase throws verificationFailed and stays locked")
    @available(iOS 17.0, *)
    func purchaseUnverified() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let verification = try await fixture.boughtTransaction()
        let unverified = VerificationResult<Transaction>.unverified(
            verification.unsafePayloadValue, .invalidSignature)
        let unlock = fixture.makeUnlock(
            transform: makeUnverified, purchase: PurchaseSeam(.success(.success(unverified))))
        await #expect(throws: ProUnlockError.verificationFailed) {
            _ = try await unlock.purchase(confirmIn: nil)
        }
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
    }

    @Test("Purchasing an unknown product throws productUnavailable without starting a purchase")
    @available(iOS 17.0, *)
    func purchaseProductUnavailable() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let seam = PurchaseSeam(.success(.pending))
        let unlock = fixture.makeUnlock(productID: "nej.KoalaTVault.nothing", purchase: seam)
        await #expect(throws: ProUnlockError.productUnavailable) {
            _ = try await unlock.purchase(confirmIn: nil)
        }
        #expect(seam.callCount == 0)
        #expect(unlock.isUnlocked == false)
    }

    @Test("A purchase that throws another error throws purchaseFailed and stays locked")
    @available(iOS 17.0, *)
    func purchaseFailed() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock(purchase: PurchaseSeam(.failure(SeamError())))
        await #expect(throws: ProUnlockError.purchaseFailed) {
            _ = try await unlock.purchase(confirmIn: nil)
        }
        #expect(unlock.isUnlocked == false)
        #expect(fixture.cached == false)
    }

    // MARK: Restore

    @Test("Restore returns true and unlocks when the App Store has the purchase")
    @available(iOS 17.0, *)
    func restoreFindsPurchase() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        try await fixture.buyExternally()
        let unlock = fixture.makeUnlock()
        #expect(try await unlock.restore())
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
        #expect(fixture.cached)
    }

    @Test("Restore returns false and stays locked when there is no purchase")
    @available(iOS 17.0, *)
    func restoreFindsNothing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        #expect(try await unlock.restore() == false)
        #expect(unlock.isUnlocked == false)
        #expect(fixture.cached == false)
    }

    @Test("Restore with a stale unlocked cache and no purchase returns false")
    @available(iOS 17.0, *)
    func restoreCorrectsStaleCache() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: cacheKey)
        let unlock = fixture.makeUnlock()
        #expect(try await unlock.restore() == false)
        #expect(unlock.isUnlocked == false)
        #expect(fixture.cached == false)
    }

    @Test("Restore rethrows the StoreKit cancel error and changes nothing")
    @available(iOS 17.0, *)
    func restoreRethrowsCancel() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock(sync: { throw StoreKitError.userCancelled })
        do {
            _ = try await unlock.restore()
            Issue.record("restore should have thrown")
        } catch StoreKitError.userCancelled {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(unlock.isUnlocked == false)
        #expect(fixture.cached == false)
    }

    // MARK: Transaction updates

    @Test("A purchase made outside the instance unlocks it live and notifies observers once")
    @available(iOS 17.0, *)
    func externalPurchaseUnlocksLive() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        let collector = Collector(unlock.unlockedUpdates())
        defer { collector.stop() }

        try await fixture.buyExternally()

        #expect(await waitUntil { unlock.isUnlocked })
        #expect(unlock.isUnlockedNow)
        #expect(fixture.cached)
        #expect(await waitUntil { collector.values == [true] })
    }

    @Test("An unverified update is ignored: it does not unlock")
    @available(iOS 17.0, *)
    func unverifiedUpdateIgnored() async throws {
        // Whether the transaction stays unfinished is not asserted: the host app's legacy entitlement
        // listener also receives updates and may finish them, so that outcome is not reliable.
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock(transform: makeUnverified)
        let collector = Collector(unlock.unlockedUpdates())
        defer { collector.stop() }
        try await fixture.buyExternally()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
        #expect(collector.values.isEmpty)
    }

    @Test("A revocation arriving as an update locks the instance live")
    @available(iOS 17.0, *)
    func externalRevocationLocksLive() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        try await fixture.buyExternally()
        #expect(await waitUntil { unlock.isUnlocked })

        let purchase = try #require(
            fixture.session.allTransactions().first { $0.productIdentifier == ProUnlock.productID })
        try fixture.session.refundTransaction(identifier: purchase.identifier)

        #expect(await waitUntil { unlock.isUnlocked == false })
        #expect(fixture.cached == false)
    }
}
