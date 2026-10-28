import XCTest
import Security
@testable import KoalaTVault

// Regression tests for adoption baseline fix 24 (docs/adopt/baseline-fixes.md): a vault key blob
// left in the Keychain by an earlier install is replaced when the vault holds no encrypted data,
// and required (never replaced) when it does.

@MainActor
final class StaleVaultKeyTests: XCTestCase {

    private var vaultRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        reset()
        vaultRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        reset()
        if let vaultRoot { try? FileManager.default.removeItem(at: vaultRoot) }
        try await super.tearDown()
    }

    private func reset() {
        AuthService.shared.lockMode = .none
        try? AuthService.shared.removePassword()
        TestCrypto.keyStore.wipeKey()
    }

    /// A blob from an "earlier install": created, then the app forgets the key.
    private func leaveStaleBlob(password: String) throws {
        try TestCrypto.keyStore.createMasterKey(password: password)
        TestCrypto.keyStore.wipeKey()
    }

    private func storedBlob() -> Data? {
        try? TestCrypto.keychain.read(account: TestCrypto.blobAccount, prompt: nil)
    }

    private func writeFile(_ name: String, _ content: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? vaultRoot).appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Imports one file with the loaded key, so the vault holds an encrypted file and an index.
    private func addEncryptedFile() throws {
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let source = try writeFile("secret.txt", "secret", in: sourceDir)
        let root = LegacyVaultDirectory(name: "test", diskURL: vaultRoot, rootURL: vaultRoot)
        try FileSystem.shared.importItems(from: [source], to: root)
    }

    // MARK: - Empty vault: the stale key is replaced

    func testEmptyVaultWithStaleBlobCreatesANewKeyForTheTypedPassword() throws {
        try leaveStaleBlob(password: "old-password")
        let oldBlob = storedBlob()

        try AuthService.shared.createPassword("new-password", vaultRootURL: vaultRoot)

        XCTAssertTrue(TestCrypto.keyStore.isKeyLoaded)
        XCTAssertNotEqual(storedBlob(), oldBlob)
        TestCrypto.keyStore.wipeKey()
        XCTAssertNoThrow(try AuthService.shared.verifyPassword("new-password"))
        TestCrypto.keyStore.wipeKey()
        XCTAssertThrowsError(try AuthService.shared.verifyPassword("old-password")) { error in
            XCTAssertEqual(error as? AuthError, .wrongPassword)
        }
    }

    func testVaultWithOnlyPlaintextFilesCountsAsEmpty() throws {
        _ = try writeFile("plain.txt", "plain")
        let sub = vaultRoot.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try writeFile("inner.txt", "inner", in: sub)
        _ = try writeFile("empty.txt", "")
        try leaveStaleBlob(password: "old-password")

        XCTAssertFalse(AuthService.shared.vaultHoldsEncryptedData(at: vaultRoot))
        XCTAssertNoThrow(try AuthService.shared.createPassword("new-password", vaultRootURL: vaultRoot))
        XCTAssertEqual(try String(contentsOf: vaultRoot.appendingPathComponent("plain.txt"), encoding: .utf8), "plain")
    }

    func testNoBlobCreatesKeyAsBefore() throws {
        try AuthService.shared.createPassword("password123", vaultRootURL: vaultRoot)
        XCTAssertTrue(AuthService.shared.hasPassword())
        XCTAssertTrue(TestCrypto.keyStore.isKeyLoaded)
    }

    // MARK: - Encrypted data: the old password is required, the blob is untouched

    func testEncryptedDataWithStaleBlobRequiresTheOldPasswordAndKeepsTheBlob() throws {
        try TestCrypto.keyStore.createMasterKey(password: "old-password")
        try addEncryptedFile()
        TestCrypto.keyStore.wipeKey()
        let oldBlob = try XCTUnwrap(storedBlob())

        XCTAssertThrowsError(try AuthService.shared.createPassword("new-password", vaultRootURL: vaultRoot)) { error in
            XCTAssertEqual(error as? AuthError, .existingPasswordRequired)
            XCTAssertEqual(error.localizedDescription,
                           "A vault password already exists on this device. Enter that password.")
        }

        XCTAssertFalse(TestCrypto.keyStore.isKeyLoaded)
        XCTAssertEqual(storedBlob(), oldBlob, "the blob is never replaced")
        XCTAssertNoThrow(try AuthService.shared.verifyPassword("old-password"))
    }

    func testEncryptedDataWithTheOldPasswordUnlocksTheExistingKey() throws {
        try TestCrypto.keyStore.createMasterKey(password: "old-password")
        try addEncryptedFile()
        TestCrypto.keyStore.wipeKey()
        let oldBlob = try XCTUnwrap(storedBlob())

        try AuthService.shared.createPassword("old-password", vaultRootURL: vaultRoot)

        XCTAssertTrue(TestCrypto.keyStore.isKeyLoaded)
        XCTAssertEqual(storedBlob(), oldBlob)
        let root = LegacyVaultDirectory(name: "test", diskURL: vaultRoot, rootURL: vaultRoot)
        let item = try XCTUnwrap(try FileSystem.shared.contents(of: root).first)
        XCTAssertEqual(try String(contentsOf: try FileSystem.shared.open(item), encoding: .utf8), "secret")
    }

    // MARK: - What counts as encrypted data

    func testIndexAloneCountsAsEncryptedData() throws {
        let sub = vaultRoot.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try writeFile(".vault_map", "anything", in: sub)
        XCTAssertTrue(AuthService.shared.vaultHoldsEncryptedData(at: vaultRoot))
    }

    func testTrashEntryCountsAsEncryptedData() throws {
        let trash = vaultRoot.appendingPathComponent(".trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        XCTAssertFalse(AuthService.shared.vaultHoldsEncryptedData(at: vaultRoot), "an empty trash folder is nothing")
        _ = try writeFile(UUID().uuidString, "deleted", in: trash)
        XCTAssertTrue(AuthService.shared.vaultHoldsEncryptedData(at: vaultRoot))
    }

    func testEncryptedFileWithoutIndexCountsAsEncryptedData() throws {
        try TestCrypto.keyStore.createMasterKey(password: "pw")
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let source = try writeFile("a.txt", "alpha", in: sourceDir)
        try TestCrypto.cipher.encryptFile(at: source, to: vaultRoot.appendingPathComponent(UUID().uuidString))
        XCTAssertTrue(AuthService.shared.vaultHoldsEncryptedData(at: vaultRoot))
    }

    func testUnreadableRootCountsAsEncryptedDataAndKeepsTheBlob() throws {
        try leaveStaleBlob(password: "old-password")
        let oldBlob = storedBlob()
        let missing = vaultRoot.appendingPathComponent("does-not-exist")

        XCTAssertTrue(AuthService.shared.vaultHoldsEncryptedData(at: missing))
        XCTAssertThrowsError(try AuthService.shared.createPassword("new-password", vaultRootURL: missing)) { error in
            XCTAssertEqual(error as? AuthError, .existingPasswordRequired)
        }
        XCTAssertEqual(storedBlob(), oldBlob)
    }

    func testEmptyRootHoldsNoEncryptedData() {
        XCTAssertFalse(AuthService.shared.vaultHoldsEncryptedData(at: vaultRoot))
    }

    func testPermissionDeniedRootCountsAsEncryptedDataAndKeepsTheBlob() throws {
        try leaveStaleBlob(password: "old-password")
        let oldBlob = storedBlob()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vaultRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vaultRoot.path) }

        XCTAssertTrue(AuthService.shared.vaultHoldsEncryptedData(at: vaultRoot))
        XCTAssertThrowsError(try AuthService.shared.createPassword("new-password", vaultRootURL: vaultRoot)) { error in
            XCTAssertEqual(error as? AuthError, .existingPasswordRequired)
        }
        XCTAssertEqual(storedBlob(), oldBlob)
    }

    // MARK: - Encrypted-file detection (AuthService.vaultHoldsEncryptedData)

    /// A fresh vault folder holding only `file`, so the check decides on that file alone.
    private func folderHolding(_ file: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testMayBeEncryptedFileIsTrueOnlyForTheEncryptedFormat() throws {
        try TestCrypto.keyStore.createMasterKey(password: "pw")
        let plain = try writeFile("plain.txt", "plain text content")
        let empty = try writeFile("empty.txt", "")
        let short = try writeFile("short.txt", "ab")
        let encrypted = vaultRoot.appendingPathComponent("enc")
        try TestCrypto.cipher.encryptFile(at: plain, to: encrypted)

        XCTAssertFalse(AuthService.shared.vaultHoldsEncryptedData(at: try folderHolding(plain)))
        XCTAssertFalse(AuthService.shared.vaultHoldsEncryptedData(at: try folderHolding(empty)))
        XCTAssertFalse(AuthService.shared.vaultHoldsEncryptedData(at: try folderHolding(short)))
        XCTAssertTrue(AuthService.shared.vaultHoldsEncryptedData(at: try folderHolding(encrypted)))
    }

    func testMayBeEncryptedFileIsTrueWhenTheFileCannotBeRead() throws {
        let locked = try writeFile("locked.txt", "plain text content")
        let folder = try folderHolding(locked)
        let copy = folder.appendingPathComponent("locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: copy.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path) }
        XCTAssertTrue(AuthService.shared.vaultHoldsEncryptedData(at: folder))
    }
}
