import Foundation
import Testing

@testable import KoalaTVault

/// Checks the StoreKit configuration file the Entitlements tests and the J9 journey run against.
@Suite struct StoreKitConfigurationFileTests {
    private func products() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("premiumTesting.storekit")
        let data = try Data(contentsOf: url)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["products"] as? [[String: Any]])
    }

    @Test("premiumTesting.storekit contains the Pro unlock product")
    func containsUnlockProduct() throws {
        let ids = try products().compactMap { $0["productID"] as? String }
        #expect(ids.contains(ProUnlock.productID), "Product ids in premiumTesting.storekit: \(ids)")
    }

    @Test("The Pro unlock product in premiumTesting.storekit is a non-consumable")
    func unlockProductIsNonConsumable() throws {
        let product = try #require(try products().first { $0["productID"] as? String == ProUnlock.productID })
        #expect(product["type"] as? String == "NonConsumable")
    }
}
