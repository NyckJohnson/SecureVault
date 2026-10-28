import XCTest
@testable import KoalaTVault

@MainActor
final class ExportServiceTests: XCTestCase {

    private var harness: LegacyVaultHarness!
    private var transfers: FileSystem!

    override func setUp() async throws {
        try await super.setUp()
        harness = try LegacyVaultHarness()
        transfers = harness.transfers(proUnlock: MockProUnlocking(isUnlocked: true))
    }

    override func tearDown() async throws {
        harness.cleanUp()
        harness = nil
        transfers = nil
        try await super.tearDown()
    }

    /// Turns the lock on: a key exists and the store is in encrypted mode.
    private func lockVault() throws {
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        harness.preferences.lockMode = .password
    }

    // MARK: - Prepare For Export (Unencrypted)
    func testPrepareForExportReturnsOriginalURLForUnencryptedFile() async throws {
        try await transfers.importItems(from: [try harness.source("test.txt", "hello")], to: harness.root)
        let listed = try await harness.items().first
        let item = try XCTUnwrap(listed)
        let exportURLs = try await transfers.prepareForExport([item]).urls

        XCTAssertEqual(exportURLs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURLs[0].path))
    }

    func testPrepareForExportMultipleUnencryptedFiles() async throws {
        let url1 = try harness.source("file1.txt", "hello")
        let url2 = try harness.source("file2.txt", "world")
        try await transfers.importItems(from: [url1, url2], to: harness.root)
        let items = try await harness.items()
        let exportURLs = try await transfers.prepareForExport(items).urls

        XCTAssertEqual(exportURLs.count, 2)
        XCTAssertTrue(exportURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    // MARK: - Prepare For Export (Encrypted)
    func testPrepareForExportDecryptsEncryptedFile() async throws {
        try lockVault()
        let content = "secret content"
        try await transfers.importItems(from: [try harness.source("test.txt", content)], to: harness.root)
        let listed = try await harness.items().first
        let item = try XCTUnwrap(listed)
        XCTAssertTrue(item.isEncrypted)

        let exportURLs = try await transfers.prepareForExport([item]).urls
        XCTAssertEqual(exportURLs.count, 1)

        let exportedContent = try String(contentsOf: exportURLs[0], encoding: .utf8)
        XCTAssertEqual(exportedContent, content)
    }

    func testPrepareForExportEncryptedFileHasOriginalName() async throws {
        try lockVault()
        try await transfers.importItems(from: [try harness.source("myfile.txt", "content")], to: harness.root)
        let listed = try await harness.items().first
        let item = try XCTUnwrap(listed)
        let exportURLs = try await transfers.prepareForExport([item]).urls

        XCTAssertEqual(exportURLs[0].lastPathComponent, "myfile.txt")
    }

    func testPrepareForExportEncryptedFileWithNoKeyThrows() async throws {
        try lockVault()
        try await transfers.importItems(from: [try harness.source("test.txt", "content")], to: harness.root)
        let listed = try await harness.items().first
        let item = try XCTUnwrap(listed)

        TestCrypto.keyStore.wipeKey()
        do {
            _ = try await transfers.prepareForExport([item])
            XCTFail("expected prepareForExport to throw")
        } catch {
            XCTAssertEqual(error as? VaultStoreError, .locked)
        }
    }

    func testPrepareForExportEmptyArrayReturnsEmpty() async throws {
        let files = try await transfers.prepareForExport([])
        XCTAssertTrue(files.urls.isEmpty)
        XCTAssertTrue(files.temporaryFolders.isEmpty)
    }

    // MARK: - Cleanup
    func testCleanupTempFilesRemovesExportedFiles() async throws {
        try lockVault()
        try await transfers.importItems(from: [try harness.source("test.txt", "content")], to: harness.root)
        let listed = try await harness.items().first
        let item = try XCTUnwrap(listed)
        let exportURLs = try await transfers.prepareForExport([item]).urls

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURLs[0].path))
        harness.store.removeAllTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURLs[0].path))
    }
}
