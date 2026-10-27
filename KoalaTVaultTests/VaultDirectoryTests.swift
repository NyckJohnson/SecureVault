import XCTest
@testable import KoalaTVault

final class VaultDirectoryTests: XCTestCase {

    // MARK: - Root
    func testRootDirectoryExists() {
        let root = LegacyVaultDirectory.root
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.diskURL.path))
    }

    func testRootDirectoryIsDirectory() {
        let root = LegacyVaultDirectory.root
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: root.diskURL.path, isDirectory: &isDir)
        XCTAssertTrue(isDir.boolValue)
    }

    func testRootDirectoryNameIsKoalaTVault() {
        XCTAssertEqual(LegacyVaultDirectory.root.name, "KoalaTVault")
    }

    func testRootDirectoryIsConsistent() {
        let root1 = LegacyVaultDirectory.root
        let root2 = LegacyVaultDirectory.root
        XCTAssertEqual(root1.diskURL, root2.diskURL)
    }

    // MARK: - Custom Directory
    func testCustomDirectoryStoresName() {
        let url = FileManager.default.temporaryDirectory
        let dir = LegacyVaultDirectory(name: "MyFolder", diskURL: url, rootURL: url)
        XCTAssertEqual(dir.name, "MyFolder")
    }

    func testCustomDirectoryStoresDiskURL() {
        let url = FileManager.default.temporaryDirectory
        let dir = LegacyVaultDirectory(name: "MyFolder", diskURL: url, rootURL: url)
        XCTAssertEqual(dir.diskURL, url)
    }
}
