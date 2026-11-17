import Foundation
import Testing
import os

@testable import KoalaTVault

/// Building an item for a name that has vanished from disk reports `.notFound` (the stat error is mapped to the
/// store's error type), reached here through `rename` when the file disappears while the folder's index is read.
@Suite struct LiveVaultStoreItemErrorTests {
    @Test("Renaming an encrypted item whose file vanishes while the index is read throws notFound")
    func renameOfVanishedEncryptedItemThrowsNotFound() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let item = try await vault.add("report.txt", "content")
        let failing = try #require(vault.failing)
        let url = item.diskURL
        failing.decryptErrorFor = { _ in
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        let error = await caught { _ = try await vault.store.rename(item, to: "renamed.txt") }

        #expect(error as? VaultStoreError == .notFound)
    }
}
