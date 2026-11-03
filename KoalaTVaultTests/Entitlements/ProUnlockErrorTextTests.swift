import Foundation
import Testing

@testable import KoalaTVault

@Suite struct ProUnlockErrorTextTests {
    @Test("productUnavailable reads Pro upgrade is currently unavailable.")
    func productUnavailableText() {
        #expect(ProUnlockError.productUnavailable.errorDescription == "Pro upgrade is currently unavailable.")
        #expect(ProUnlockError.productUnavailable.localizedDescription == "Pro upgrade is currently unavailable.")
    }

    @Test("verificationFailed reads Could not verify purchase.")
    func verificationFailedText() {
        #expect(ProUnlockError.verificationFailed.errorDescription == "Could not verify purchase.")
        #expect(ProUnlockError.verificationFailed.localizedDescription == "Could not verify purchase.")
    }

    @Test("purchaseFailed reads Purchase could not be completed.")
    func purchaseFailedText() {
        #expect(ProUnlockError.purchaseFailed.errorDescription == "Purchase could not be completed.")
        #expect(ProUnlockError.purchaseFailed.localizedDescription == "Purchase could not be completed.")
    }
}
