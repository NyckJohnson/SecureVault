import XCTest
@testable import KoalaTVault

final class CopyTests: VaultTestCase {

    // MARK: - Basic Copy
    func testCopyFileCreatesDuplicate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.copy(item, to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 2)
    }

    func testCopyFileKeepsOriginal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.copy(item, to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents.contains { $0.name == "test.txt" })
    }

    func testCopyFileResolvesNameConflict() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.copy(item, to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents.contains { $0.name == "test.txt" })
        XCTAssertTrue(contents.contains { $0.name == "test 1.txt" })
    }

    func testCopyFilePreservesContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "copy me"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.copy(item, to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        let copy = contents.first { $0.name == "test 1.txt" }!
        let readContent = try String(contentsOf: copy.diskURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    // MARK: - Copy To Different Folder
    func testCopyFileToSubfolder() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let subFolder = try FileSystem.shared.createFolder(named: "SubFolder", in: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first { !$0.isDirectory }!
        try FileSystem.shared.copy(item, to: subFolder)

        let rootContents = try FileSystem.shared.contents(of: testDirectory)
        let subContents = try FileSystem.shared.contents(of: subFolder)
        XCTAssertTrue(rootContents.contains { $0.name == "test.txt" })
        XCTAssertTrue(subContents.contains { $0.name == "test.txt" })
    }

    // MARK: - Multiple Copies
    func testCopySameFileTwiceIncrementsCorrectly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.copy(item, to: testDirectory)
        let copy1 = try FileSystem.shared.contents(of: testDirectory).first { $0.name == "test 1.txt" }!
        try FileSystem.shared.copy(copy1, to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 3)
        XCTAssertTrue(contents.contains { $0.name == "test.txt" })
        XCTAssertTrue(contents.contains { $0.name == "test 1.txt" })
        XCTAssertTrue(contents.contains { $0.name == "test 2.txt" })
    }

    // MARK: - Encrypted Copy
    func testCopyEncryptedFile() throws {
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "secret copy"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        XCTAssertTrue(item.isEncrypted)
        try FileSystem.shared.copy(item, to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.allSatisfy { $0.isEncrypted })
    }

    func testCopyEncryptedFilePreservesContent() throws {
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "secret content to copy"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.copy(item, to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 2)
        // open the copy (whichever isn't the original)
        let copy = contents.first { $0.id != item.id }!
        let openedURL = try FileSystem.shared.open(copy)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    func testCopyEncryptedFileResolvesNameConflict() throws {
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.copy(item, to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.contains { $0.name == "test.txt" })
        XCTAssertTrue(contents.contains { $0.name == "test 1.txt" })
    }
}
