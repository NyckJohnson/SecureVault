import Foundation
import Testing
import os

@testable import KoalaTVault

/// Device-test leftovers: a trash file that is gone, the shared store temp folder, and header-only probe reads.
@Suite struct VaultTrashLeftoversTests {
    // MARK: - Helpers

    private func vaultFiles(_ vault: VaultStoreFixture) throws -> [String: Data] {
        try vault.snapshot().filter { $0.key.hasPrefix(vault.rootURL.path) }
    }

    private func storeTempFolder(_ vault: VaultStoreFixture) -> URL {
        vault.tempRoot.appendingPathComponent("VaultStore", isDirectory: true)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func children(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private func runTrashChecks(_ vault: VaultStoreFixture) async throws {
        _ = await vault.store.hasUnreadableTrash()
        try await vault.store.clearUnreadableTrash()
        _ = try await vault.store.trashContents()
    }

    // MARK: - A trash item whose file is gone

    @Test("migrateToEncrypted on a trash item whose file is gone changes nothing and does not throw")
    func encryptMissingTrashFile() async throws {
        var vault = try VaultStoreFixture(lockMode: .none, headerAware: true)
        defer { vault.cleanUp() }
        let item = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(item)
        try await vault.add("keep.txt", "kept")
        vault.reopen(encrypted: true)

        let pending = try #require(
            try await vault.store.itemsToMigrate(toEncrypted: true).first { $0.name == "old.txt" })
        try FileManager.default.removeItem(at: pending.diskURL)
        let before = try vaultFiles(vault)

        try await vault.store.migrateToEncrypted(pending)

        #expect(try vaultFiles(vault) == before)
    }

    @Test("migrateToDecrypted on a trash item whose file is gone changes nothing and does not throw")
    func decryptMissingTrashFile() async throws {
        var vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let item = try await vault.add("old.txt", "old content")
        try await vault.store.moveToTrash(item)
        try await vault.add("keep.txt", "kept")
        vault.reopen(encrypted: false)

        let pending = try #require(
            try await vault.store.itemsToMigrate(toEncrypted: false).first { $0.name == "old.txt" })
        try FileManager.default.removeItem(at: pending.diskURL)
        let before = try vaultFiles(vault)

        try await vault.store.migrateToDecrypted(pending)

        #expect(try vaultFiles(vault) == before)
    }

    // MARK: - The store temp folder survives the trash checks

    @Test("The trash checks leave an existing store temp folder and its contents in place")
    func checksKeepExistingTempFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        try await vault.store.moveToTrash(item)
        let made = try vault.store.makeTempDirectory()
        let folder = storeTempFolder(vault)
        #expect(exists(folder))

        try await runTrashChecks(vault)

        #expect(exists(folder))
        #expect(exists(made))
        #expect(children(of: folder) == [made.lastPathComponent])
    }

    @Test("The trash checks leave the store temp folder in place and no probe folder in it")
    func checksKeepFolderTheyCreated() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        try await vault.store.moveToTrash(item)
        let folder = storeTempFolder(vault)
        #expect(exists(folder) == false)

        try await runTrashChecks(vault)

        #expect(exists(folder))
        #expect(children(of: folder).isEmpty)
    }

    @Test("Each trash check alone leaves a previously made temp folder untouched")
    func eachCheckKeepsMadeTempFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        try await vault.store.moveToTrash(item)
        let made = try vault.store.makeTempDirectory()
        let folder = storeTempFolder(vault)

        _ = await vault.store.hasUnreadableTrash()
        #expect(exists(made) && exists(folder))
        try await vault.store.clearUnreadableTrash()
        #expect(exists(made) && exists(folder))
        _ = try await vault.store.trashContents()
        #expect(exists(made) && exists(folder))
        #expect(children(of: folder) == [made.lastPathComponent])
    }

    // MARK: - Header-only reads

    @Test("Listing a large healthy encrypted trash file copies at most 8 KiB for the header read")
    func listingCopiesOnlyTheHeader() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let item = try await vault.add("big.bin", String(repeating: "a", count: 300_000))
        try await vault.store.moveToTrash(item)

        let size = OSAllocatedUnfairLock<Int?>(initialState: nil)
        failing.onFirstStreamInfo = { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = attributes?[.size] as? Int
            size.withLock { $0 = bytes }
        }
        let listed = try await vault.store.trashContents()

        #expect(listed.map(\.name) == ["big.bin"])
        let copied = try #require(size.withLock { $0 })
        #expect(copied <= 4 * 1024)
    }
}
