import XCTest
@testable import SecureVault

final class MigrationViewControllerTests: XCTestCase {

    var testDirectory: VaultDirectory!

    override func setUp() {
        super.setUp()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        testDirectory = VaultDirectory(name: "test", diskURL: tempURL)
    }

    override func tearDown() {
        super.tearDown()
        CryptoService.shared.wipeKey()
        CryptoService.shared.wipeMasterKeyBlob()
        try? FileManager.default.removeItem(at: testDirectory.diskURL)
        FileSystem.testForcedMigrationFailureFileName = nil
        PreferencesService.shared.pendingMigrationType = nil
        PreferencesService.shared.pendingMigrationTargetLockMode = nil
    }

    private func presentAndWait(_ sut: MigrationViewController, timeout: TimeInterval = 10) -> Bool {
        let window = UIWindow()
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        window.rootViewController?.present(sut, animated: false)

        let expectation = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: timeout)
        return true
    }

    // MARK: - Full Success
    func testAllFilesSucceedCallsOnCompleteTrue() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = testDirectory.diskURL.appendingPathComponent("file.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)

        let done = expectation(description: "complete")
        var result: Bool?
        let sut = MigrationViewController(type: .encrypt, directory: testDirectory) { completedFully in
            result = completedFully
            done.fulfill()
        }
        _ = presentAndWait(sut, timeout: 1)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(result, true)
    }

    // MARK: - Failure Summary / Skip
    func testFailedFileAppearsInSummaryAndSkipCompletesWithFalse() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let goodURL = testDirectory.diskURL.appendingPathComponent("good.txt")
        let badURL = testDirectory.diskURL.appendingPathComponent("bad.txt")
        try "content".write(to: goodURL, atomically: true, encoding: .utf8)
        try "content".write(to: badURL, atomically: true, encoding: .utf8)
        FileSystem.testForcedMigrationFailureFileName = "bad.txt"

        let done = expectation(description: "complete")
        var result: Bool?
        let sut = MigrationViewController(type: .encrypt, directory: testDirectory) { completedFully in
            result = completedFully
            done.fulfill()
        }
        _ = presentAndWait(sut, timeout: 1)

        XCTAssertEqual(sut.testFailedFileNames, ["bad.txt"])
        sut.testTapSkip()

        wait(for: [done], timeout: 10)
        XCTAssertEqual(result, false)
    }

    // MARK: - Retry
    func testRetrySucceedsAfterClearingFailureCondition() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = testDirectory.diskURL.appendingPathComponent("flaky.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        FileSystem.testForcedMigrationFailureFileName = "flaky.txt"

        let done = expectation(description: "complete")
        var result: Bool?
        let sut = MigrationViewController(type: .encrypt, directory: testDirectory) { completedFully in
            result = completedFully
            done.fulfill()
        }
        _ = presentAndWait(sut, timeout: 1)
        XCTAssertEqual(sut.testFailedFileNames, ["flaky.txt"])

        FileSystem.testForcedMigrationFailureFileName = nil  // clear the injected failure before retrying
        sut.testTapRetry()

        wait(for: [done], timeout: 10)
        XCTAssertEqual(result, true)
    }

    // MARK: - Pause on Key Loss
    func testMigrationPausesWhenKeyIsWiped() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = testDirectory.diskURL.appendingPathComponent("file.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        CryptoService.shared.wipeKey()  // key gone before migration ever starts

        let sut = MigrationViewController(type: .encrypt, directory: testDirectory) { _ in
            XCTFail("should not complete while paused")
        }
        _ = presentAndWait(sut)

        XCTAssertTrue(sut.testIsPaused)
        XCTAssertEqual(sut.testStatusText, "Paused — unlock to continue")
    }

    // MARK: - Resume After Unlock
    func testMigrationResumesOnUnlockNotification() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let url = testDirectory.diskURL.appendingPathComponent("file.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        CryptoService.shared.wipeKey()  // start already keyless, so it pauses immediately

        let done = expectation(description: "complete")
        let sut = MigrationViewController(type: .encrypt, directory: testDirectory) { completedFully in
            XCTAssertTrue(completedFully)
            done.fulfill()
        }
        _ = presentAndWait(sut, timeout: 1)
        XCTAssertTrue(sut.testIsPaused)

        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        NotificationCenter.default.post(name: AuthService.vaultUnlockedNotification, object: nil)

        wait(for: [done], timeout: 10)
    }
}
