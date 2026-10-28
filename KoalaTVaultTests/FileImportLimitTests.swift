//
//  FileImportLimitTests.swift
//  KoalaTVault
//

import XCTest
@testable import KoalaTVault

final class FileImportLimitTests: VaultTestCase {

    private var originalProUnlock: (any ProUnlocking)?
    private var proUnlock: MockProUnlocking!

    override func setUp() {
        super.setUp()
        originalProUnlock = LegacyStorage.current.proUnlockSlot.installed
        proUnlock = MainActor.assumeIsolated { MockProUnlocking(isUnlocked: false) }
        LegacyStorage.current.proUnlockSlot.install(proUnlock)
    }

    override func tearDown() {
        if let originalProUnlock { LegacyStorage.current.proUnlockSlot.install(originalProUnlock) }
        proUnlock = nil
        originalProUnlock = nil
        super.tearDown()
    }

    // MARK: - Helpers
    /// Writes `count` plain files directly into the directory, bypassing importItems
    /// so seeding doesn't depend on the import/encryption pipeline under test.
    private func seedFiles(count: Int, in directory: LegacyVaultDirectory) throws {
        for i in 0..<count {
            let url = directory.diskURL.appendingPathComponent("seed-\(i).txt")
            try "seed".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func assertFileLimitReached(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case FileSystemError.fileLimitReached = error else {
            XCTFail("Expected FileSystemError.fileLimitReached, got \(error)", file: file, line: line)
            return
        }
    }

    // MARK: - checkImportAllowed
    func testCheckImportAllowedPassesUnderLimit() throws {
        try seedFiles(count: 5, in: testDirectory)
        XCTAssertNoThrow(try FileSystem.shared.checkImportAllowed(additionalCount: 10, in: testDirectory))
    }

    func testCheckImportAllowedThrowsWhenOverLimit() throws {
        try seedFiles(count: ProUnlock.freeFileLimit, in: testDirectory)
        XCTAssertThrowsError(try FileSystem.shared.checkImportAllowed(additionalCount: 1, in: testDirectory)) {
            assertFileLimitReached($0)
        }
    }

    func testCheckImportAllowedAllowsExactlyUpToLimit() throws {
        try seedFiles(count: ProUnlock.freeFileLimit - 1, in: testDirectory)
        XCTAssertNoThrow(try FileSystem.shared.checkImportAllowed(additionalCount: 1, in: testDirectory))
    }

    func testCheckImportAllowedPassesWhenUnlockedRegardlessOfCount() throws {
        MainActor.assumeIsolated { proUnlock.isUnlocked = true }
        try seedFiles(count: ProUnlock.freeFileLimit, in: testDirectory)
        XCTAssertNoThrow(try FileSystem.shared.checkImportAllowed(additionalCount: 50, in: testDirectory))
    }

    // MARK: - importItems
    func testImportItemsThrowsAndImportsNothingWhenOverLimit() throws {
        try seedFiles(count: ProUnlock.freeFileLimit, in: testDirectory)

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("overflow.txt")
        try "overflow".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        XCTAssertThrowsError(try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)) {
            assertFileLimitReached($0)
        }

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, ProUnlock.freeFileLimit)
        XCTAssertFalse(contents.contains { $0.name == "overflow.txt" })
    }

    func testImportItemsSucceedsWhenUnlockedBeyondLimit() throws {
        MainActor.assumeIsolated { proUnlock.isUnlocked = true }
        try seedFiles(count: ProUnlock.freeFileLimit, in: testDirectory)

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("overflow.txt")
        try "overflow".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, ProUnlock.freeFileLimit + 1)
        XCTAssertTrue(contents.contains { $0.name == "overflow.txt" })
    }

    func testImportItemsCountsAcrossSubfolders() throws {
        let subFolder = try FileSystem.shared.createFolder(named: "Sub", in: testDirectory)
        try seedFiles(count: ProUnlock.freeFileLimit, in: subFolder)

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("overflow.txt")
        try "overflow".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        // Importing into the root should still see the subfolder's files, since both
        // share the same rootURL for this vault.
        XCTAssertThrowsError(try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)) {
            assertFileLimitReached($0)
        }
    }
}
