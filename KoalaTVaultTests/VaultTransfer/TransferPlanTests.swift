import Foundation
import Testing

@testable import KoalaTVault

/// The planning rules of a transfer (file counting, the free-tier limit, same-vault check), observed through
/// `LiveVaultTransfer.transfer`.
@MainActor
@Suite struct TransferPlanTests {
    private func run(
        _ fixture: TransferFixture, ids: [String], pro: Bool, removing: Bool = false
    ) async throws -> TransferResult {
        let items = try ids.map { try #require(fixture.source.item($0)) }
        return try await makeTransfer(pro: pro).transfer(
            items, from: fixture.source, to: fixture.target, removingOriginals: removing,
            progress: { _, _ in })
    }

    private func assertNothingWritten(_ fixture: TransferFixture) {
        let writes = fixture.log.events.filter {
            $0.hasPrefix("tgt.addFile") || $0.hasPrefix("tgt.createFolder") || $0.hasPrefix("src.remove:")
        }
        #expect(writes.isEmpty)
    }

    @Test("A single file counts as one: 99 files in the target plus one file is allowed")
    func fileCountsAsOne() async throws {
        let fixture = TransferFixture()
        try await fixture.target.fill(99)
        let result = try await run(fixture, ids: ["Beach.jpg"], pro: false)
        #expect(result == TransferResult(done: 1, failed: 0))
    }

    @Test("Exactly 100 files in the target after the transfer is allowed without Pro")
    func exactlyOneHundredIsAllowed() async throws {
        let fixture = TransferFixture()
        try await fixture.target.fill(98)
        let result = try await run(fixture, ids: ["Beach.jpg", "Holiday.mov"], pro: false)
        #expect(result == TransferResult(done: 2, failed: 0))
        #expect(try await fixture.target.countFiles() == 100)
    }

    @Test("101 files in the target after the transfer throws limitReached without Pro")
    func oneOverTheLimitThrows() async throws {
        let fixture = TransferFixture()
        try await fixture.target.fill(100)
        await #expect(throws: VaultTransferError.limitReached) {
            _ = try await run(fixture, ids: ["Beach.jpg"], pro: false)
        }
    }

    @Test("The limit counts the items' files together with the target's existing files")
    func limitSumsAllItems() async throws {
        let fixture = TransferFixture()
        try await fixture.target.fill(98)
        await #expect(throws: VaultTransferError.limitReached) {
            _ = try await run(fixture, ids: ["Beach.jpg", "Holiday.mov", "Notes.rtf"], pro: false)
        }
    }

    @Test("A folder counts as every file in its tree: 98 plus a two-file folder is allowed")
    func folderCountsItsFilesAllowed() async throws {
        let fixture = TransferFixture()
        try await fixture.target.fill(98)
        let result = try await run(fixture, ids: ["Photos"], pro: false)
        #expect(result == TransferResult(done: 1, failed: 0))
    }

    @Test("A folder counts as every file in its tree: 99 plus a two-file folder throws limitReached")
    func folderCountsItsFilesLimit() async throws {
        let fixture = TransferFixture()
        try await fixture.target.fill(99)
        await #expect(throws: VaultTransferError.limitReached) {
            _ = try await run(fixture, ids: ["Photos"], pro: false)
        }
    }

    @Test("Files in nested folders count toward the limit")
    func nestedFilesCount() async throws {
        let fixture = TransferFixture()
        let photos = try #require(fixture.source.item("Photos")?.asDirectory)
        let deep = try await fixture.source.inner.createFolder(named: "Deep", in: photos)
        let deepDirectory = try #require(deep.asDirectory)
        _ = try await fixture.source.inner.addFile(
            from: URL(fileURLWithPath: "/dev/null"), named: "Nested.txt", to: deepDirectory)
        try await fixture.target.fill(98)  // Photos now holds 3 files
        await #expect(throws: VaultTransferError.limitReached) {
            _ = try await run(fixture, ids: ["Photos"], pro: false)
        }
    }

    @Test("An empty folder adds no files to the count")
    func emptyFolderCountsZero() async throws {
        let fixture = TransferFixture()
        try await fixture.target.fill(100)
        let result = try await run(fixture, ids: ["Documents"], pro: false)
        #expect(result == TransferResult(done: 1, failed: 0))
    }

    @Test("limitReached is thrown before anything is written or removed")
    func limitWritesNothing() async throws {
        let fixture = TransferFixture()
        try await fixture.target.fill(99)
        await #expect(throws: VaultTransferError.limitReached) {
            _ = try await run(fixture, ids: ["Beach.jpg", "Holiday.mov"], pro: false, removing: true)
        }
        assertNothingWritten(fixture)
        #expect(fixture.source.item("Beach.jpg") != nil)
        #expect(fixture.source.item("Holiday.mov") != nil)
    }

    @Test("With Pro there is no limit")
    func proHasNoLimit() async throws {
        let fixture = TransferFixture()
        try await fixture.target.fill(150)
        let result = try await run(fixture, ids: ["Beach.jpg", "Photos"], pro: true)
        #expect(result == TransferResult(done: 2, failed: 0))
        #expect(try await fixture.target.countFiles() == 153)
    }

    @Test("Source and target with the same root throw sameVault")
    func sameRootThrowsSameVault() async throws {
        let fixture = TransferFixture(targetName: "Source")
        #expect(fixture.source.root == fixture.target.root)
        await #expect(throws: VaultTransferError.sameVault) {
            _ = try await run(fixture, ids: ["Beach.jpg"], pro: false)
        }
        assertNothingWritten(fixture)
    }

    @Test("sameVault is thrown even with Pro and when moving")
    func sameVaultWithProAndMove() async throws {
        let fixture = TransferFixture(targetName: "Source")
        await #expect(throws: VaultTransferError.sameVault) {
            _ = try await run(fixture, ids: ["Beach.jpg"], pro: true, removing: true)
        }
        assertNothingWritten(fixture)
        #expect(fixture.source.item("Beach.jpg") != nil)
    }
}
