import XCTest
@testable import SecureVault

final class ConflictResolutionTests: XCTestCase {

    var testDirectory: VaultDirectory!

    override func setUp() {
        super.setUp()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        testDirectory = VaultDirectory(name: "test", diskURL: tempURL)
    }

    override func tearDown() {
        super.tearDown()
        CryptoService.shared.wipeKey()
        try? FileManager.default.removeItem(at: testDirectory.diskURL)
    }

    // MARK: - Basic Conflicts
    func testImportSameFileTwiceCreatesConflict() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.contains { $0.name == "test.txt" })
        XCTAssertTrue(contents.contains { $0.name == "test 1.txt" })
    }

    func testImportSameFileThreeTimesCreatesSequentialConflicts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 3)
        XCTAssertTrue(contents.contains { $0.name == "test.txt" })
        XCTAssertTrue(contents.contains { $0.name == "test 1.txt" })
        XCTAssertTrue(contents.contains { $0.name == "test 2.txt" })
    }

    // MARK: - No Extension
    func testConflictWithNoExtension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noextension")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.contains { $0.name == "noextension" })
        XCTAssertTrue(contents.contains { $0.name == "noextension 1" })
    }

    // MARK: - Folder Conflicts
    func testCreateFolderConflict() throws {
        _ = try FileSystem.shared.createFolder(named: "MyFolder", in: testDirectory)
        let second = try FileSystem.shared.createFolder(named: "MyFolder", in: testDirectory)
        XCTAssertEqual(second.name, "MyFolder 1")
    }

    func testCreateMultipleFolderConflicts() throws {
        _ = try FileSystem.shared.createFolder(named: "MyFolder", in: testDirectory)
        _ = try FileSystem.shared.createFolder(named: "MyFolder", in: testDirectory)
        let third = try FileSystem.shared.createFolder(named: "MyFolder", in: testDirectory)
        XCTAssertEqual(third.name, "MyFolder 2")
    }

    // MARK: - Encrypted Conflicts
    func testEncryptedImportSameFileTwiceCreatesConflict() throws {
        try CryptoService.shared.loadKey(from: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        print("Encrypted conflict names: \(contents.map { $0.name })")  // add this
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.contains { $0.name == "test.txt" })
        XCTAssertTrue(contents.contains { $0.name == "test 1.txt" })
    }

    // MARK: - Different Extensions
    func testFilesWithDifferentExtensionsDontConflict() throws {
        let url1 = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("test.jpg")
        try "hello".write(to: url1, atomically: true, encoding: .utf8)
        try "world".write(to: url2, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        try FileSystem.shared.importItems(from: [url1, url2], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.contains { $0.name == "test.txt" })
        XCTAssertTrue(contents.contains { $0.name == "test.jpg" })
    }
}
