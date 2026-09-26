//
//  StoreKitConfigurationTests.swift
//  KoalaTVaultTests
//

import XCTest
import StoreKit
import StoreKitTest
@testable import KoalaTVault

final class StoreKitConfigurationTests: XCTestCase {

    private var session: SKTestSession?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "premiumTesting", withExtension: "storekit"),
            "premiumTesting.storekit is not in the KoalaTVaultTests bundle — check target membership"
        )
        let session = try SKTestSession(contentsOf: configURL)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        self.session = session
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        // EntitlementService is a singleton; reset its state so later tests start locked.
        await EntitlementService.shared.refreshEntitlementStatus()
        session = nil
        try await super.tearDown()
    }

    // MARK: - Configuration
    func testConfigurationFileContainsUnlockProduct() throws {
        let configURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "premiumTesting", withExtension: "storekit")
        )
        let data = try Data(contentsOf: configURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let products = json["products"] as? [[String: Any]] ?? []
        let ids = products.compactMap { $0["productID"] as? String }

        XCTAssertTrue(
            ids.contains(EntitlementService.unlockProductID),
            "Product IDs in bundled premiumTesting.storekit: \(ids)"
        )

        let unlockProduct = products.first { $0["productID"] as? String == EntitlementService.unlockProductID }
        XCTAssertEqual(unlockProduct?["type"] as? String, "NonConsumable")
    }
    
    @MainActor
    func testUnlockProductLoadsFromConfiguration() async throws {
        let products = try await Product.products(for: [EntitlementService.unlockProductID])

        let product = try XCTUnwrap(
            products.first,
            "No product for \(EntitlementService.unlockProductID) — check the ID in premiumTesting.storekit"
        )
        XCTAssertEqual(product.type, .nonConsumable)
    }

    // MARK: - Purchase
    @MainActor
    func testPurchasedTransactionGrantsEntitlement() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("buyProduct(identifier:) requires iOS 17") }
        let session = try XCTUnwrap(self.session)
        XCTAssertFalse(EntitlementService.shared.isUnlocked, "Precondition: should start locked")

        _ = try await session.buyProduct(identifier: EntitlementService.unlockProductID)
        await EntitlementService.shared.refreshEntitlementStatus()

        XCTAssertTrue(EntitlementService.shared.isUnlocked)
    }
}
