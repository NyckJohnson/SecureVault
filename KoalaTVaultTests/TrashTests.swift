import XCTest
@testable import KoalaTVault

final class TrashTests: VaultTestCase {

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

        let trash = try FileSystem.shared.contentsOfTrash(for: testDirectory)
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

        let trash = try FileSystem.shared.contentsOfTrash(for: testDirectory)
        XCTAssertEqual(trash.count, 2)
    }

    func testTrashPreservesFileName() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myfile.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let trash = try FileSystem.shared.contentsOfTrash(for: testDirectory)
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

        let trashItem = try FileSystem.shared.contentsOfTrash(for: testDirectory).first!
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

        let trashItem = try FileSystem.shared.contentsOfTrash(for: testDirectory).first!
        try FileSystem.shared.restoreFromTrash(trashItem)

        let trash = try FileSystem.shared.contentsOfTrash(for: testDirectory)
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

        let trashItem = try FileSystem.shared.contentsOfTrash(for: testDirectory).first!
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

        let trashItem = try FileSystem.shared.contentsOfTrash(for: testDirectory).first!
        try FileSystem.shared.permanentlyDelete(trashItem)

        let trash = try FileSystem.shared.contentsOfTrash(for: testDirectory)
        XCTAssertTrue(trash.isEmpty)
    }

    func testPermanentlyDeleteRemovesFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let trashItem = try FileSystem.shared.contentsOfTrash(for: testDirectory).first!
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

        try FileSystem.shared.emptyTrash(for: testDirectory)
        let trash = try FileSystem.shared.contentsOfTrash(for: testDirectory)
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

        FileSystem.shared.cleanupExpiredTrashItems(for: testDirectory)

        let trash = try FileSystem.shared.contentsOfTrash(for: testDirectory)
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

        let trash = try FileSystem.shared.contentsOfTrash(for: testDirectory)
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

        XCTAssertEqual(try FileSystem.shared.contentsOfTrash(for: testDirectory).count, 1)

        let trashItem = try FileSystem.shared.contentsOfTrash(for: testDirectory).first!
        try FileSystem.shared.restoreFromTrash(trashItem)

        let restored = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.name, "test.txt")
        XCTAssertTrue(try FileSystem.shared.contentsOfTrash(for: testDirectory).isEmpty)
    }

    // MARK: - Trash map under a lock (baseline fix 12)

    private var trashMapURL: URL {
        FileSystem.shared.trashDirectory(for: testDirectory.rootURL).diskURL.appendingPathComponent(".trash_map")
    }

    private func importPlainFile(named name: String) throws -> VaultItem {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())-\(name)")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let renamed = url.deletingLastPathComponent().appendingPathComponent(name)
        try? FileManager.default.removeItem(at: renamed)
        try FileManager.default.moveItem(at: url, to: renamed)
        defer { try? FileManager.default.removeItem(at: renamed) }
        try FileSystem.shared.importItems(from: [renamed], to: testDirectory)
        return try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first { $0.name == name })
    }

    func testPlaintextTrashMapIsReadWithKeyLoadedAndNextSaveEncryptsIt() throws {
        let first = try importPlainFile(named: "before-lock.txt")
        try FileSystem.shared.delete(first)   // no lock: plaintext .trash_map
        XCTAssertNotNil(try? JSONDecoder().decode([String: FileSystem.TrashEntryForTesting].self,
                                                  from: Data(contentsOf: trashMapURL)))

        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let listed = try FileSystem.shared.contentsOfTrash(for: testDirectory)
        XCTAssertEqual(listed.map(\.name), ["before-lock.txt"])

        let second = try importPlainFile(named: "after-lock.txt")
        try FileSystem.shared.delete(second)  // next save

        let raw = try Data(contentsOf: trashMapURL)
        XCTAssertNil(try? JSONDecoder().decode([String: FileSystem.TrashEntryForTesting].self, from: raw),
                     "After the next save the trash map is encrypted, not plaintext JSON")
        XCTAssertEqual(Set(try FileSystem.shared.contentsOfTrash(for: testDirectory).map(\.name)),
                       ["before-lock.txt", "after-lock.txt"])
    }

    func testMoveToTrashThrowsAndLeavesItemWhenTrashMapIsUnreadable() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let item = try importPlainFile(named: "keep.txt")
        try Data([0x00, 0xFF, 0x13, 0x37, 0xDE, 0xAD]).write(to: trashMapURL, options: .atomic)

        XCTAssertThrowsError(try FileSystem.shared.moveToTrash(item))

        XCTAssertTrue(FileManager.default.fileExists(atPath: item.diskURL.path))
        XCTAssertEqual(try FileSystem.shared.contents(of: testDirectory).map(\.name), ["keep.txt"])
    }

    /// Deletes a file to the trash, then rewrites its trash entry with the given folder and disk name.
    private func trashItemWithTamperedEntry(directory: String?, diskName: String?) throws -> VaultItem {
        let item = try importPlainFile(named: "victim.txt")
        try FileSystem.shared.delete(item)
        var map = try FileSystem.shared.testTrashMap(for: testDirectory)
        let key = try XCTUnwrap(map.keys.first)
        let old = try XCTUnwrap(map[key])
        map[key] = FileSystem.TrashEntryForTesting(
            originalDiskName: diskName ?? old.originalDiskName,
            originalDirectoryURL: directory ?? old.originalDirectoryURL,
            deletedAt: old.deletedAt, isEncrypted: old.isEncrypted,
            originalName: old.originalName, rootURL: old.rootURL)
        try FileSystem.shared.saveTestTrashMap(map, for: testDirectory)
        return try XCTUnwrap(try FileSystem.shared.contentsOfTrash(for: testDirectory).first)
    }

    private func assertRestoreRejected(_ trashItem: VaultItem, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try FileSystem.shared.restoreFromTrash(trashItem), file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashItem.diskURL.path), file: file, line: line)
        XCTAssertEqual(try FileSystem.shared.contentsOfTrash(for: testDirectory).count, 1, file: file, line: line)
    }

    func testRestoreRejectsEntryWithDotDotFolderOutsideVaultRoot() throws {
        let escaping = testDirectory.diskURL.path + "/../escaped-\(UUID())"
        let trashItem = try trashItemWithTamperedEntry(directory: escaping, diskName: nil)
        try assertRestoreRejected(trashItem)
    }

    func testRestoreRejectsEntryWithAbsoluteFolderOutsideVaultRoot() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID())").path
        let trashItem = try trashItemWithTamperedEntry(directory: outside, diskName: nil)
        try assertRestoreRejected(trashItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside))
    }

    func testRestoreRejectsEntryWhoseDiskNameContainsSlash() throws {
        let trashItem = try trashItemWithTamperedEntry(directory: nil, diskName: "sub/evil.txt")
        try assertRestoreRejected(trashItem)
    }
}
