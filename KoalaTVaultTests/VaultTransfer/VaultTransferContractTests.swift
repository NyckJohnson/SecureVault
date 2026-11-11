import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultTransferContractTests {
    @Test("limitReached describes the other vault passing 100 files")
    func limitReachedDescription() {
        #expect(VaultTransferError.limitReached.errorDescription == "The other vault would have more than 100 files.")
    }

    @Test("sameVault says the items are already in this vault")
    func sameVaultDescription() {
        #expect(VaultTransferError.sameVault.errorDescription == "These items are already in this vault.")
    }

    @Test("localizedDescription shows the same texts in alerts")
    func localizedDescriptionMatches() {
        #expect(VaultTransferError.limitReached.localizedDescription == "The other vault would have more than 100 files.")
        #expect(VaultTransferError.sameVault.localizedDescription == "These items are already in this vault.")
    }
}
