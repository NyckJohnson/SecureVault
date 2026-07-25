import XCTest
@testable import SecureVault

final class MigrationTests: XCTestCase {

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
        FileSystem.shared.cleanupTempFiles()
    }

    // MARK: - Migrate To Encrypted
    func testMigrateToEncryptedEncryptsFiles() throws {
        // import unencrypted files
        let url1 = FileManager.default.temporaryDirectory.appendingPathComponent("file1.txt")
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("file2.txt")
        try "content1".write(to: url1, atomically: true, encoding: .utf8)
        try "content2".write(to: url2, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        // import without encryption
        try FileSystem.shared.importItems(from: [url1, url2], to: testDirectory)
        var contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents.allSatisfy { !$0.isEncrypted })

        // now enable encryption and migrate
        try CryptoService.shared.loadKey(from: "testpassword")
        try FileSystem.shared.migrateToEncrypted(in: testDirectory, progress: { _ in })

        contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.allSatisfy { $0.isEncrypted })
    }

    func testMigrateToEncryptedPreservesFileNames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("important.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        try CryptoService.shared.loadKey(from: "testpassword")
        try FileSystem.shared.migrateToEncrypted(in: testDirectory, progress: { _ in })

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.first?.name, "important.txt")
    }

    func testMigrateToEncryptedPreservesContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "preserved content"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        try CryptoService.shared.loadKey(from: "testpassword")
        try FileSystem.shared.migrateToEncrypted(in: testDirectory, progress: { _ in })

        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let openedURL = try FileSystem.shared.open(item)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    func testMigrateToEncryptedReportsProgress() throws {
        let url1 = FileManager.default.temporaryDirectory.appendingPathComponent("file1.txt")
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("file2.txt")
        try "a".write(to: url1, atomically: true, encoding: .utf8)
        try "b".write(to: url2, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        try FileSystem.shared.importItems(from: [url1, url2], to: testDirectory)
        try CryptoService.shared.loadKey(from: "testpassword")

        var progressValues: [Double] = []
        try FileSystem.shared.migrateToEncrypted(in: testDirectory, progress: { progressValues.append($0) })

        XCTAssertEqual(progressValues.count, 2)
        XCTAssertEqual(progressValues.last, 1.0)
    }

    // MARK: - Migrate To Decrypted
    func testMigrateToDecryptedDecryptsFiles() throws {
        try CryptoService.shared.loadKey(from: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        var contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents.first?.isEncrypted == true)

        try FileSystem.shared.migrateToDecrypted(in: testDirectory, progress: { _ in })
        CryptoService.shared.wipeKey()

        contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 1)
        XCTAssertFalse(contents.first?.isEncrypted == true)
    }

    func testMigrateToDecryptedPreservesFileNames() throws {
        try CryptoService.shared.loadKey(from: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myfile.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        try FileSystem.shared.migrateToDecrypted(in: testDirectory, progress: { _ in })

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.first?.name, "myfile.txt")
    }

    func testMigrateToDecryptedPreservesContent() throws {
        try CryptoService.shared.loadKey(from: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "decrypted content"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        try FileSystem.shared.migrateToDecrypted(in: testDirectory, progress: { _ in })

        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let readContent = try String(contentsOf: item.diskURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    func testMigrateToDecryptedRemovesMappingFile() throws {
        try CryptoService.shared.loadKey(from: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        try FileSystem.shared.migrateToDecrypted(in: testDirectory, progress: { _ in })

        let mapURL = testDirectory.diskURL.appendingPathComponent(".vault_map")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapURL.path))
    }

    // MARK: - Round Trip
    func testEncryptThenDecryptRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "round trip content"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // import unencrypted
        try FileSystem.shared.importItems(from: [url], to: testDirectory)

        // encrypt
        try CryptoService.shared.loadKey(from: "testpassword")
        try FileSystem.shared.migrateToEncrypted(in: testDirectory, progress: { _ in })

        // decrypt
        try FileSystem.shared.migrateToDecrypted(in: testDirectory, progress: { _ in })
        CryptoService.shared.wipeKey()

        // verify content
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let readContent = try String(contentsOf: item.diskURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }
}
