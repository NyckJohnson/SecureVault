import XCTest
@testable import SecureVault

final class ExportServiceTests: VaultTestCase {

    // MARK: - Prepare For Export (Unencrypted)
    func testPrepareForExportReturnsOriginalURLForUnencryptedFile() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let exportURLs = try FileSystem.shared.prepareForExport([item])

        XCTAssertEqual(exportURLs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURLs[0].path))
    }

    func testPrepareForExportMultipleUnencryptedFiles() throws {
        let url1 = FileManager.default.temporaryDirectory.appendingPathComponent("file1.txt")
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("file2.txt")
        try "hello".write(to: url1, atomically: true, encoding: .utf8)
        try "world".write(to: url2, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        try FileSystem.shared.importItems(from: [url1, url2], to: testDirectory)
        let items = try FileSystem.shared.contents(of: testDirectory)
        let exportURLs = try FileSystem.shared.prepareForExport(items)

        XCTAssertEqual(exportURLs.count, 2)
        XCTAssertTrue(exportURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    // MARK: - Prepare For Export (Encrypted)
    func testPrepareForExportDecryptsEncryptedFile() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "secret content"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        XCTAssertTrue(item.isEncrypted)

        let exportURLs = try FileSystem.shared.prepareForExport([item])
        XCTAssertEqual(exportURLs.count, 1)

        let exportedContent = try String(contentsOf: exportURLs[0], encoding: .utf8)
        XCTAssertEqual(exportedContent, content)
    }

    func testPrepareForExportEncryptedFileHasOriginalName() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("myfile.txt")
        try "content".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let exportURLs = try FileSystem.shared.prepareForExport([item])

        XCTAssertEqual(exportURLs[0].lastPathComponent, "myfile.txt")
    }

    func testPrepareForExportEncryptedFileWithNoKeyThrows() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "content".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!

        CryptoService.shared.wipeKey()
        XCTAssertThrowsError(try FileSystem.shared.prepareForExport([item]))
    }

    func testPrepareForExportEmptyArrayReturnsEmpty() throws {
        let exportURLs = try FileSystem.shared.prepareForExport([])
        XCTAssertTrue(exportURLs.isEmpty)
    }

    // MARK: - Cleanup
    func testCleanupTempFilesRemovesExportedFiles() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "content".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let exportURLs = try FileSystem.shared.prepareForExport([item])

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURLs[0].path))
        FileSystem.shared.cleanupTempFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURLs[0].path))
    }
}
