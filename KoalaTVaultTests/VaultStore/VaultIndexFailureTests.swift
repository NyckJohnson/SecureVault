import Foundation
import Testing

@testable import KoalaTVault

/// The index when the cipher fails or the key disappears part-way through an operation.
@Suite struct VaultIndexFailureTests {
    @Test("A key that disappears while the index is decrypted gives locked and leaves the index alone")
    func keyLostDuringIndexReadIsLocked() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.diskFile("11111111-1111-1111-1111-111111111111")
        try vault.writeIndex(["11111111-1111-1111-1111-111111111111": "a.txt"], context: ".vault_map")
        let before = vault.rawIndex()
        vault.cipher.errorToThrow = .noKeyLoaded

        let error = await caught { _ = try await vault.list() }

        vault.cipher.errorToThrow = nil
        #expect(error as? VaultStoreError == .locked)
        #expect(vault.rawIndex() == before)
    }

    enum SealFailure: String, CaseIterable, Sendable {
        case noKey, other

        var cryptoError: VaultCryptoError { self == .noKey ? .noKeyLoaded : .encryptionFailed }
        func matches(_ error: (any Error)?) -> Bool {
            self == .noKey ? error as? VaultStoreError == .locked : isIOError(error)
        }
    }

    @Test(
        "An index write whose sealing fails throws locked or io and never writes plaintext",
        arguments: SealFailure.allCases)
    func indexWriteWithFailingSealThrows(failure: SealFailure) async throws {
        let vault = try VaultStoreFixture(lockMode: .password, selective: true)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        let before = vault.rawIndex()
        let failing = try #require(vault.failing)
        failing.encryptError = failure.cryptoError

        let error = await caught { _ = try await vault.store.rename(item, to: "b.txt") }

        failing.encryptError = nil
        #expect(failure.matches(error), "unexpected error \(String(describing: error))")
        #expect(vault.rawIndex() == before)
        #expect(!vault.indexIsPlaintextJSON())
        #expect(vault.indexEntries()?[item.id] == "a.txt")
    }
}
