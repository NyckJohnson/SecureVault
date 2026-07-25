import XCTest
@testable import SecureVault

final class VaultItemTests: XCTestCase {

    func makeItem(name: String = "test.txt", isDirectory: Bool = false, isEncrypted: Bool = false) -> VaultItem {
        VaultItem(
            id: UUID(),
            name: name,
            isDirectory: isDirectory,
            dateModified: Date(),
            fileSize: 100,
            diskURL: FileManager.default.temporaryDirectory.appendingPathComponent(name),
            isEncrypted: isEncrypted
        )
    }

    // MARK: - Equatable
    func testItemsWithSameIDAreEqual() {
        let id = UUID()
        let item1 = VaultItem(id: id, name: "a.txt", isDirectory: false, dateModified: Date(), fileSize: 1, diskURL: FileManager.default.temporaryDirectory, isEncrypted: false)
        let item2 = VaultItem(id: id, name: "b.txt", isDirectory: false, dateModified: Date(), fileSize: 2, diskURL: FileManager.default.temporaryDirectory, isEncrypted: false)
        XCTAssertEqual(item1, item2)
    }

    func testItemsWithDifferentIDsAreNotEqual() {
        let item1 = makeItem(name: "test.txt")
        let item2 = makeItem(name: "test.txt")
        XCTAssertNotEqual(item1, item2)
    }

    // MARK: - Hashable
    func testItemsWithSameIDHaveSameHash() {
        let id = UUID()
        let item1 = VaultItem(id: id, name: "a.txt", isDirectory: false, dateModified: Date(), fileSize: 1, diskURL: FileManager.default.temporaryDirectory, isEncrypted: false)
        let item2 = VaultItem(id: id, name: "b.txt", isDirectory: false, dateModified: Date(), fileSize: 2, diskURL: FileManager.default.temporaryDirectory, isEncrypted: false)
        XCTAssertEqual(item1.hashValue, item2.hashValue)
    }

    func testItemCanBeStoredInSet() {
        let item1 = makeItem(name: "test.txt")
        let item2 = makeItem(name: "other.txt")
        var set = Set<VaultItem>()
        set.insert(item1)
        set.insert(item2)
        XCTAssertEqual(set.count, 2)
    }

    func testDuplicateItemNotAddedToSet() {
        let item = makeItem(name: "test.txt")
        var set = Set<VaultItem>()
        set.insert(item)
        set.insert(item)
        XCTAssertEqual(set.count, 1)
    }

    func testItemCanBeUsedAsDictionaryKey() {
        let item = makeItem(name: "test.txt")
        var dict = [VaultItem: String]()
        dict[item] = "value"
        XCTAssertEqual(dict[item], "value")
    }

    // MARK: - Properties
    func testIsDirectoryFalseByDefault() {
        let item = makeItem(isDirectory: false)
        XCTAssertFalse(item.isDirectory)
    }

    func testIsDirectoryTrue() {
        let item = makeItem(isDirectory: true)
        XCTAssertTrue(item.isDirectory)
    }

    func testIsEncryptedFalseByDefault() {
        let item = makeItem(isEncrypted: false)
        XCTAssertFalse(item.isEncrypted)
    }

    func testIsEncryptedTrue() {
        let item = makeItem(isEncrypted: true)
        XCTAssertTrue(item.isEncrypted)
    }

    func testNameIsStoredCorrectly() {
        let item = makeItem(name: "myfile.pdf")
        XCTAssertEqual(item.name, "myfile.pdf")
    }

    func testNameIsMutable() {
        var item = makeItem(name: "original.txt")
        item.name = "renamed.txt"
        XCTAssertEqual(item.name, "renamed.txt")
    }
}
