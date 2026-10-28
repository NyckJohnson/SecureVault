# Legacy-test scan: Entitlements

Legacy tests: `KoalaTVaultTests/StoreKitConfigurationTests.swift`. New tests: `KoalaTVaultTests/Entitlements/StoreKitProUnlockTests.swift`.

| Legacy case | Class | Notes |
| --- | --- | --- |
| testConfigurationFileContainsUnlockProduct | obsolete | Parses premiumTesting.storekit and checks that the product id is present and NonConsumable, via the legacy `EntitlementService.unlockProductID`. It is worth keeping, re-created against `ProUnlock.productID`, because the new tests would only fail indirectly if the config broke. |
| testUnlockProductLoadsFromConfiguration | covered | `displayPriceReturnsPrice`. The product type isn't asserted directly; the re-created config test above would cover it. |
| testPurchasedTransactionGrantsEntitlement | covered | `refreshUnlocks`, `externalPurchaseUnlocksLive`, restore tests; "starts locked" covered by the start tests. |
| setUp/tearDown singleton reset | obsolete | New tests use an injected suite and a fresh instance. |

No case is missed, contradicts the spec, or is outside the spec.

Carried over from `entitlements-unit1-notes.md`: once the legacy listener is gone, the finish checks become real (verified finished, unverified not finished); the re-lock window needs a decision from the human.
