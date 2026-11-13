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

/// Edge cases of `findItem(named:in:)`: errors, stale and duplicate index entries, letter case, hidden names and
/// the spelling of names. Where the listing doesn't throw, the answer equals the listing-based one.
@Suite struct VaultFindItemEdgeCaseTests {
    private let uuidA = "00000000-0000-0000-0000-00000000000A"
    private let uuidB = "00000000-0000-0000-0000-00000000000B"

    /// The old answer: the first item of the folder's listing with that display name.
    private func listed(_ vault: VaultStoreFixture, _ name: String, in directory: VaultDirectory) async throws
        -> VaultItem?
    {
        try await vault.list(directory).first { $0.name == name }
    }

    @Test("findItem in a removed folder throws notFound, as the listing does", arguments: [LockMode.none, .password])
    func missingFolder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let gone = try vault.folder("Gone")
        try FileManager.default.removeItem(at: gone.diskURL)

        let error = await caught { _ = try await vault.store.findItem(named: "a.txt", in: gone) }
        let listingError = await caught { _ = try await vault.list(gone) }

        #expect(error as? VaultStoreError == .notFound)
        #expect(listingError as? VaultStoreError == .notFound)
    }

    @Test("findItem in a 'folder' that is a file throws io", arguments: [LockMode.none, .password])
    func folderIsAFile(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let url = try vault.diskFile("notAFolder")
        let fake = VaultDirectory(name: "notAFolder", diskURL: url, rootURL: vault.rootURL)

        let error = await caught { _ = try await vault.store.findItem(named: "a.txt", in: fake) }

        #expect(isIOError(error), "expected io, got \(String(describing: error))")
    }

    @Test("findItem in an unreadable folder throws io, as the listing does", arguments: [LockMode.none, .password])
    func unreadableFolder(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let locked = try vault.folder("Locked")
        try await vault.add("a.txt", to: locked)
        let restore = try restrict(locked.diskURL, to: 0o000)
        defer { restore() }

        let error = await caught { _ = try await vault.store.findItem(named: "a.txt", in: locked) }
        let listingError = await caught { _ = try await vault.list(locked) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(isIOError(listingError))
    }

    @Test("findItem does not return an index entry whose file is gone from disk")
    func staleIndexEntry() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let added = try await vault.add("a.txt")
        try await vault.add("b.txt")
        try FileManager.default.removeItem(at: added.diskURL)

        let found = try await vault.store.findItem(named: "a.txt", in: vault.root)

        #expect(found == nil)
        #expect(found == (try await listed(vault, "a.txt", in: vault.root)))
    }

    @Test("findItem with a stale index entry returns the unmapped disk file of that name")
    func staleIndexEntryWithUnmappedFileOfSameName() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let added = try await vault.add("a.txt")
        try FileManager.default.removeItem(at: added.diskURL)
        try vault.diskFile("a.txt", "loose")

        let found = try #require(try await vault.store.findItem(named: "a.txt", in: vault.root))

        #expect(found.id == "a.txt")
        #expect(found.isEncrypted == false)
        #expect(found == (try await listed(vault, "a.txt", in: vault.root)))
    }

    @Test("findItem with two index entries of one display name returns the one with the smallest disk name")
    func duplicateDisplayNames() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.writeIndex([uuidB: "same.txt", uuidA: "same.txt"], context: ".vault_map")
        try vault.diskFile(uuidB)
        try vault.diskFile(uuidA)

        let found = try #require(try await vault.store.findItem(named: "same.txt", in: vault.root))

        #expect(found.id == uuidA)
        #expect(found.isEncrypted)
    }

    @Test("findItem is case sensitive: A.TXT does not find a.txt", arguments: [LockMode.none, .password])
    func letterCase(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")

        let found = try await vault.store.findItem(named: "A.TXT", in: vault.root)

        #expect(found == nil)
        #expect(found == (try await listed(vault, "A.TXT", in: vault.root)))
        #expect(try await vault.store.findItem(named: "a.txt", in: vault.root) != nil)
    }

    @Test("findItem returns the mapped item before an unmapped disk file with the same name")
    func mappedBeforeUnmapped() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.writeIndex([uuidA: "dup.txt"], context: ".vault_map")
        try vault.diskFile(uuidA)
        try vault.diskFile("dup.txt", "loose")

        let found = try #require(try await vault.store.findItem(named: "dup.txt", in: vault.root))

        #expect(found.id == uuidA)
        #expect(found.isEncrypted)
    }

    @Test("findItem never returns an index entry whose disk name starts with a dot")
    func hiddenDiskNameInIndex() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try vault.writeIndex([".hidden": "x.txt"], context: ".vault_map")
        try vault.diskFile(".hidden")

        let found = try await vault.store.findItem(named: "x.txt", in: vault.root)

        #expect(found == nil)
        #expect(found == (try await listed(vault, "x.txt", in: vault.root)))
    }

    @Test(
        "findItem returns an unmapped file under its on-disk spelling of the name",
        arguments: [LockMode.none, .password])
    func unicodeSpelling(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let decomposed = "e\u{301}.txt"
        let composed = "\u{e9}.txt"
        try vault.diskFile(decomposed)
        let onDisk = try #require(try vault.diskNames().first { $0.hasSuffix(".txt") })

        let found = try #require(try await vault.store.findItem(named: composed, in: vault.root))

        #expect(Array(found.name.unicodeScalars) == Array(onDisk.unicodeScalars))
        #expect(Array(found.id.unicodeScalars) == Array(onDisk.unicodeScalars))
        #expect(found.diskURL.lastPathComponent.unicodeScalars.elementsEqual(onDisk.unicodeScalars))
    }
}
