import XCTest
@testable import SecureVault

final class VaultDirectoryTests: XCTestCase {

    // MARK: - Root
    func testRootDirectoryExists() {
        let root = VaultDirectory.root
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.diskURL.path))
    }

    func testRootDirectoryIsDirectory() {
        let root = VaultDirectory.root
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: root.diskURL.path, isDirectory: &isDir)
        XCTAssertTrue(isDir.boolValue)
    }

    func testRootDirectoryNameIsSecureVault() {
        XCTAssertEqual(VaultDirectory.root.name, "SecureVault")
    }

    func testRootDirectoryIsConsistent() {
        let root1 = VaultDirectory.root
        let root2 = VaultDirectory.root
        XCTAssertEqual(root1.diskURL, root2.diskURL)
    }

    // MARK: - Custom Directory
    func testCustomDirectoryStoresName() {
        let url = FileManager.default.temporaryDirectory
        let dir = VaultDirectory(name: "MyFolder", diskURL: url)
        XCTAssertEqual(dir.name, "MyFolder")
    }

    func testCustomDirectoryStoresDiskURL() {
        let url = FileManager.default.temporaryDirectory
        let dir = VaultDirectory(name: "MyFolder", diskURL: url)
        XCTAssertEqual(dir.diskURL, url)
    }
}
