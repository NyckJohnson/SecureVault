import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct LiveVaultImporterEdgeTests {
    private typealias Fixture = ImporterTestFixture

    // MARK: Pending files are added before a failure is rethrown

    @Test("A failing lookup adds the loose files already waiting, then rethrows")
    func lookupFailureFlushesWaitingLooseFiles() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("dup.txt", content: "old")
        let a = try fixture.source.file("a.txt", content: "A")
        let b = try fixture.source.file("b.txt", content: "B")
        let dup = try fixture.source.file("dup.txt", content: "new")
        let later = try fixture.source.file("z.txt", content: "Z")
        fixture.store.failFindItem(with: VaultStoreError.io("lookup"))
        await #expect(throws: VaultStoreError.io("lookup")) {
            _ = try await fixture.importItems([a, b, dup, later])
        }
        #expect(fixture.store.readString("a.txt") == "A")
        #expect(fixture.store.readString("b.txt") == "B")
        #expect(fixture.store.readString("z.txt") == nil)
    }

    @Test("A failing lookup for a file inside a picked folder adds the folder's waiting files, then rethrows")
    func lookupFailureFlushesWaitingFolderFiles() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("Trip/dup.txt", content: "old")
        try fixture.source.file("Trip/a.txt", content: "A")
        try fixture.source.file("Trip/b.txt", content: "B")
        try fixture.source.file("Trip/dup.txt", content: "new")
        fixture.store.failFindItem(with: VaultStoreError.io("lookup"))
        await #expect(throws: VaultStoreError.io("lookup")) {
            _ = try await fixture.importItems([fixture.source.url.appendingPathComponent("Trip")])
        }
        #expect(fixture.store.readString("Trip/a.txt") == "A")
        #expect(fixture.store.readString("Trip/b.txt") == "B")
    }

    @Test("A failing listing of a merged folder adds the parent's waiting files, then rethrows")
    func listingFailureFlushesParentsWaitingFiles() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("Trip/old.txt", content: "old")
        let a = try fixture.source.file("a.txt", content: "A")
        let b = try fixture.source.file("b.txt", content: "B")
        try fixture.source.file("Trip/x.txt", content: "x")
        fixture.store.failContents(ofPath: "Trip", with: VaultStoreError.io("listing"))
        await #expect(throws: VaultStoreError.io("listing")) {
            _ = try await fixture.importItems([a, b, fixture.source.url.appendingPathComponent("Trip")])
        }
        #expect(fixture.store.readString("a.txt") == "A")
        #expect(fixture.store.readString("b.txt") == "B")
    }

    // MARK: Names and folders

    @Test("Two picked folders with the same new name merge: no ' 1' folder, both folders' files present")
    func sameNewFolderNamePickedTwiceMerges() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.source.file("one/Trip/x.txt", content: "x")
        try fixture.source.file("two/Trip/y.txt", content: "y")
        let result = try await fixture.importItems([
            fixture.source.url.appendingPathComponent("one/Trip"),
            fixture.source.url.appendingPathComponent("two/Trip"),
        ])
        #expect(result == ImportResult(imported: 2, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.allPaths() == ["Trip/", "Trip/x.txt", "Trip/y.txt"])
    }

    @Test("A loose file then a picked folder of the same name: the file is added first, the folder gets ' 1'")
    func looseFileThenFolderOfSameName() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let file = try fixture.source.file("Trip", content: "file")
        try fixture.source.file("dir/Trip/x.txt", content: "x")
        let result = try await fixture.importItems([file, fixture.source.url.appendingPathComponent("dir/Trip")])
        #expect(result == ImportResult(imported: 2, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.readString("Trip") == "file")
        #expect(fixture.store.readString("Trip 1/x.txt") == "x")
    }

    @Test("A file named like a folder this import created is not a duplicate and gets ' 1'")
    func fileNamedLikeCreatedFolderIsNotDuplicate() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.source.file("dir/Trip/x.txt", content: "x")
        let file = try fixture.source.file("Trip", content: "file")
        let result = try await fixture.importItems([fixture.source.url.appendingPathComponent("dir/Trip"), file])
        #expect(result == ImportResult(imported: 2, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.readString("Trip/x.txt") == "x")
        #expect(fixture.store.readString("Trip 1") == "file")
    }

    @Test("A name in different case is looked up (case-sensitively, finds nothing), is not a duplicate, and is added as given")
    func differentCaseNameIsLookedUpButNotADuplicate() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("photo.jpg", content: "same")
        let picked = try fixture.source.file("PHOTO.JPG", content: "same")
        let result = try await fixture.importItems([picked])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.findItemNames == ["PHOTO.JPG"])
        #expect(fixture.store.addedNames == ["PHOTO.JPG"])
    }

    @Test("A name the store gave on a clash counts as added: the same file picked under it is a duplicate")
    func storeGivenClashNameCountsAsAdded() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("a.txt", content: "old")
        let first = try fixture.source.file("one/a.txt", content: "new")
        let second = try fixture.source.file("two/a 1.txt", content: "new")
        let result = try await fixture.importItems([first, second])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 1, failed: 0))
        #expect(fixture.store.allPaths() == ["a 1.txt", "a.txt"])
        #expect(fixture.store.readString("a 1.txt") == "new")
    }

    @Test("A folder picked twice whose name belongs to a file merges into one ' 1' folder, never a ' 2'")
    func folderPickedTwiceWithFileNameMergesIntoOne() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("Trip", content: "file")
        try fixture.source.file("one/Trip/x.txt", content: "x")
        try fixture.source.file("two/Trip/y.txt", content: "y")
        let result = try await fixture.importItems([
            fixture.source.url.appendingPathComponent("one/Trip"),
            fixture.source.url.appendingPathComponent("two/Trip"),
        ])
        #expect(result == ImportResult(imported: 2, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.allPaths() == ["Trip", "Trip 1/", "Trip 1/x.txt", "Trip 1/y.txt"])
    }
}
