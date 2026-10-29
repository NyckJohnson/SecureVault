//
//  FileImportLimitTests.swift
//  KoalaTVault
//

import XCTest
@testable import KoalaTVault

@MainActor
final class FileImportLimitTests: XCTestCase {

    private var harness: LegacyVaultHarness!
    private var proUnlock: MockProUnlocking!
    private var transfers: FileSystem!

    override func setUp() async throws {
        try await super.setUp()
        harness = try LegacyVaultHarness()
        proUnlock = MockProUnlocking(isUnlocked: false)
        transfers = harness.transfers(proUnlock: proUnlock)
    }

    override func tearDown() async throws {
        harness.cleanUp()
        harness = nil
        proUnlock = nil
        transfers = nil
        try await super.tearDown()
    }

    // MARK: - Helpers
    /// Writes `count` plain files directly into the directory, bypassing importItems
    /// so seeding doesn't depend on the import/encryption pipeline under test.
    private func seedFiles(count: Int, in directory: VaultDirectory) throws {
        for i in 0..<count {
            try harness.diskFile("seed-\(i).txt", "seed", in: directory)
        }
    }

    private func assertFileLimitReached(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case ImportError.fileLimitReached = error else {
            XCTFail("Expected ImportError.fileLimitReached, got \(error)", file: file, line: line)
            return
        }
    }

    private func overflowSource() throws -> URL {
        try harness.source("overflow.txt", "overflow")
    }

    // MARK: - checkImportAllowed
    func testCheckImportAllowedPassesUnderLimit() async throws {
        try seedFiles(count: 5, in: harness.root)
        try await transfers.checkImportAllowed(additionalCount: 10)
    }

    func testCheckImportAllowedThrowsWhenOverLimit() async throws {
        try seedFiles(count: ProUnlock.freeFileLimit, in: harness.root)
        do {
            try await transfers.checkImportAllowed(additionalCount: 1)
            XCTFail("expected checkImportAllowed to throw")
        } catch {
            assertFileLimitReached(error)
        }
    }

    func testCheckImportAllowedAllowsExactlyUpToLimit() async throws {
        try seedFiles(count: ProUnlock.freeFileLimit - 1, in: harness.root)
        try await transfers.checkImportAllowed(additionalCount: 1)
    }

    func testCheckImportAllowedPassesWhenUnlockedRegardlessOfCount() async throws {
        proUnlock.isUnlocked = true
        try seedFiles(count: ProUnlock.freeFileLimit, in: harness.root)
        try await transfers.checkImportAllowed(additionalCount: 50)
    }

    // MARK: - importItems
    func testImportItemsThrowsAndImportsNothingWhenOverLimit() async throws {
        try seedFiles(count: ProUnlock.freeFileLimit, in: harness.root)
        let sourceURL = try overflowSource()

        do {
            try await transfers.importItems(from: [sourceURL], to: harness.root)
            XCTFail("expected importItems to throw")
        } catch {
            assertFileLimitReached(error)
        }

        let contents = try await harness.items()
        XCTAssertEqual(contents.count, ProUnlock.freeFileLimit)
        XCTAssertFalse(contents.contains { $0.name == "overflow.txt" })
    }

    func testImportItemsSucceedsWhenUnlockedBeyondLimit() async throws {
        proUnlock.isUnlocked = true
        try seedFiles(count: ProUnlock.freeFileLimit, in: harness.root)
        let sourceURL = try overflowSource()

        try await transfers.importItems(from: [sourceURL], to: harness.root)

        let contents = try await harness.items()
        XCTAssertEqual(contents.count, ProUnlock.freeFileLimit + 1)
        XCTAssertTrue(contents.contains { $0.name == "overflow.txt" })
    }

    func testImportItemsCountsAcrossSubfolders() async throws {
        let subFolder = try await harness.folder("Sub")
        try seedFiles(count: ProUnlock.freeFileLimit, in: subFolder)
        let sourceURL = try overflowSource()

        // Importing into the root should still see the subfolder's files, since both
        // share the same rootURL for this vault.
        do {
            try await transfers.importItems(from: [sourceURL], to: harness.root)
            XCTFail("expected importItems to throw")
        } catch {
            assertFileLimitReached(error)
        }
    }
}
