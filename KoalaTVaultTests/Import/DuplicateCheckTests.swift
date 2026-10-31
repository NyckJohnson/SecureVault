import Foundation
import Testing

@testable import KoalaTVault

// Assumed: `DuplicateCheck(store: any VaultStoring)` with
// `func isDuplicate(source: URL, named name: String, in directory: VaultDirectory) async throws -> Bool`:
// true when the directory already holds an item of that name with the same SHA-256 content.
@Suite struct DuplicateCheckTests {
    @Test("A name the folder does not hold is not a duplicate")
    func unknownNameIsNotDuplicate() async throws {
        let store = try DiskBackedVaultStore()
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        let file = try source.file("a.txt", content: "hello")
        let check = DuplicateCheck(store: store)
        #expect(try await check.isDuplicate(source: file, named: "a.txt", in: store.root) == false)
    }

    @Test("Same name and same content is a duplicate")
    func sameNameSameContentIsDuplicate() async throws {
        let store = try DiskBackedVaultStore()
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("a.txt", content: "hello")
        let file = try source.file("other-disk-name.txt", content: "hello")
        let check = DuplicateCheck(store: store)
        #expect(try await check.isDuplicate(source: file, named: "a.txt", in: store.root) == true)
    }

    @Test("Same name with different content is not a duplicate")
    func sameNameDifferentContentIsNotDuplicate() async throws {
        let store = try DiskBackedVaultStore()
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("a.txt", content: "hello")
        let file = try source.file("a.txt", content: "goodbye")
        let check = DuplicateCheck(store: store)
        #expect(try await check.isDuplicate(source: file, named: "a.txt", in: store.root) == false)
    }

    @Test("Same content under a different name is not a duplicate")
    func differentNameSameContentIsNotDuplicate() async throws {
        let store = try DiskBackedVaultStore()
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("a.txt", content: "hello")
        let file = try source.file("b.txt", content: "hello")
        let check = DuplicateCheck(store: store)
        #expect(try await check.isDuplicate(source: file, named: "b.txt", in: store.root) == false)
    }

    @Test("Only the target folder is searched")
    func otherFoldersAreIgnored() async throws {
        let store = try DiskBackedVaultStore()
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("Photos/a.txt", content: "hello")
        let file = try source.file("a.txt", content: "hello")
        let check = DuplicateCheck(store: store)
        #expect(try await check.isDuplicate(source: file, named: "a.txt", in: store.root) == false)
    }

    @Test("In an encrypted vault the same name and content is found as a duplicate")
    func encryptedVaultFindsDuplicate() async throws {
        let store = try DiskBackedVaultStore(encrypted: true)
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("a.txt", content: "secret")
        let file = try source.file("a.txt", content: "secret")
        let check = DuplicateCheck(store: store)
        #expect(try await check.isDuplicate(source: file, named: "a.txt", in: store.root) == true)
    }

    @Test(
        "In an encrypted vault the existing file is decrypted to a temp folder and removed afterwards",
        arguments: ["secret", "different"])
    func encryptedVaultCleansUpTempFolder(sourceContent: String) async throws {
        let store = try DiskBackedVaultStore(encrypted: true)
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("a.txt", content: "secret")
        let file = try source.file("a.txt", content: sourceContent)
        let check = DuplicateCheck(store: store)
        _ = try await check.isDuplicate(source: file, named: "a.txt", in: store.root)
        #expect(store.tempDirectoriesCreated >= 1)
        #expect(store.leftoverTempFiles.isEmpty)
    }

    @Test("An unencrypted vault is compared in place without a temp folder")
    func unencryptedVaultUsesNoTempFolder() async throws {
        let store = try DiskBackedVaultStore()
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("a.txt", content: "hello")
        let file = try source.file("a.txt", content: "hello")
        let check = DuplicateCheck(store: store)
        _ = try await check.isDuplicate(source: file, named: "a.txt", in: store.root)
        #expect(store.leftoverTempFiles.isEmpty)
    }

    @Test("An error from the store's findItem is rethrown")
    func findItemErrorIsRethrown() async throws {
        let store = try DiskBackedVaultStore()
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        let file = try source.file("a.txt", content: "hello")
        store.failFindItem(with: VaultStoreError.io("find failed"))
        let check = DuplicateCheck(store: store)
        await #expect(throws: VaultStoreError.io("find failed")) {
            _ = try await check.isDuplicate(source: file, named: "a.txt", in: store.root)
        }
    }
}
