import XCTest
@testable import KoalaTVault

final class SortTests: VaultTestCase {

    override func setUp() {
        super.setUp()
        LegacyStorage.current.preferences.sortOption = .name
        LegacyStorage.current.preferences.sortDirection = .ascending
    }

    override func tearDown() {
        LegacyStorage.current.preferences.sortOption = .name
        LegacyStorage.current.preferences.sortDirection = .ascending
        super.tearDown()
    }

    // MARK: - Helpers
    private func createFile(named name: String, content: String = "x") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Folders First
    func testFoldersAlwaysBeforeFiles() throws {
        let url = try createFile(named: "aaa.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try FileSystem.shared.importItems(from: [url], to: testDirectory)
        _ = try FileSystem.shared.createFolder(named: "zzz", in: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents.first?.isDirectory == true)
        XCTAssertFalse(contents.last?.isDirectory == true)
    }

    // MARK: - Sort By Name
    func testSortByNameAscending() throws {
        let urlB = try createFile(named: "banana.txt")
        let urlA = try createFile(named: "apple.txt")
        let urlC = try createFile(named: "cherry.txt")
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
            try? FileManager.default.removeItem(at: urlC)
        }

        LegacyStorage.current.preferences.sortOption = .name
        LegacyStorage.current.preferences.sortDirection = .ascending
        try FileSystem.shared.importItems(from: [urlB, urlA, urlC], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents[0].name, "apple.txt")
        XCTAssertEqual(contents[1].name, "banana.txt")
        XCTAssertEqual(contents[2].name, "cherry.txt")
    }

    func testSortByNameDescending() throws {
        let urlB = try createFile(named: "banana.txt")
        let urlA = try createFile(named: "apple.txt")
        let urlC = try createFile(named: "cherry.txt")
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
            try? FileManager.default.removeItem(at: urlC)
        }

        LegacyStorage.current.preferences.sortOption = .name
        LegacyStorage.current.preferences.sortDirection = .descending
        try FileSystem.shared.importItems(from: [urlB, urlA, urlC], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(contents[0].name, "cherry.txt")
        XCTAssertEqual(contents[1].name, "banana.txt")
        XCTAssertEqual(contents[2].name, "apple.txt")
    }

    // MARK: - Sort By Type
    func testSortByTypeGroupsExtensions() throws {
        let urlJpg  = try createFile(named: "photo.jpg")
        let urlTxt  = try createFile(named: "doc.txt")
        let urlJpg2 = try createFile(named: "another.jpg")
        defer {
            try? FileManager.default.removeItem(at: urlJpg)
            try? FileManager.default.removeItem(at: urlTxt)
            try? FileManager.default.removeItem(at: urlJpg2)
        }

        LegacyStorage.current.preferences.sortOption = .type
        LegacyStorage.current.preferences.sortDirection = .ascending
        try FileSystem.shared.importItems(from: [urlJpg, urlTxt, urlJpg2], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        let names = contents.map { $0.name }
        // jpg files should be grouped together
        let jpgIndices = names.enumerated().filter { ($0.element as NSString).pathExtension == "jpg" }.map { $0.offset }
        XCTAssertEqual(jpgIndices, [0, 1])
    }

    func testSortByTypeDescending() throws {
        let urlJpg = try createFile(named: "photo.jpg")
        let urlTxt = try createFile(named: "doc.txt")
        defer {
            try? FileManager.default.removeItem(at: urlJpg)
            try? FileManager.default.removeItem(at: urlTxt)
        }

        LegacyStorage.current.preferences.sortOption = .type
        LegacyStorage.current.preferences.sortDirection = .descending
        try FileSystem.shared.importItems(from: [urlJpg, urlTxt], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        // descending: txt before jpg
        XCTAssertEqual((contents.first?.name as? NSString)?.pathExtension, "txt")
    }

    // MARK: - Sort By Date
    func testSortByDateModifiedAscending() throws {
        let url1 = try createFile(named: "file1.txt")
        Thread.sleep(forTimeInterval: 0.05)
        let url2 = try createFile(named: "file2.txt")
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        LegacyStorage.current.preferences.sortOption = .dateModified
        LegacyStorage.current.preferences.sortDirection = .ascending
        try FileSystem.shared.importItems(from: [url2, url1], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents[0].dateModified <= contents[1].dateModified)
    }

    func testSortByDateModifiedDescending() throws {
        let url1 = try createFile(named: "file1.txt")
        Thread.sleep(forTimeInterval: 0.05)
        let url2 = try createFile(named: "file2.txt")
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        LegacyStorage.current.preferences.sortOption = .dateModified
        LegacyStorage.current.preferences.sortDirection = .descending
        try FileSystem.shared.importItems(from: [url1, url2], to: testDirectory)

        let contents = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(contents[0].dateModified >= contents[1].dateModified)
    }

    // MARK: - Sort Preferences
    func testSortOptionPersists() {
        LegacyStorage.current.preferences.sortOption = .dateModified
        XCTAssertEqual(LegacyStorage.current.preferences.sortOption, .dateModified)
    }

    func testSortDirectionPersists() {
        LegacyStorage.current.preferences.sortDirection = .descending
        XCTAssertEqual(LegacyStorage.current.preferences.sortDirection, .descending)
    }

    func testAllSortOptionsAvailable() {
        XCTAssertEqual(SortOption.allCases.count, 3)
        XCTAssertTrue(SortOption.allCases.contains(.name))
        XCTAssertTrue(SortOption.allCases.contains(.type))
        XCTAssertTrue(SortOption.allCases.contains(.dateModified))
    }

    func testSortOptionDisplayNames() {
        XCTAssertEqual(SortOption.name.displayName, "Name")
        XCTAssertEqual(SortOption.type.displayName, "Type")
        XCTAssertEqual(SortOption.dateModified.displayName, "Date Modified")
    }
}
