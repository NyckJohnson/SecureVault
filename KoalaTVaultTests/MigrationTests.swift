import XCTest
import os
@testable import KoalaTVault

/// A vault store that forwards everything to `base`, except that migrating the file named
/// `failingFileName` fails with `VaultCryptoError.encryptionFailed` while it is set. Unlike the app's
/// `FailingMigrationVaultStore` (a fixed name for `-uiTesting`), the name can be cleared mid-test so a
/// retry can succeed.
final class ToggleableFailingVaultStore: VaultStoring, @unchecked Sendable {
    private let base: any VaultStoring
    private let failingName = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(base: any VaultStoring) { self.base = base }

    var failingFileName: String? {
        get { failingName.withLock { $0 } }
        set { failingName.withLock { $0 = newValue } }
    }

    var root: VaultDirectory { base.root }

    private func throwIfFailing(_ item: VaultItem) throws {
        if let name = failingFileName, item.name == name { throw VaultCryptoError.encryptionFailed }
    }

    func migrateToEncrypted(_ item: VaultItem) async throws {
        try throwIfFailing(item)
        try await base.migrateToEncrypted(item)
    }

    func migrateToDecrypted(_ item: VaultItem) async throws {
        try throwIfFailing(item)
        try await base.migrateToDecrypted(item)
    }

    func contents(of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection) async throws -> [VaultItem] {
        try await base.contents(of: directory, sortedBy: option, direction)
    }
    func open(_ item: VaultItem) async throws -> URL { try await base.open(item) }
    func write(_ data: Data, to item: VaultItem) async throws { try await base.write(data, to: item) }
    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await base.createFolder(named: name, in: directory)
    }
    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await base.createDocument(named: name, in: directory)
    }
    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem {
        try await base.addFile(from: source, named: name, to: directory)
    }
    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem? {
        try await base.findItem(named: name, in: directory)
    }
    func move(_ item: VaultItem, to directory: VaultDirectory) async throws { try await base.move(item, to: directory) }
    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem {
        try await base.copy(item, to: directory)
    }
    func rename(_ item: VaultItem, to name: String) async throws -> VaultItem { try await base.rename(item, to: name) }
    func moveToTrash(_ item: VaultItem) async throws { try await base.moveToTrash(item) }
    func trashContents() async throws -> [VaultItem] { try await base.trashContents() }
    func restore(_ trashed: VaultItem) async throws -> VaultItem { try await base.restore(trashed) }
    func deletePermanently(_ trashed: VaultItem) async throws { try await base.deletePermanently(trashed) }
    func emptyTrash() async { await base.emptyTrash() }
    func purgeExpiredTrash(now: Date) async throws -> Int { try await base.purgeExpiredTrash(now: now) }
    func countFiles() async throws -> Int { try await base.countFiles() }
    func itemsToMigrate(toEncrypted: Bool) async throws -> [VaultItem] {
        try await base.itemsToMigrate(toEncrypted: toEncrypted)
    }
    func finishDecryption() async throws { try await base.finishDecryption() }
    func finishEncryption() async throws { try await base.finishEncryption() }
    func hasUnencryptedFiles() async throws -> Bool { try await base.hasUnencryptedFiles() }
    func keyMatchesVault() async -> Bool { await base.keyMatchesVault() }
    func sweepOrphans() async { await base.sweepOrphans() }
    func makeTempDirectory() throws -> URL { try base.makeTempDirectory() }
    func removeTemporary(_ url: URL) { base.removeTemporary(url) }
    func removeAllTemporaryFiles() { base.removeAllTemporaryFiles() }
}

@MainActor
final class MigrationViewControllerTests: XCTestCase {

    private var harness: LegacyVaultHarness!
    private var store: ToggleableFailingVaultStore!

    override func setUp() async throws {
        try await super.setUp()
        harness = try LegacyVaultHarness()
        store = ToggleableFailingVaultStore(base: harness.store)
    }

    override func tearDown() async throws {
        LegacyStorage.current.preferences.pendingMigration = nil
        harness.cleanUp()
        harness = nil
        store = nil
        try await super.tearDown()
    }

    /// Adds a lock (a key, and the store in encrypted mode), the starting point of an encrypt migration.
    private func lockVault() throws {
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        harness.preferences.lockMode = .password
    }

    private func makeMigration(
        onComplete: @escaping (_ completedFully: Bool) -> Void
    ) -> LegacyMigrationViewController {
        LegacyMigrationViewController(type: .encrypt, vaultStore: store, onComplete: onComplete)
    }

