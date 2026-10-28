import Foundation
import Testing

@testable import KoalaTVault

/// Listing and writing when the disk or the cipher misbehaves.
@Suite struct LiveVaultStoreFailureTests {
    @Test("trashContents doesn't list an entry whose file is missing", arguments: [LockMode.none, .password])
    func trashContentsSkipsMissingFile(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let lost = try await vault.add("lost.txt", "lost")
        let kept = try await vault.add("kept.txt", "kept")
        try await vault.store.moveToTrash(lost)
        try await vault.store.moveToTrash(kept)
        let listed = try await vault.store.trashContents()
        let lostItem = try #require(listed.first { $0.name == "lost.txt" })
        try FileManager.default.removeItem(at: lostItem.diskURL)

        let after = try await vault.store.trashContents()

        #expect(after.map(\.name) == ["kept.txt"])
    }

    @Test("Listing a folder that can't be read throws io and changes nothing", arguments: [LockMode.none, .password])
    func contentsOfUnreadableFolderThrowsIO(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let locked = try vault.folder("Locked")
        try await vault.add("a.txt")
        let before = try vault.diskNames()
        let restore = try restrict(locked.diskURL, to: 0o000)
        defer { restore() }

        let error = await caught { _ = try await vault.store.contents(of: locked, sortedBy: .name, .ascending) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.diskNames() == before)
        #expect(try vault.diskNames(in: locked).isEmpty)
    }

    @Test("Listing a folder that was removed throws notFound and changes nothing")
    func contentsOfRemovedFolderThrowsNotFound() async throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let gone = try vault.folder("Gone")
        try FileManager.default.removeItem(at: gone.diskURL)
        let before = try vault.diskNames()

        let error = await caught { _ = try await vault.store.contents(of: gone, sortedBy: .name, .ascending) }

        #expect(error as? VaultStoreError == .notFound)
        #expect(try vault.diskNames() == before)
    }

    @Test(
        "Files with the same modification date are ordered by id, the same way in every listing",
        arguments: [LockMode.none, .password])
    func dateTieBrokenById(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        // Imported out of order, so the order can't come from creation order.
        for name in ["b.txt", "c.txt", "a.txt"] { try await vault.add(name) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for item in try await vault.list() { try vault.setModified(item.diskURL, to: date) }
        let ids = try await vault.list().sorted { $0.id < $1.id }.map(\.id)
        let namesById = Dictionary(uniqueKeysWithValues: try await vault.list().map { ($0.id, $0.name) })

        let ascending = try await vault.list(nil, .dateModified, .ascending)
        let ascendingAgain = try await vault.list(nil, .dateModified, .ascending)
        let descending = try await vault.list(nil, .dateModified, .descending)

        #expect(ascending.map(\.id) == ids)
        #expect(ascendingAgain.map(\.id) == ids)
        #expect(descending.map(\.id) == ids.reversed())
        #expect(ascending.map(\.name) == ids.compactMap { namesById[$0] })
    }

    @Test("Writing to a plaintext item in a read-only folder throws io and leaves the file unchanged")
    func plaintextWriteInReadOnlyFolderThrowsIO() async throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "original")
        let restore = try restrict(vault.rootURL)
        defer { restore() }

        let error = await caught { try await vault.store.write(Data("changed".utf8), to: item) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.content(item.diskURL) == "original")
        #expect(try vault.diskNames() == ["a.txt"])
    }

    @Test("Writing to an encrypted item whose encryption fails throws, leaves the file and stages nothing")
    func encryptedWriteWithFailingEncryptionThrows() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "original")
        let before = try Data(contentsOf: item.diskURL)
        let indexBefore = vault.rawIndex()
        vault.cipher.errorToThrow = .encryptionFailed

        let error = await caught { try await vault.store.write(Data("changed".utf8), to: item) }

        vault.cipher.errorToThrow = nil
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try Data(contentsOf: item.diskURL) == before)
        #expect(vault.rawIndex() == indexBefore)
        #expect(vault.tempFiles().isEmpty)
        #expect(try await vault.openedContent(item) == "original")
    }
}
