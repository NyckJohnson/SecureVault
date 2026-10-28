import XCTest
import Security
@testable import KoalaTVault

// Regression tests for adoption baseline fix 25 (docs/adopt/baseline-fixes.md): adding Password +
// Face ID from No Lock creates the password first and enables Face ID last; when enabling Face ID
// fails, the password setup is rolled back (a key created by the attempt is removed, a kept key
// stays).

@MainActor
final class PasswordSetupRollbackTests: XCTestCase {

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
        AuthService.shared.removeBiometricSecret()
        TestCrypto.keyStore.wipeKey()
    }

    private func storedBlob() -> Data? {
        try? TestCrypto.keychain.read(account: TestCrypto.blobAccount, prompt: nil)
    }

    /// Puts a plain item where the biometric item lives.
    private func plantBiometricItem() throws {
        try TestCrypto.keychain.write(Data([1, 2, 3]), account: TestCrypto.biometricAccount, accessibility: .whenUnlocked)
    }

    private func biometricItemExists() -> Bool {
        ((try? TestCrypto.keychain.read(account: TestCrypto.biometricAccount, prompt: nil)) ?? nil) != nil
    }

    private func addEncryptedFile() throws {
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let source = sourceDir.appendingPathComponent("secret.txt")
        try "secret".write(to: source, atomically: true, encoding: .utf8)
        let root = LegacyVaultDirectory(name: "test", diskURL: vaultRoot, rootURL: vaultRoot)
        try FileSystem.shared.importItems(from: [source], to: root)
    }

    // MARK: - createPassword return value

    func testCreatePasswordWithNoBlobReportsANewKey() throws {
        let created = try AuthService.shared.createPassword("password123", vaultRootURL: vaultRoot)
        XCTAssertTrue(created)
        XCTAssertTrue(TestCrypto.keyStore.isKeyLoaded)
    }

    func testCreatePasswordReplacingAStaleBlobInAnEmptyVaultReportsANewKey() throws {
        try TestCrypto.keyStore.createMasterKey(password: "old-password")
        TestCrypto.keyStore.wipeKey()
        let oldBlob = storedBlob()

        let created = try AuthService.shared.createPassword("new-password", vaultRootURL: vaultRoot)

        XCTAssertTrue(created)
        XCTAssertNotEqual(storedBlob(), oldBlob)
    }

    func testCreatePasswordReusingTheBlobOfAnEncryptedVaultReportsNoNewKey() throws {
        try TestCrypto.keyStore.createMasterKey(password: "old-password")
        try addEncryptedFile()
        TestCrypto.keyStore.wipeKey()
        let oldBlob = storedBlob()

        let created = try AuthService.shared.createPassword("old-password", vaultRootURL: vaultRoot)

        XCTAssertFalse(created)
        XCTAssertEqual(storedBlob(), oldBlob)
        XCTAssertTrue(TestCrypto.keyStore.isKeyLoaded)
    }

    // MARK: - rollBackPasswordSetup

    func testRollbackOfANewKeyRemovesBlobAndBiometricItemAndWipesKeyButKeepsLockMode() throws {
        let created = try AuthService.shared.createPassword("password123", vaultRootURL: vaultRoot)
        try plantBiometricItem()
        AuthService.shared.lockMode = .password

        AuthService.shared.rollBackPasswordSetup(createdNewKey: created)

        XCTAssertNil(storedBlob())
        XCTAssertFalse(AuthService.shared.hasPassword())
        XCTAssertFalse(biometricItemExists())
        XCTAssertFalse(TestCrypto.keyStore.isKeyLoaded)
        XCTAssertEqual(AuthService.shared.lockMode, .password, "lock mode is not touched")
    }

    func testRollbackLeavesLockModeNoneAsItWas() throws {
        let created = try AuthService.shared.createPassword("password123", vaultRootURL: vaultRoot)
        AuthService.shared.lockMode = .none

        AuthService.shared.rollBackPasswordSetup(createdNewKey: created)

        XCTAssertEqual(AuthService.shared.lockMode, .none)
        XCTAssertNil(storedBlob())
    }

    func testRollbackOfAKeptKeyKeepsTheBlobSoTheOldPasswordStillUnlocksIt() throws {
        try TestCrypto.keyStore.createMasterKey(password: "old-password")
        try addEncryptedFile()
        TestCrypto.keyStore.wipeKey()
        let oldBlob = try XCTUnwrap(storedBlob())
        let created = try AuthService.shared.createPassword("old-password", vaultRootURL: vaultRoot)
        try plantBiometricItem()

        AuthService.shared.rollBackPasswordSetup(createdNewKey: created)

        XCTAssertEqual(storedBlob(), oldBlob)
        XCTAssertFalse(biometricItemExists())
        XCTAssertFalse(TestCrypto.keyStore.isKeyLoaded)
        XCTAssertNoThrow(try AuthService.shared.verifyPassword("old-password"))
    }

    func testRollbackWithNothingToUndoDoesNotCrash() {
        AuthService.shared.rollBackPasswordSetup(createdNewKey: true)
        AuthService.shared.rollBackPasswordSetup(createdNewKey: false)
        XCTAssertNil(storedBlob())
        XCTAssertFalse(TestCrypto.keyStore.isKeyLoaded)
    }

    // MARK: - enableBiometrics without a key

    func testEnableBiometricsWithNoKeyLoadedThrowsNoKeyLoaded() {
        TestCrypto.keyStore.wipeKey()
        XCTAssertThrowsError(try AuthService.shared.enableBiometrics()) { error in
            XCTAssertEqual(error as? VaultCryptoError, .noKeyLoaded)
        }
        XCTAssertFalse(biometricItemExists())
    }
}