    private func presentAndWait(_ sut: LegacyMigrationViewController, timeout: TimeInterval = 10) async -> Bool {
        let window = UIWindow()
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        window.rootViewController?.present(sut, animated: false)

        let expectation = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: timeout)
        return true
    }

    // MARK: - Full Success
    func testAllFilesSucceedCallsOnCompleteTrue() async throws {
        try lockVault()
        try harness.diskFile("file.txt", "content")

        let done = expectation(description: "complete")
        var result: Bool?
        let sut = makeMigration { completedFully in
            result = completedFully
            done.fulfill()
        }
        _ = await presentAndWait(sut, timeout: 1)
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(result, true)
    }

    // MARK: - Failure Summary / Skip
    func testFailedFileAppearsInSummaryAndSkipCompletesWithFalse() async throws {
        try lockVault()
        try harness.diskFile("good.txt", "content")
        try harness.diskFile("bad.txt", "content")
        store.failingFileName = "bad.txt"

        let done = expectation(description: "complete")
        var result: Bool?
        let sut = makeMigration { completedFully in
            result = completedFully
            done.fulfill()
        }
        _ = await presentAndWait(sut, timeout: 1)

        XCTAssertEqual(sut.testFailedFileNames, ["bad.txt"])
        sut.testTapSkip()

        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(result, false)
    }

    // MARK: - Retry
    func testRetrySucceedsAfterClearingFailureCondition() async throws {
        try lockVault()
        try harness.diskFile("flaky.txt", "content")
        store.failingFileName = "flaky.txt"

        let done = expectation(description: "complete")
        var result: Bool?
        let sut = makeMigration { completedFully in
            result = completedFully
            done.fulfill()
        }
        _ = await presentAndWait(sut, timeout: 1)
        XCTAssertEqual(sut.testFailedFileNames, ["flaky.txt"])

        store.failingFileName = nil  // clear the injected failure before retrying
        sut.testTapRetry()

        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(result, true)
    }

    // MARK: - Pause on Key Loss
    func testMigrationPausesWhenKeyIsWiped() async throws {
        try lockVault()
        try harness.diskFile("file.txt", "content")
        TestCrypto.keyStore.wipeKey()  // key gone before migration ever starts

        let sut = makeMigration { _ in
            XCTFail("should not complete while paused")
        }
        _ = await presentAndWait(sut)

        XCTAssertTrue(sut.testIsPaused)
        XCTAssertEqual(sut.testStatusText, "Paused — unlock to continue")
    }

    // MARK: - Resume After Unlock
    func testMigrationResumesOnUnlockNotification() async throws {
        try lockVault()
        try harness.diskFile("file.txt", "content")
        TestCrypto.keyStore.wipeKey()  // start already keyless, so it pauses immediately

        let done = expectation(description: "complete")
        let sut = makeMigration { completedFully in
            XCTAssertTrue(completedFully)
            done.fulfill()
        }
        _ = await presentAndWait(sut, timeout: 1)
        XCTAssertTrue(sut.testIsPaused)

        try TestCrypto.keyStore.unlock(password: "testpassword")
        NotificationCenter.default.post(name: AuthService.vaultUnlockedNotification, object: nil)

        await fulfillment(of: [done], timeout: 10)
    }

    // MARK: - Lock screen dismissed over the migration (baseline fix 15)
    func testReappearingWhilePausedDoesNotRestartAndUnlockCompletesOnce() async throws {
        try lockVault()
        try harness.diskFile("file.txt", "content")
        TestCrypto.keyStore.wipeKey()  // paused before any file is migrated

        let done = expectation(description: "complete once")
        done.assertForOverFulfill = true
        var results: [Bool] = []
        let sut = makeMigration { completedFully in
            results.append(completedFully)
            done.fulfill()
        }
        _ = await presentAndWait(sut, timeout: 1)
        XCTAssertTrue(sut.testIsPaused)
        let originalTask = try XCTUnwrap(sut.testMigrationTask)

        sut.viewDidAppear(false)  // the lock screen was dismissed over this screen

        XCTAssertEqual(sut.testMigrationTask, originalTask, "No second migration loop is started")
        XCTAssertTrue(sut.testIsPaused)

        try TestCrypto.keyStore.unlock(password: "testpassword")
        NotificationCenter.default.post(name: AuthService.vaultUnlockedNotification, object: nil)

        await fulfillment(of: [done], timeout: 10)
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settle.fulfill() }
        await fulfillment(of: [settle], timeout: 5)

        XCTAssertEqual(results, [true])
        XCTAssertTrue(sut.testFailedFileNames.isEmpty)
        XCTAssertNil(sut.presentedViewController, "No failure alert")
        let remaining = try await store.itemsToMigrate(toEncrypted: true)
        XCTAssertTrue(remaining.isEmpty)
    }
}
