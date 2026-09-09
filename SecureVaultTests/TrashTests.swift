import XCTest
@testable import SecureVault

final class TrashTests: XCTestCase {

    var testDirectory: VaultDirectory!

    override func setUp() {
        super.setUp()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        testDirectory = VaultDirectory(name: "test", diskURL: tempURL)
        // clean trash before each test
        try? FileSystem.shared.emptyTrash()
    }

    override func tearDown() {
        super.tearDown()
        CryptoService.shared.wipeKey()
        try? FileManager.default.removeItem(at: testDirectory.diskURL)
        try? FileSystem.shared.emptyTrash()
        FileSystem.shared.cleanupTempFiles()
    }

    // MARK: - Move To Trash
    func testMoveToTrashRemovesFromSource() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents.isEmpty)
    }

    func testMoveToTrashAppearsInTrash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let trash = FileSystem.shared.contentsOfTrash()
        XCTAssertEqual(trash.count, 1)
        XCTAssertEqual(trash.first?.name, "test.txt")
    }

    func testMoveMultipleFilesToTrash() throws {
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
        for item in items { try FileSystem.shared.delete(item) }

        let trash = FileSystem.shared.contentsOfTrash()
        XCTAssertEqual(trash.count, 2)
    }

    func testTrashPreservesFileName() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myfile.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let trash = FileSystem.shared.contentsOfTrash()
        XCTAssertEqual(trash.first?.name, "myfile.txt")
    }

    // MARK: - Restore From Trash
    func testRestoreFromTrashAppearsInBrowser() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let trashItem = FileSystem.shared.contentsOfTrash().first!
        try FileSystem.shared.restoreFromTrash(trashItem)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?.name, "test.txt")
    }

    func testRestoreFromTrashRemovesFromTrash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let trashItem = FileSystem.shared.contentsOfTrash().first!
        try FileSystem.shared.restoreFromTrash(trashItem)

        let trash = FileSystem.shared.contentsOfTrash()
        XCTAssertTrue(trash.isEmpty)
    }

    func testRestorePreservesContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "preserved content"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let trashItem = FileSystem.shared.contentsOfTrash().first!
        try FileSystem.shared.restoreFromTrash(trashItem)

        let restored = try FileSystem.shared.contents(of: testDirectory).first!
        let readContent = try String(contentsOf: restored.diskURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    // MARK: - Permanently Delete
    func testPermanentlyDeleteRemovesFromTrash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let trashItem = FileSystem.shared.contentsOfTrash().first!
        try FileSystem.shared.permanentlyDelete(trashItem)

        let trash = FileSystem.shared.contentsOfTrash()
        XCTAssertTrue(trash.isEmpty)
    }

    func testPermanentlyDeleteRemovesFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let trashItem = FileSystem.shared.contentsOfTrash().first!
        let diskURL = trashItem.diskURL
        try FileSystem.shared.permanentlyDelete(trashItem)

        XCTAssertFalse(FileManager.default.fileExists(atPath: diskURL.path))
    }

    // MARK: - Empty Trash
    func testEmptyTrashClearsAllItems() throws {
        let url1 = FileManager.default.temporaryDirectory.appendingPathComponent("file1.txt")
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("file2.txt")
        try "a".write(to: url1, atomically: true, encoding: .utf8)
        try "b".write(to: url2, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        try FileSystem.shared.importItems(from: [url1, url2], to: testDirectory)
        let items = try FileSystem.shared.contents(of: testDirectory)
        for item in items { try FileSystem.shared.delete(item) }

        try FileSystem.shared.emptyTrash()
        let trash = FileSystem.shared.contentsOfTrash()
        XCTAssertTrue(trash.isEmpty)
    }

    // MARK: - Cleanup Expired
    func testCleanupExpiredDoesNotRemoveRecentItems() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        FileSystem.shared.cleanupExpiredTrashItems()

        let trash = FileSystem.shared.contentsOfTrash()
        XCTAssertEqual(trash.count, 1)
    }

    // MARK: - Encrypted Trash
    func testEncryptedFileMoveToTrash() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "secret".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        XCTAssertTrue(item.isEncrypted)
        try FileSystem.shared.delete(item)

        let trash = FileSystem.shared.contentsOfTrash()
        XCTAssertEqual(trash.count, 1)
        XCTAssertEqual(trash.first?.name, "test.txt")
    }

    func testEncryptedFileRestoreFromTrash() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "secret content".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        XCTAssertEqual(FileSystem.shared.contentsOfTrash().count, 1)

        let trashItem = FileSystem.shared.contentsOfTrash().first!
        try FileSystem.shared.restoreFromTrash(trashItem)

        let restored = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.name, "test.txt")
        XCTAssertTrue(FileSystem.shared.contentsOfTrash().isEmpty)
    }
}
