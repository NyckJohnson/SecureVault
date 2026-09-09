import XCTest
@testable import SecureVault

final class AdditionalEdgeCaseTests: XCTestCase {

    var testDirectory: VaultDirectory!

    override func setUp() {
        super.setUp()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        testDirectory = VaultDirectory(name: "test", diskURL: tempURL)
        try? FileSystem.shared.emptyTrash()
    }

    override func tearDown() {
        super.tearDown()
        CryptoService.shared.wipeKey()
        try? FileManager.default.removeItem(at: testDirectory.diskURL)
        try? FileSystem.shared.emptyTrash()
        FileSystem.shared.cleanupTempFiles()
    }

    // MARK: - Folder Import Conflicts
    func testImportFolderWithConflictingName() throws {
        // create folder with same name first
        _ = try FileSystem.shared.createFolder(named: "TestFolder", in: testDirectory)

        // create temp folder to import
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("TestFolder")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileURL = folderURL.appendingPathComponent("file.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        try FileSystem.shared.importItems(from: [folderURL], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.filter { $0.isDirectory }.count, 2)
        XCTAssertTrue(contents.contains { $0.name == "TestFolder" })
        XCTAssertTrue(contents.contains { $0.name == "TestFolder 1" })
    }

    func testImportMultipleFoldersWithSameName() throws {
        let folder1URL = FileManager.default.temporaryDirectory.appendingPathComponent("MyFolder")
        let folder2URL = FileManager.default.temporaryDirectory.appendingPathComponent("MyFolder")
        try FileManager.default.createDirectory(at: folder1URL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder1URL) }

        try FileSystem.shared.importItems(from: [folder1URL], to: testDirectory)
        try FileSystem.shared.importItems(from: [folder2URL], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.filter { $0.isDirectory }.count, 2)
    }

    // MARK: - Copy Encrypted To Different Folder
    func testCopyEncryptedFileToSubfolder() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "encrypted copy to subfolder"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let subFolder = try FileSystem.shared.createFolder(named: "SubFolder", in: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first { !$0.isDirectory }!
        try FileSystem.shared.copy(item, to: subFolder)

        // verify in both locations
        let rootContents = try FileSystem.shared.contents(of: testDirectory)
        let subContents = try FileSystem.shared.contents(of: subFolder)
        XCTAssertTrue(rootContents.contains { $0.name == "test.txt" })
        XCTAssertTrue(subContents.contains { $0.name == "test.txt" })
        XCTAssertTrue(subContents.first?.isEncrypted == true)

        // verify content preserved
        let copy = subContents.first!
        let openedURL = try FileSystem.shared.open(copy)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    // MARK: - Move Encrypted Then Verify Content
    func testMoveEncryptedFileThenVerifyContent() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "content after move"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let subFolder = try FileSystem.shared.createFolder(named: "SubFolder", in: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first { !$0.isDirectory }!
        try FileSystem.shared.move(item, to: subFolder)

        let subContents = try FileSystem.shared.contents(of: subFolder)
        XCTAssertEqual(subContents.count, 1)
        XCTAssertTrue(subContents.first?.isEncrypted == true)

        let movedItem = subContents.first!
        let openedURL = try FileSystem.shared.open(movedItem)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    // MARK: - Special Characters In File Names
    func testImportFileWithSpecialCharacters() throws {
        let name = "file with spaces & symbols!.txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.first?.name, name)
    }

    func testRenameToNameWithSpecialCharacters() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let newName = "renamed with spaces & symbols!.txt"
        try FileSystem.shared.rename(item, to: newName)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.first?.name, newName)
    }

    // MARK: - Multiple Operations In Sequence
    func testImportRenameMoveDelete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // import
        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        var item = try FileSystem.shared.contents(of: testDirectory).first!

        // rename
        try FileSystem.shared.rename(item, to: "renamed.txt")
        item = try FileSystem.shared.contents(of: testDirectory).first!
        XCTAssertEqual(item.name, "renamed.txt")

        // move to subfolder
        let subFolder = try FileSystem.shared.createFolder(named: "Sub", in: testDirectory)
        try FileSystem.shared.move(item, to: subFolder)
        var subContents = try FileSystem.shared.contents(of: subFolder)
        XCTAssertEqual(subContents.count, 1)

        // delete
        try FileSystem.shared.delete(subContents.first!)
        subContents = try FileSystem.shared.contents(of: subFolder)
        XCTAssertTrue(subContents.isEmpty)

        // verify in trash
        let trash = FileSystem.shared.contentsOfTrash()
        XCTAssertEqual(trash.first?.name, "renamed.txt")
    }

    func testEncryptedImportRenameMoveDelete() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "sequential ops content"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // import encrypted
        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        var item = try FileSystem.shared.contents(of: testDirectory).first!
        XCTAssertTrue(item.isEncrypted)

        // rename
        try FileSystem.shared.rename(item, to: "renamed.txt")
        item = try FileSystem.shared.contents(of: testDirectory).first!
        XCTAssertEqual(item.name, "renamed.txt")
        XCTAssertTrue(item.isEncrypted)

        // verify content still readable after rename
        let urlAfterRename = try FileSystem.shared.open(item)
        XCTAssertEqual(try String(contentsOf: urlAfterRename, encoding: .utf8), content)

        // move
        let subFolder = try FileSystem.shared.createFolder(named: "Sub", in: testDirectory)
        try FileSystem.shared.move(item, to: subFolder)
        let subContents = try FileSystem.shared.contents(of: subFolder)
        XCTAssertEqual(subContents.count, 1)
        XCTAssertTrue(subContents.first?.isEncrypted == true)

        // verify content still readable after move
        let urlAfterMove = try FileSystem.shared.open(subContents.first!)
        XCTAssertEqual(try String(contentsOf: urlAfterMove, encoding: .utf8), content)

        // delete
        try FileSystem.shared.delete(subContents.first!)
        let trash = FileSystem.shared.contentsOfTrash()
        XCTAssertEqual(trash.first?.name, "renamed.txt")
    }

    // MARK: - Large File
    func testImportLargeFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("large.txt")
        let content = String(repeating: "x", count: 1024 * 1024) // 1MB
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        XCTAssertEqual(item.name, "large.txt")
    }

    func testEncryptedLargeFile() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("large.txt")
        let content = String(repeating: "x", count: 1024 * 1024) // 1MB
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        XCTAssertTrue(item.isEncrypted)

        let openedURL = try FileSystem.shared.open(item)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }
}
