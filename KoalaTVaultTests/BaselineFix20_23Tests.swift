import XCTest
@testable import KoalaTVault

// Regression tests for adoption baseline fixes 20 and 23 (docs/adopt/baseline-fixes.md).

// MARK: - Fix 23: the encrypt migration survives the key being wiped; a stuck vault recovers
// (The store-level steps are VaultStore's migration steps; these run them against the real key store and cipher.)
final class EncryptMigrationSafetyTests: XCTestCase {

    private var harness: LegacyVaultHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try LegacyVaultHarness()
    }

    override func tearDown() async throws {
        harness.cleanUp()
        harness = nil
        LegacyStorage.current.preferences.pendingMigration = nil
        try await super.tearDown()
    }

    private var store: LiveVaultStore { harness.store }
    private var mapURL: URL { harness.rootURL.appendingPathComponent(".vault_map") }

    /// Adds a lock: a key exists and the store is in encrypted mode (the encrypt migration's starting point).
    private func lockVault() throws {
        try TestCrypto.keyStore.createMasterKey(password: "pw")
        harness.preferences.lockMode = .password
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        try harness.diskFile(name, content)
    }

    private func plaintextItems() async throws -> [VaultItem] {
        try await store.itemsToMigrate(toEncrypted: true)
    }

    func testMigratingAFileEncryptsItAndRemovesThePlaintext() async throws {
        try lockVault()
        let url = try write("a.txt", "alpha")
        let entryValue = try await plaintextItems().first
        let entry = try XCTUnwrap(entryValue)

        try await store.migrateToEncrypted(entry)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let items = try await harness.items()
        XCTAssertEqual(items.map(\.name), ["a.txt"])
        XCTAssertTrue(items[0].isEncrypted)
        let opened = try await harness.content(of: items[0])
        XCTAssertEqual(opened, "alpha")
    }

    func testMigratingWithoutKeyThrowsKeepsPlaintextAndWritesNoPlaintextIndex() async throws {
        try lockVault()
        let url = try write("a.txt", "alpha")
        let entryValue = try await plaintextItems().first
        let entry = try XCTUnwrap(entryValue)
        TestCrypto.keyStore.wipeKey()

        do {
            try await store.migrateToEncrypted(entry)
            XCTFail("expected migrateToEncrypted to throw")
        } catch {
            XCTAssertEqual(error as? VaultStoreError, .locked)
        }

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "alpha")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapURL.path), "no index of any kind written")
        let others = try FileManager.default.contentsOfDirectory(atPath: harness.rootURL.path)
        XCTAssertEqual(others, ["a.txt"], "no stray encrypted copy left")
    }

    func testMigrationWithKeyWipedLeavesNoReadablePlaintextIndexAfterPartialFolder() async throws {
        try lockVault()
        _ = try write("a.txt", "alpha")
        _ = try write("b.txt", "beta")
        let entries = try await plaintextItems()
        try await store.migrateToEncrypted(entries[0])
        TestCrypto.keyStore.wipeKey()  // device locks mid-folder
        do {
            try await store.migrateToEncrypted(entries[1])
            XCTFail("expected migrateToEncrypted to throw")
        } catch {}

        let data = try Data(contentsOf: mapURL)
        XCTAssertFalse(LegacyVaultHarness.isPlaintextJSON(data), "the index on disk is never plaintext JSON")
    }

    func testResumeAfterKeyWipeFinishesTheFolder() async throws {
        try lockVault()
        _ = try write("a.txt", "alpha")
        _ = try write("b.txt", "beta")
        _ = try write("c.txt", "gamma")
        let first = try await plaintextItems()
        try await store.migrateToEncrypted(first[0])
        TestCrypto.keyStore.wipeKey()
        for entry in first.dropFirst() {
            do {
                try await store.migrateToEncrypted(entry)
                XCTFail("expected migrateToEncrypted to throw")
            } catch {}
        }
        try TestCrypto.keyStore.unlock(password: "pw")

        for entry in try await plaintextItems() {
            try await store.migrateToEncrypted(entry)
        }

        let remaining = try await plaintextItems()
        XCTAssertTrue(remaining.isEmpty)
        let items = try await harness.items()
        XCTAssertEqual(Set(items.map(\.name)), ["a.txt", "b.txt", "c.txt"])
        XCTAssertTrue(items.allSatisfy(\.isEncrypted))
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: harness.rootURL.path)
        XCTAssertFalse(onDisk.contains("a.txt") || onDisk.contains("b.txt") || onDisk.contains("c.txt"))
    }

    func testLegacyPlaintextIndexIsRecoveredAndReEncrypted() async throws {
        try lockVault()
        // An older build left a plaintext index next to its encrypted copy.
        _ = try write("a.txt", "alpha")
        let entryValue = try await plaintextItems().first
        let entry = try XCTUnwrap(entryValue)
        try await store.migrateToEncrypted(entry)
        let encryptedItemValue = try await harness.items().first
        let encryptedItem = try XCTUnwrap(encryptedItemValue)
        let uuid = encryptedItem.diskURL.lastPathComponent
        let plaintextIndex = try JSONSerialization.data(withJSONObject: [uuid: ["originalName": "a.txt"]])
        try plaintextIndex.write(to: mapURL, options: .atomic)

        // The plaintext index still lists the file.
        let items = try await harness.items()
        XCTAssertEqual(items.map(\.name), ["a.txt"])
        XCTAssertTrue(items[0].isEncrypted)

        try await store.finishEncryption()

        XCTAssertFalse(LegacyVaultHarness.isPlaintextJSON(try Data(contentsOf: mapURL)), "index is no longer plaintext")
        let names = try await harness.items().map(\.name)
        XCTAssertEqual(names, ["a.txt"])
    }

    func testFinishEncryptionRecursesIntoSubfolders() async throws {
        try lockVault()
        let sub = try await harness.folder("Sub")
        let subMap = sub.diskURL.appendingPathComponent(".vault_map")
        let plain = try JSONSerialization.data(withJSONObject: ["X": ["originalName": "x.txt"]])
        try plain.write(to: subMap)

        try await store.finishEncryption()

        XCTAssertFalse(LegacyVaultHarness.isPlaintextJSON(try Data(contentsOf: subMap)))
    }

    func testFinishEncryptionWithoutKeyThrowsLocked() async throws {
        try lockVault()
        TestCrypto.keyStore.wipeKey()
        do {
            try await store.finishEncryption()
            XCTFail("expected finishEncryption to throw")
        } catch {
            XCTAssertEqual(error as? VaultStoreError, .locked)
        }
    }

    func testRerunDeletesLeftoverPlaintextWhenEncryptedCopyMatchesByteForByte() async throws {
        try lockVault()
        _ = try write("a.txt", "same content")
        let entryValue = try await plaintextItems().first
        let entry = try XCTUnwrap(entryValue)
        try await store.migrateToEncrypted(entry)
        // A crash before the delete left the plaintext behind.
        let leftover = try write("a.txt", "same content")
        let rerunValue = try await plaintextItems().first
        let rerun = try XCTUnwrap(rerunValue)

        try await store.migrateToEncrypted(rerun)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        let items = try await harness.items()
        XCTAssertEqual(items.map(\.name), ["a.txt"], "no duplicate was made")
    }

    func testRerunKeepsDifferingSameNamePlaintextAndEncryptsItUnderAFreeName() async throws {
        try lockVault()
        _ = try write("a.txt", "original")
        let entryValue = try await plaintextItems().first
        let entry = try XCTUnwrap(entryValue)
        try await store.migrateToEncrypted(entry)
        _ = try write("a.txt", "something else entirely")
        let rerunValue = try await plaintextItems().first
        let rerun = try XCTUnwrap(rerunValue)

        try await store.migrateToEncrypted(rerun)

        // Never silently dropped: both contents survive, under different visible names.
        let items = try await harness.items()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.name)).count, 2)
        var contents: Set<String> = []
        for item in items { contents.insert(try await harness.content(of: item)) }
        XCTAssertEqual(contents, ["original", "something else entirely"])
    }

    func testRerunKeepsSameSizeDifferentPlaintextInsteadOfDeletingIt() async throws {
        try lockVault()
        _ = try write("a.txt", "AAAAAAAA")
        let entryValue = try await plaintextItems().first
        let entry = try XCTUnwrap(entryValue)
        try await store.migrateToEncrypted(entry)
        _ = try write("a.txt", "BBBBBBBB")  // same length, different bytes
        let rerunValue = try await plaintextItems().first
        let rerun = try XCTUnwrap(rerunValue)

        try await store.migrateToEncrypted(rerun)

        var contents: Set<String> = []
        for item in try await harness.items() { contents.insert(try await harness.content(of: item)) }
        XCTAssertEqual(contents, ["AAAAAAAA", "BBBBBBBB"])
    }
}

