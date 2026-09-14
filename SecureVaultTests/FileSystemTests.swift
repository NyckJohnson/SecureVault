//
//  Untitled.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/20/26.
//

import XCTest
@testable import SecureVault

final class FileSystemTests: VaultTestCase {

    // MARK: - Create Folder
    func testCreateFolder() throws {
        let folder = try FileSystem.shared.createFolder(named: "TestFolder", in: testDirectory)
        XCTAssertEqual(folder.name, "TestFolder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.diskURL.path))
    }

    // MARK: - Conflict Resolution
    func testCreateFolderHandlesNameConflict() throws {
        _ = try FileSystem.shared.createFolder(named: "TestFolder", in: testDirectory)
        let second = try FileSystem.shared.createFolder(named: "TestFolder", in: testDirectory)
        XCTAssertEqual(second.name, "TestFolder 1")
    }

    // MARK: - Contents
    func testContentsReturnsCreatedFolder() throws {
        _ = try FileSystem.shared.createFolder(named: "TestFolder", in: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?.name, "TestFolder")
        XCTAssertTrue(contents.first?.isDirectory == true)
    }

    func testContentsIsEmptyInitially() throws {
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents.isEmpty)
    }

    // MARK: - Import
    func testImportFile() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello world".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?.name, "test.txt")
    }

    func testImportSameFileTwiceDoesNotDuplicate() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 1)
        XCTAssertTrue(contents.contains { $0.name == "test.txt" })
    }

    func testImportDifferentFileWithSameNameCreatesConflict() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)

        try "goodbye".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.contains { $0.name == "test.txt" })
        XCTAssertTrue(contents.contains { $0.name == "test 1.txt" })
    }

    // MARK: - Delete
    func testDeleteFile() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        try FileSystem.shared.delete(contents.first!)
        let afterDelete = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    // MARK: - Rename
    func testRenameFile() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let contents = try FileSystem.shared.contents(of: testDirectory)
        try FileSystem.shared.rename(contents.first!, to: "renamed.txt")
        let afterRename = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(afterRename.first?.name, "renamed.txt")
    }

    // MARK: - Move
    func testMoveFileToFolder() throws {
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
    }

    // MARK: - Open
    func testOpenFileReturnsReadableContent() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        let content = "hello world"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!
        let openedURL = try FileSystem.shared.open(item)
        let readContent = try String(contentsOf: openedURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }
}
