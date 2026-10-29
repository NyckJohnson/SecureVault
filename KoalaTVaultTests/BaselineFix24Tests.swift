import XCTest
@testable import KoalaTVault

// Regression tests for adoption baseline fix 24 (docs/adopt/baseline-fixes.md): what counts as encrypted
// data in a vault folder. The stale-blob decisions built on it (replace the blob in an empty vault, require
// the old password otherwise) are tested in VaultLock/LiveVaultLockTests.swift.

/// The bytes that start an encrypted vault file.
private let encryptedFileMagic = Data("SVC5".utf8)

final class StaleVaultKeyTests: XCTestCase {

    private var vaultRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vaultRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let vaultRoot { try? FileManager.default.removeItem(at: vaultRoot) }
        super.tearDown()
    }

    private func holdsEncryptedData(at url: URL) -> Bool {
        VaultEncryptedDataCheck.holdsEncryptedData(at: url, fileManager: .default)
    }

    @discardableResult
    private func writeFile(_ name: String, _ content: Data, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? vaultRoot).appendingPathComponent(name)
        try content.write(to: url)
        return url
    }

    @discardableResult
    private func writeFile(_ name: String, _ content: String, in dir: URL? = nil) throws -> URL {
        try writeFile(name, Data(content.utf8), in: dir)
    }

    /// An encrypted-format file: the magic bytes then filler.
    private var encryptedContent: Data { encryptedFileMagic + Data(repeating: 7, count: 64) }

    // MARK: - What counts as encrypted data

    func testVaultWithOnlyPlaintextFilesCountsAsEmpty() throws {
        try writeFile("plain.txt", "plain")
        let sub = vaultRoot.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile("inner.txt", "inner", in: sub)
        try writeFile("empty.txt", "")

        XCTAssertFalse(holdsEncryptedData(at: vaultRoot))
    }

    func testIndexAloneCountsAsEncryptedData() throws {
        let sub = vaultRoot.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(".vault_map", "anything", in: sub)
        XCTAssertTrue(holdsEncryptedData(at: vaultRoot))
    }

    func testTrashEntryCountsAsEncryptedData() throws {
        let trash = vaultRoot.appendingPathComponent(".trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        XCTAssertFalse(holdsEncryptedData(at: vaultRoot), "an empty trash folder is nothing")
        try writeFile(UUID().uuidString, "deleted", in: trash)
        XCTAssertTrue(holdsEncryptedData(at: vaultRoot))
    }

    func testEncryptedFileWithoutIndexCountsAsEncryptedData() throws {
        try writeFile(UUID().uuidString, encryptedContent)
        XCTAssertTrue(holdsEncryptedData(at: vaultRoot))
    }

    func testUnreadableRootCountsAsEncryptedData() {
        let missing = vaultRoot.appendingPathComponent("does-not-exist")
        XCTAssertTrue(holdsEncryptedData(at: missing))
    }

    func testEmptyRootHoldsNoEncryptedData() {
        XCTAssertFalse(holdsEncryptedData(at: vaultRoot))
    }

    func testPermissionDeniedRootCountsAsEncryptedData() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vaultRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vaultRoot.path) }
        XCTAssertTrue(holdsEncryptedData(at: vaultRoot))
    }

    // MARK: - Encrypted-file detection

    /// A fresh vault folder holding only `file`, so the check decides on that file alone.
    private func folderHolding(_ file: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testMayBeEncryptedFileIsTrueOnlyForTheEncryptedFormat() throws {
        let plain = try writeFile("plain.txt", "plain text content")
        let empty = try writeFile("empty.txt", "")
        let short = try writeFile("short.txt", "ab")
        let encrypted = try writeFile("enc", encryptedContent)

        XCTAssertFalse(holdsEncryptedData(at: try folderHolding(plain)))
        XCTAssertFalse(holdsEncryptedData(at: try folderHolding(empty)))
        XCTAssertFalse(holdsEncryptedData(at: try folderHolding(short)))
        XCTAssertTrue(holdsEncryptedData(at: try folderHolding(encrypted)))
    }

    func testMayBeEncryptedFileIsTrueWhenTheFileCannotBeRead() throws {
        let locked = try writeFile("locked.txt", "plain text content")
        let folder = try folderHolding(locked)
        let copy = folder.appendingPathComponent("locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: copy.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path) }
        XCTAssertTrue(holdsEncryptedData(at: folder))
    }
}
