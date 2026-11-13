import Foundation
import Testing

@testable import KoalaTVault

/// `findItem(named:in:)` looks up one name; its results are the same as finding it in the folder's listing.
@Suite struct VaultFindItemTests {
    @Test("findItem finds an encrypted file by display name with the same fields as the listing")
    func encryptedMatchesListing() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let added = try await vault.add("Report.pdf", "data", to: docs)
        try await vault.add("Other.txt", "o", to: docs)

        let found = try #require(try await vault.store.findItem(named: "Report.pdf", in: docs))

        #expect(found.name == "Report.pdf")
        #expect(found.id == added.id)
        #expect(found.isEncrypted)
        #expect(found.isDirectory == false)
        let listed = try #require(try await vault.list(docs).first { $0.name == "Report.pdf" })
        #expect(found == listed)
    }

    @Test("findItem finds a plaintext file in an unencrypted vault with the same fields as the listing")
    func plaintextMatchesListing() async throws {
        let vault = try VaultStoreFixture(lockMode: .none)
        defer { vault.cleanUp() }
        try vault.diskFile("a.txt", "hello")
        try vault.diskFile("b.txt")

        let found = try #require(try await vault.store.findItem(named: "a.txt", in: vault.root))

        #expect(found.isEncrypted == false)
        #expect(found.id == "a.txt")
        #expect(try await vault.list().first { $0.name == "a.txt" } == found)
    }

    @Test("findItem finds a folder by name in both modes", arguments: [LockMode.none, .password])
    func folder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        try vault.folder("Docs")
        try await vault.add("a.txt")

        let found = try #require(try await vault.store.findItem(named: "Docs", in: vault.root))

        #expect(found.isDirectory)
        #expect(found.isEncrypted == false)
        #expect(try await vault.list().first { $0.name == "Docs" } == found)
    }

    @Test("findItem returns nil for a missing name in both modes", arguments: [LockMode.none, .password])
    func missing(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        #expect(try await vault.store.findItem(named: "missing.txt", in: vault.root) == nil)
        #expect(try await vault.store.findItem(named: "", in: vault.root) == nil)
    }

    @Test("findItem in an empty folder returns nil and creates no index")
    func emptyFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        #expect(try await vault.store.findItem(named: "a.txt", in: vault.root) == nil)
        #expect(vault.rawIndex() == nil)
    }

    @Test("findItem finds an unmapped disk file in an encrypted vault by its disk name")
    func unmappedByDiskName() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("Mapped.txt")
        try vault.diskFile("loose.txt", "loose")

        let found = try #require(try await vault.store.findItem(named: "loose.txt", in: vault.root))

        #expect(found.name == "loose.txt")
        #expect(found.id == "loose.txt")
        #expect(found.isEncrypted == false)
        #expect(try await vault.list().first { $0.name == "loose.txt" } == found)
    }

    @Test("findItem does not find a mapped file by its UUID disk name")
    func mappedNotFoundByUUID() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let added = try await vault.add("Secret.txt")
        let diskName = (added.id as NSString).lastPathComponent
        #expect(try await vault.store.findItem(named: diskName, in: vault.root) == nil)
    }

    @Test("findItem does not return hidden entries such as the index")
    func hiddenNotFound() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        #expect(try await vault.store.findItem(named: ".vault_map", in: vault.root) == nil)
    }

    @Test("findItem searches only the given folder", arguments: [LockMode.none, .password])
    func onlyGivenFolder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try await vault.add("inner.txt", to: docs)
        #expect(try await vault.store.findItem(named: "inner.txt", in: vault.root) == nil)
        #expect(try await vault.store.findItem(named: "inner.txt", in: docs) != nil)
    }

    @Test("findItem does not decrypt any file content")
    func noContentDecryption() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        for index in 0..<5 { try await vault.add("f\(index).txt") }
        let before = vault.cipher.calls.count

        _ = try await vault.store.findItem(named: "f3.txt", in: vault.root)

        let during = vault.cipher.calls.dropFirst(before)
        #expect(during.allSatisfy { if case .decrypt = $0 { return true } else { return false } })
        #expect(during.count <= 1)
    }

    @Test("findItem in an unreadable index throws indexUnreadable")
    func unreadableIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.writeRawIndex(Data("garbage".utf8))
        let error = await caught { _ = try await vault.store.findItem(named: "a.txt", in: vault.root) }
        #expect(isIndexUnreadable(error))
        #expect(vault.rawIndex() == Data("garbage".utf8))
    }
}