// MARK: - Fix 23: a pending encrypt is recoverable at launch
@MainActor
final class PendingEncryptionLaunchTests: XCTestCase {

    private func makeAuthService(
        password: String?, pending: PendingMigration?
    ) -> (AuthService, MockVaultLocking, MockPreferencesStoring) {
        let lock = MockVaultLocking(lockMode: .none, password: password)
        let preferences = MockPreferencesStoring(lockMode: .none, pendingMigration: pending)
        let service = AuthService(
            vaultLock: lock, preferences: preferences, keyStore: MockMasterKeyStoring(password: password))
        return (service, lock, preferences)
    }

    func testPendingEncryptWithoutAPasswordIsDroppedAndLaunchStaysUnlocked() throws {
        let (service, lock, preferences) = makeAuthService(
            password: nil, pending: PendingMigration(kind: .encrypt, targetLockMode: .password))

        let showedLockScreen = service.handleInitialLaunch(in: nil)

        XCTAssertNil(preferences.pendingMigration)
        XCTAssertEqual(preferences.lockMode, .none)
        XCTAssertFalse(showedLockScreen)
        XCTAssertEqual(lock.state, .open)
        XCTAssertTrue(lock.calls.contains(.appWillEnterForeground), "the lock is told to refresh its state")
    }

    func testPendingEncryptWithAPasswordAsksForItEvenWhenLockModeWasNeverSaved() throws {
        let (service, _, preferences) = makeAuthService(
            password: "password123", pending: PendingMigration(kind: .encrypt, targetLockMode: .password))

        let showedLockScreen = service.handleInitialLaunch(in: nil)

        XCTAssertTrue(showedLockScreen)
        XCTAssertEqual(preferences.pendingMigration?.kind, .encrypt, "pending encrypt is kept")
    }

    func testNoPendingMigrationAndNoLockLaunchesUnlocked() throws {
        let (service, _, _) = makeAuthService(password: nil, pending: nil)
        XCTAssertFalse(service.handleInitialLaunch(in: nil))
    }
}
