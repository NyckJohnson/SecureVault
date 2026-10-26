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
        CryptoService.shared.wipeKey()
    }

    private func itemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.KoalaTVault",
            kSecAttrAccount as String: account
        ]
    }

    private func storedBlob() -> Data? {
        var query = itemQuery(account: "com.KoalaTVault.masterKeyBlob")
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = LegacyStorage.current.keychain.copyMatching(query)
        return status == errSecSuccess ? result as? Data : nil
    }

    /// Puts a plain item where the biometric item lives (no access control, so the test can read it).
    private func plantBiometricItem() {
        var attrs = itemQuery(account: "com.KoalaTVault.biometricMasterKey")
        attrs[kSecValueData as String] = Data([1, 2, 3])
        LegacyStorage.current.keychain.delete(matching: itemQuery(account: "com.KoalaTVault.biometricMasterKey"))
        XCTAssertEqual(LegacyStorage.current.keychain.add(attrs), errSecSuccess)
    }

    private func biometricItemExists() -> Bool {
        var query = itemQuery(account: "com.KoalaTVault.biometricMasterKey")
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return LegacyStorage.current.keychain.copyMatching(query).status == errSecSuccess
    }

    private func addEncryptedFile() throws {
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let source = sourceDir.appendingPathComponent("secret.txt")
        try "secret".write(to: source, atomically: true, encoding: .utf8)
        let root = VaultDirectory(name: "test", diskURL: vaultRoot, rootURL: vaultRoot)
        try FileSystem.shared.importItems(from: [source], to: root)
    }

    // MARK: - createPassword return value

    func testCreatePasswordWithNoBlobReportsANewKey() throws {
        let created = try AuthService.shared.createPassword("password123", vaultRootURL: vaultRoot)
        XCTAssertTrue(created)
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
    }

    func testCreatePasswordReplacingAStaleBlobInAnEmptyVaultReportsANewKey() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "old-password")
        CryptoService.shared.wipeKey()
        let oldBlob = storedBlob()

        let created = try AuthService.shared.createPassword("new-password", vaultRootURL: vaultRoot)

        XCTAssertTrue(created)
        XCTAssertNotEqual(storedBlob(), oldBlob)
    }

    func testCreatePasswordReusingTheBlobOfAnEncryptedVaultReportsNoNewKey() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "old-password")
        try addEncryptedFile()
        CryptoService.shared.wipeKey()
        let oldBlob = storedBlob()

        let created = try AuthService.shared.createPassword("old-password", vaultRootURL: vaultRoot)

        XCTAssertFalse(created)
        XCTAssertEqual(storedBlob(), oldBlob)
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
    }

    // MARK: - rollBackPasswordSetup

    func testRollbackOfANewKeyRemovesBlobAndBiometricItemAndWipesKeyButKeepsLockMode() throws {
        let created = try AuthService.shared.createPassword("password123", vaultRootURL: vaultRoot)
        plantBiometricItem()
        AuthService.shared.lockMode = .password

        AuthService.shared.rollBackPasswordSetup(createdNewKey: created)

        XCTAssertNil(storedBlob())
        XCTAssertFalse(AuthService.shared.hasPassword())
        XCTAssertFalse(biometricItemExists())
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)
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
        try CryptoService.shared.createMasterKey(wrappedBy: "old-password")
        try addEncryptedFile()
        CryptoService.shared.wipeKey()
        let oldBlob = try XCTUnwrap(storedBlob())
        let created = try AuthService.shared.createPassword("old-password", vaultRootURL: vaultRoot)
        plantBiometricItem()

        AuthService.shared.rollBackPasswordSetup(createdNewKey: created)

        XCTAssertEqual(storedBlob(), oldBlob)
        XCTAssertFalse(biometricItemExists())
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)
        XCTAssertNoThrow(try AuthService.shared.verifyPassword("old-password"))
    }

    func testRollbackWithNothingToUndoDoesNotCrash() {
        AuthService.shared.rollBackPasswordSetup(createdNewKey: true)
        AuthService.shared.rollBackPasswordSetup(createdNewKey: false)
        XCTAssertNil(storedBlob())
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)
    }

    // MARK: - enableBiometrics without a key

    func testEnableBiometricsWithNoKeyLoadedThrowsNoKeyLoaded() {
        CryptoService.shared.wipeKey()
        XCTAssertThrowsError(try AuthService.shared.enableBiometrics()) { error in
            XCTAssertEqual(error as? CryptoError, .noKeyLoaded)
        }
        XCTAssertFalse(biometricItemExists())
    }
}
