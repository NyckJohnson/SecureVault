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

    @Test("A same-named item whose source file does not exist is not a duplicate and does not throw")
    func missingSourceIsNotDuplicate() async throws {
        let store = try DiskBackedVaultStore()
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("a.txt", content: "hello")
        let missing = source.url.appendingPathComponent("missing.txt")
        let check = DuplicateCheck(store: store)
        #expect(try await check.isDuplicate(source: missing, named: "a.txt", in: store.root) == false)
    }

    @Test("A same-named item whose opened file does not exist is not a duplicate and does not throw")
    func unreadableExistingFileIsNotDuplicate() async throws {
        let store = try DiskBackedVaultStore(encrypted: true)
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("a.txt", content: "hello")
        let file = try source.file("a.txt", content: "hello")
        store.overrideOpen(with: source.url.appendingPathComponent("nonexistent-opened.txt"))
        let check = DuplicateCheck(store: store)
        #expect(try await check.isDuplicate(source: file, named: "a.txt", in: store.root) == false)
        #expect(store.leftoverTempFiles.isEmpty)
    }

    @Test("A folder given as the source is not a duplicate and does not throw")
    func directorySourceIsNotDuplicate() async throws {
        let store = try DiskBackedVaultStore(encrypted: true)
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("a.txt", content: "hello")
        let folder = try source.folder("a.txt")
        let check = DuplicateCheck(store: store)
        #expect(try await check.isDuplicate(source: folder, named: "a.txt", in: store.root) == false)
        #expect(store.leftoverTempFiles.isEmpty)
    }

    @Test("A folder as the existing file's opened URL is not a duplicate and does not throw")
    func directoryOpenedUrlIsNotDuplicate() async throws {
        let store = try DiskBackedVaultStore(encrypted: true)
        let source = try SourceFolder()
        defer { store.cleanup(); source.cleanup() }
        try store.seed("a.txt", content: "hello")
        let file = try source.file("a.txt", content: "hello")
        let folder = try source.folder("opened-folder")
        store.overrideOpen(with: folder)
        let check = DuplicateCheck(store: store)
        #expect(try await check.isDuplicate(source: file, named: "a.txt", in: store.root) == false)
        #expect(store.leftoverTempFiles.isEmpty)
    }
}
