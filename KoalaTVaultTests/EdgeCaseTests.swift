import XCTest
@testable import KoalaTVault

final class EdgeCaseTests: VaultTestCase {

    // MARK: - Empty Folder
    func testEmptyFolderContentsIsEmpty() throws {
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents.isEmpty)
    }

    func testEmptyFolderAfterDeletingAllFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents.isEmpty)
    }

    // MARK: - Long File Names
    func testImportFileWithLongName() throws {
        let longName = String(repeating: "a", count: 200) + ".txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(longName)
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.first?.name, longName)
    }

    func testRenameToLongName() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let longName = String(repeating: "b", count: 200) + ".txt"
        try FileSystem.shared.rename(item, to: longName)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.first?.name, longName)
    }

    // MARK: - Files With No Extension
    func testImportFileWithNoExtension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noextension")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.first?.name, "noextension")
    }

    func testCopyFileWithNoExtension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noextension")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.copy(item, to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.contains { $0.name == "noextension" })
        XCTAssertTrue(contents.contains { $0.name == "noextension 1" })
    }

    func testDeleteFileWithNoExtension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noextension")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        let trash = try FileSystem.shared.contentsOfTrash(for: testDirectory)
        XCTAssertEqual(trash.first?.name, "noextension")
    }

    // MARK: - Move File To Same Directory
    func testMoveFileToSameDirectory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        // moving to same directory should not crash
        XCTAssertNoThrow(try FileSystem.shared.move(item, to: testDirectory))
    }

    // MARK: - Import Folder
    func testImportFolder() throws {
        // create a temp folder with files
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("TestImportFolder")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let file1URL = folderURL.appendingPathComponent("file1.txt")
        let file2URL = folderURL.appendingPathComponent("file2.txt")
        try "hello".write(to: file1URL, atomically: true, encoding: .utf8)
        try "world".write(to: file2URL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        try FileSystem.shared.importItems(from: [folderURL], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 1)
        XCTAssertTrue(contents.first?.isDirectory == true)
        XCTAssertEqual(contents.first?.name, "TestImportFolder")

        let importedFolder = VaultDirectory(name: "TestImportFolder", diskURL: contents.first!.diskURL, rootURL: testDirectory.rootURL)
        let folderContents = try FileSystem.shared.contents(of: importedFolder)
        XCTAssertEqual(folderContents.count, 2)
    }

    func testImportNestedFolder() throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("ParentFolder")
        let subFolderURL = folderURL.appendingPathComponent("SubFolder")
        try FileManager.default.createDirectory(at: subFolderURL, withIntermediateDirectories: true)
        let fileURL = subFolderURL.appendingPathComponent("nested.txt")
        try "nested".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        try FileSystem.shared.importItems(from: [folderURL], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 1)
        XCTAssertTrue(contents.first?.isDirectory == true)

        let importedFolder = VaultDirectory(name: "ParentFolder", diskURL: contents.first!.diskURL, rootURL: testDirectory.rootURL)
        let folderContents = try FileSystem.shared.contents(of: importedFolder)
        XCTAssertEqual(folderContents.count, 1)
        XCTAssertTrue(folderContents.first?.isDirectory == true)
        XCTAssertEqual(folderContents.first?.name, "SubFolder")
    }

    // MARK: - Write
    func testWritePlaintextFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let newContent = "updated"
        try FileSystem.shared.write(data: newContent.data(using: .utf8)!, to: item)

        let readContent = try String(contentsOf: item.diskURL, encoding: .utf8)
        XCTAssertEqual(readContent, newContent)
    }

    func testWriteEncryptedFile() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let newContent = "updated encrypted"
        try FileSystem.shared.write(data: newContent.data(using: .utf8)!, to: item)

        let openedURL = try FileSystem.shared.open(item)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, newContent)
    }

    // MARK: - Trash Edge Cases
    func testTrashCleanupRemovesExpiredItems() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(item)

        // manually set deletion date to 31 days ago
        var trashMap = try FileSystem.shared.testTrashMap(for: testDirectory)
        if let key = trashMap.keys.first {
            let oldEntry = trashMap[key]!
            trashMap[key] = FileSystem.TrashEntryForTesting(
                originalDiskName: oldEntry.originalDiskName,
                originalDirectoryURL: oldEntry.originalDirectoryURL,
                deletedAt: Date().addingTimeInterval(-31 * 24 * 60 * 60),
                isEncrypted: oldEntry.isEncrypted,
                originalName: oldEntry.originalName,
                rootURL: oldEntry.rootURL
            )
            try FileSystem.shared.saveTestTrashMap(trashMap, for: testDirectory)
        }

        FileSystem.shared.cleanupExpiredTrashItems(for: testDirectory)
        XCTAssertTrue(try FileSystem.shared.contentsOfTrash(for: testDirectory).isEmpty)
    }

    func testRestoreWhenOriginalFolderDeleted() throws {
        // create subfolder, import file, delete subfolder contents, restore
        let subFolder = try FileSystem.shared.createFolder(named: "SubFolder", in: testDirectory)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: subFolder)
        let item = try FileSystem.shared.contents(of: subFolder).first!
        try FileSystem.shared.delete(item)

        // delete the subfolder
        let subFolderItem = try FileSystem.shared.contents(of: testDirectory).first!
        try FileSystem.shared.delete(subFolderItem)

        // restore should recreate the folder
        let trashItems = try FileSystem.shared.contentsOfTrash(for: testDirectory)
        let fileItem = trashItems.first { !$0.isDirectory }
        guard let fileItem else { return }

        XCTAssertNoThrow(try FileSystem.shared.restoreFromTrash(fileItem))
    }
}
