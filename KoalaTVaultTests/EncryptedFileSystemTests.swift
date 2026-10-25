import XCTest
@testable import KoalaTVault

final class EncryptedFileSystemTests: VaultTestCase {

    override func setUp() {
        try? CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        super.setUp()
    }

    // MARK: - Encrypted Import
    func testImportFileCreatesEncryptedVersion() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello world".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)

        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?.name, "test.txt")
        XCTAssertTrue(contents.first?.isEncrypted == true)
    }

    func testEncryptedFileHasUUIDDiskName() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        let diskName = contents.first?.diskURL.lastPathComponent ?? ""

        // disk name should be UUID, not original name
        XCTAssertNotEqual(diskName, "test.txt")
        XCTAssertEqual(diskName.count, 36) // UUID length
    }

    func testEncryptedFileOpenReturnsCorrectContent() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "hello encrypted world"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let openedURL = try FileSystem.shared.open(item)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    func testEncryptedFileOnDiskIsUnreadable() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "sensitive content"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let diskData = try Data(contentsOf: item.diskURL)
        XCTAssertFalse(diskData.contains(content.data(using: .utf8)!))
    }

    // MARK: - Encrypted Rename
    func testRenameEncryptedFile() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.rename(item, to: "renamed.txt")

        let afterRename = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(afterRename.first?.name, "renamed.txt")
        XCTAssertTrue(afterRename.first?.isEncrypted == true)
    }

    func testRenameEncryptedFilePreservesContent() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "preserved content"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.rename(item, to: "renamed.txt")

        let renamedItem = try FileSystem.shared.contents(of: testDirectory).first!
        let openedURL = try FileSystem.shared.open(renamedItem)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    // MARK: - Encrypted Move
    func testMoveEncryptedFile() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let subFolder = try FileSystem.shared.createFolder(named: "SubFolder", in: testDirectory)
        let file = try FileSystem.shared.contents(of: testDirectory).first { !$0.isDirectory }!
        try FileSystem.shared.move(file, to: subFolder)

        let rootContents = try FileSystem.shared.contents(of: testDirectory)
        let subContents = try FileSystem.shared.contents(of: subFolder)
        XCTAssertFalse(rootContents.contains { $0.name == "test.txt" })
        XCTAssertTrue(subContents.contains { $0.name == "test.txt" })
        XCTAssertTrue(subContents.first?.isEncrypted == true)
    }

    func testMoveEncryptedFilePreservesContent() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "moved content"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let subFolder = try FileSystem.shared.createFolder(named: "SubFolder", in: testDirectory)
        let file = try FileSystem.shared.contents(of: testDirectory).first { !$0.isDirectory }!
        try FileSystem.shared.move(file, to: subFolder)

        let movedItem = try FileSystem.shared.contents(of: subFolder).first!
        let openedURL = try FileSystem.shared.open(movedItem)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    // MARK: - Encrypted Delete
    func testDeleteEncryptedFileRemovesFromMapping() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let afterDelete = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(afterDelete.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.diskURL.path))
    }

    // MARK: - Write
    func testWriteEncryptedFileUpdatesContent() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "original".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let newContent = "updated encrypted content"
        try FileSystem.shared.write(data: newContent.data(using: .utf8)!, to: item)

        let openedURL = try FileSystem.shared.open(item)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, newContent)
    }

    // MARK: - No Key
    func testOpenEncryptedFileWithNoKeyThrows() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        CryptoService.shared.wipeKey()
        XCTAssertThrowsError(try FileSystem.shared.open(item))
    }

    // MARK: - createDocument (baseline fix 13)
    func testCreateDocumentUnderKeyWritesUUIDNamedSVC5FileAndMapEntry() throws {
        let item = try FileSystem.shared.createDocument(named: "notes", in: testDirectory)

        XCTAssertEqual(item.name, "notes.rtf")
        XCTAssertTrue(item.isEncrypted)
        let diskName = item.diskURL.lastPathComponent
        XCTAssertNotNil(UUID(uuidString: diskName))
        let bytes = try Data(contentsOf: item.diskURL)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x53, 0x56, 0x43, 0x35], "File starts with the SVC5 magic")
        XCTAssertEqual(try FileSystem.shared.testMapping(in: testDirectory)[diskName]?.originalName, "notes.rtf")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: testDirectory.diskURL.appendingPathComponent("notes.rtf").path))
        XCTAssertEqual(try FileSystem.shared.contents(of: testDirectory).map(\.name), ["notes.rtf"])
    }

    func testCreateDocumentWithSameNameUnderKeyGetsNumberSuffix() throws {
        _ = try FileSystem.shared.createDocument(named: "notes", in: testDirectory)
        let second = try FileSystem.shared.createDocument(named: "notes", in: testDirectory)

        XCTAssertEqual(second.name, "notes 1.rtf")
        XCTAssertEqual(Set(try FileSystem.shared.contents(of: testDirectory).map(\.name)),
                       ["notes.rtf", "notes 1.rtf"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: testDirectory.diskURL.appendingPathComponent("notes.rtf").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: testDirectory.diskURL.appendingPathComponent("notes 1.rtf").path))
    }

    func testCreateDocumentWithoutLockNeverTruncatesExistingDocument() throws {
        CryptoService.shared.wipeKey()
        try? CryptoService.shared.wipeMasterKeyBlob()
        let existing = testDirectory.diskURL.appendingPathComponent("notes.rtf")
        try "precious".write(to: existing, atomically: true, encoding: .utf8)

        let created = try FileSystem.shared.createDocument(named: "notes", in: testDirectory)

        XCTAssertEqual(created.name, "notes 1.rtf")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "precious")
    }
}
