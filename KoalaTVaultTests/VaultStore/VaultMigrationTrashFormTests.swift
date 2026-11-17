import Foundation
import Testing

@testable import KoalaTVault

/// `hasUnencryptedFiles()` and the trash: an entry that isn't a regular file is judged by its stored flag, a form
/// check that fails for a file that still exists propagates, and a file removed while it is checked is skipped.
@Suite struct VaultMigrationTrashFormTests {
    /// An encrypted vault whose trash holds one healthy encrypted file.
    private func vaultWithTrashedFile() async throws -> (vault: VaultStoreFixture, key: String) {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        let item = try await vault.add("seed.txt", "seed")
        try await vault.store.moveToTrash(item)
        let entries = try #require(vault.trashEntries())
        return (vault, try #require(entries.keys.first))
    }

    /// Adds a trash entry whose file is a symbolic link (not a regular file), with the given stored flag.
    private func addLinkEntry(_ vault: VaultStoreFixture, isEncrypted: Bool) throws {
        let entries = try #require(vault.trashEntries())
        let (_, seedEntry) = try #require(entries.first)
        let target = try vault.outsideFolder().appendingPathComponent("target.txt")
        try Data("target".utf8).write(to: target)
        let key = VaultStoreFixture.newDiskName()
        try FileManager.default.createSymbolicLink(
            at: vault.trashURL.appendingPathComponent(key), withDestinationURL: target)
        var all = entries
        var entry = seedEntry
        entry["originalName"] = "link.txt"
        entry["isEncrypted"] = isEncrypted
        all[key] = entry
        let json = try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        try (VaultStoreFixture.sealedPrefix + Data(".trash_map:".utf8) + json).write(to: vault.trashMapURL)
    }

    @Test("A trash entry that isn't a regular file counts as unencrypted when its stored flag says so")
    func nonRegularTrashEntryWithPlainFlagIsUnencrypted() async throws {
        let (vault, _) = try await vaultWithTrashedFile()
        defer { vault.cleanUp() }
        try addLinkEntry(vault, isEncrypted: false)

        #expect(try await vault.store.hasUnencryptedFiles())
    }

    @Test("A trash entry that isn't a regular file is skipped when its stored flag says encrypted")
    func nonRegularTrashEntryWithEncryptedFlagIsSkipped() async throws {
        let (vault, _) = try await vaultWithTrashedFile()
        defer { vault.cleanUp() }
        try addLinkEntry(vault, isEncrypted: true)

        #expect(try await vault.store.hasUnencryptedFiles() == false)
    }

    @Test("hasUnencryptedFiles throws locked when the key is lost while a trash file's form is checked")
    func trashFormCheckLockedPropagates() async throws {
        let (vault, _) = try await vaultWithTrashedFile()
        defer { vault.cleanUp() }
        vault.failing?.streamInfoError = VaultCryptoError.noKeyLoaded

        let error = await caught { _ = try await vault.store.hasUnencryptedFiles() }

        #expect(error as? VaultStoreError == .locked)
    }

    @Test("hasUnencryptedFiles throws io when a trash file that still exists can't be read")
    func trashFormCheckIOPropagates() async throws {
        let (vault, key) = try await vaultWithTrashedFile()
        defer { vault.cleanUp() }
        vault.failing?.streamInfoError = VaultCryptoError.decryptionFailed
        let restore = try restrict(vault.trashURL.appendingPathComponent(key), to: 0o000)
        defer { restore() }

        let error = await caught { _ = try await vault.store.hasUnencryptedFiles() }
        restore()

        #expect(isIOError(error))
    }

    @Test("A trash file removed while its form is checked is skipped")
    func trashFileRemovedDuringCheckIsSkipped() async throws {
        let (vault, key) = try await vaultWithTrashedFile()
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let url = vault.trashURL.appendingPathComponent(key)
        failing.onFirstStreamInfo = { _ in try? FileManager.default.removeItem(at: url) }

        #expect(try await vault.store.hasUnencryptedFiles() == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
