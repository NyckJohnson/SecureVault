import Foundation
import StoreKit
import StoreKitTest
import Testing

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
}

/// A StoreKit test session, a throwaway UserDefaults suite, and a factory for the unit under test.
@MainActor
private final class Fixture {
    let session: SKTestSession
    let suiteName = "StoreKitProUnlockTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
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
        transform: @escaping @Sendable (VerificationResult<Transaction>) -> VerificationResult<Transaction> = { $0 }
    ) -> StoreKitProUnlock {
        StoreKitProUnlock(defaults: defaults, productID: productID, verificationTransform: transform)
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
    func startsFromCachedUnlocked() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: cacheKey)
        let unlock = fixture.makeUnlock()
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
    }

    @Test("Starts locked when nothing is cached")
    func startsLockedWithoutCache() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
    }

    @Test("A refresh after starting from a stale unlocked cache sets both values from StoreKit")
    func refreshCorrectsStaleCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: cacheKey)
        let unlock = fixture.makeUnlock()
        await unlock.refresh()
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
    }

    @Test("A refresh after starting from a stale locked cache unlocks when StoreKit has the purchase")
    func refreshCorrectsStaleLockedCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.buyExternally()
        let unlock = fixture.makeUnlock()
        await unlock.refresh()
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
    }

    // MARK: Refresh

    @Test("Refresh with a verified entitlement unlocks and caches it")
    func refreshUnlocks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        try await fixture.buyExternally()
        await unlock.refresh()
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
        #expect(fixture.cached)
    }

    @Test("Refresh with no entitlement leaves it locked and the cache false")
    func refreshLocked() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        await unlock.refresh()
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
    }

    @Test("Refresh after a revocation locks again and the cache follows")
    func refreshAfterRevocation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        try await fixture.buyExternally()
        await unlock.refresh()
        #expect(unlock.isUnlocked)

        let transactions = fixture.session.allTransactions()
        let purchase = try #require(transactions.first { $0.productIdentifier == ProUnlock.productID })
        try fixture.session.refundTransaction(identifier: purchase.identifier)

        await unlock.refresh()
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
    }

    @Test("Refresh treats an unverified entitlement as not unlocked")
    func refreshIgnoresUnverifiedEntitlement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.buyExternally()
        let unlock = fixture.makeUnlock(transform: makeUnverified)
        await unlock.refresh()
        #expect(unlock.isUnlocked == false)
        #expect(fixture.cached == false)
    }

    @Test("Refresh for an unknown product id stays locked")
    func refreshOtherProductStaysLocked() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.buyExternally()
        let unlock = fixture.makeUnlock(productID: "nej.KoalaTVault.nothing")
        await unlock.refresh()
        #expect(unlock.isUnlocked == false)
    }

    @Test("Each change reaches unlockedUpdates once, in order, and an unchanged refresh adds nothing")
    func updatesDeliverEachChangeOnce() async throws {
        let fixture = try Fixture()
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
    func updatesReachEveryObserver() async throws {
        let fixture = try Fixture()
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
    func displayPriceReturnsPrice() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        #expect(await unlock.displayPrice() == "$19.99")
    }

    @Test("displayPrice is nil when the product does not exist")
    func displayPriceNilWithoutProduct() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock(productID: "nej.KoalaTVault.nothing")
        #expect(await unlock.displayPrice() == nil)
    }

    // MARK: Purchase

    @Test("A verified purchase unlocks, returns .unlocked, caches, and finishes the transaction")
    func purchaseUnlocks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        let outcome = try await unlock.purchase(confirmIn: nil)
        #expect(outcome == .unlocked)
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
        #expect(fixture.cached)
        #expect(await unfinishedTransactionIDs().isEmpty)
    }

    @Test("A purchase notifies unlockedUpdates observers once")
    func purchaseNotifiesObservers() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        let collector = Collector(unlock.unlockedUpdates())
        defer { collector.stop() }
        _ = try await unlock.purchase(confirmIn: nil)
        #expect(await waitUntil { collector.values == [true] })
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(collector.values == [true])
    }

    @Test("A purchase that needs approval returns .pending and stays locked")
    func purchasePending() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.session.askToBuyEnabled = true
        let unlock = fixture.makeUnlock()
        let outcome = try await unlock.purchase(confirmIn: nil)
        #expect(outcome == .pending)
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
    }

    @Test("An unverified purchase throws verificationFailed, stays locked, and leaves the transaction unfinished")
    func purchaseUnverified() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock(transform: makeUnverified)
        await #expect(throws: ProUnlockError.verificationFailed) {
            _ = try await unlock.purchase(confirmIn: nil)
        }
        #expect(unlock.isUnlocked == false)
        #expect(fixture.cached == false)
        #expect(await unfinishedTransactionIDs().isEmpty == false)
    }

    @Test("Purchasing an unknown product throws productUnavailable")
    func purchaseProductUnavailable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock(productID: "nej.KoalaTVault.nothing")
        await #expect(throws: ProUnlockError.productUnavailable) {
            _ = try await unlock.purchase(confirmIn: nil)
        }
        #expect(unlock.isUnlocked == false)
    }

    @Test("A purchase StoreKit fails throws purchaseFailed and stays locked")
    func purchaseFailed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.session.failTransactionsEnabled = true
        let unlock = fixture.makeUnlock()
        await #expect(throws: ProUnlockError.purchaseFailed) {
            _ = try await unlock.purchase(confirmIn: nil)
        }
        #expect(unlock.isUnlocked == false)
        #expect(fixture.cached == false)
    }

    // MARK: Restore

    @Test("Restore returns true and unlocks when the App Store has the purchase")
    func restoreFindsPurchase() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.buyExternally()
        let unlock = fixture.makeUnlock()
        #expect(try await unlock.restore())
        #expect(unlock.isUnlocked)
        #expect(unlock.isUnlockedNow)
        #expect(fixture.cached)
    }

    @Test("Restore returns false and stays locked when there is no purchase")
    func restoreFindsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        #expect(try await unlock.restore() == false)
        #expect(unlock.isUnlocked == false)
        #expect(fixture.cached == false)
    }

    @Test("Restore with a stale unlocked cache and no purchase returns false")
    func restoreCorrectsStaleCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: cacheKey)
        let unlock = fixture.makeUnlock()
        #expect(try await unlock.restore() == false)
        #expect(unlock.isUnlocked == false)
        #expect(fixture.cached == false)
    }

    // MARK: Transaction updates

    @Test("A purchase made outside the instance unlocks it live and notifies observers")
    func externalPurchaseUnlocksLive() async throws {
        let fixture = try Fixture()
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

    @Test("A verified update's transaction is finished")
    func externalPurchaseIsFinished() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock()
        try await fixture.buyExternally()
        #expect(await waitUntil { unlock.isUnlocked })
        #expect(await waitUntil { await unfinishedTransactionIDs().isEmpty })
    }

    @Test("An unverified update is ignored: it neither unlocks nor finishes the transaction")
    func unverifiedUpdateIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unlock = fixture.makeUnlock(transform: makeUnverified)
        try await fixture.buyExternally()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(unlock.isUnlocked == false)
        #expect(unlock.isUnlockedNow == false)
        #expect(fixture.cached == false)
        #expect(await unfinishedTransactionIDs().isEmpty == false)
    }

    @Test("A revocation arriving as an update locks the instance live")
    func externalRevocationLocksLive() async throws {
        let fixture = try Fixture()
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
