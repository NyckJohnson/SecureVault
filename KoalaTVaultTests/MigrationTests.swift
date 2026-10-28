import XCTest
@testable import KoalaTVault

final class MigrationViewControllerTests: VaultTestCase {

    override func tearDown() {
        FileSystem.testForcedMigrationFailureFileName = nil
        LegacyStorage.current.preferences.pendingMigration = nil
        super.tearDown()
    }

    private func presentAndWait(_ sut: LegacyMigrationViewController, timeout: TimeInterval = 10) -> Bool {
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
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        let url = testDirectory.diskURL.appendingPathComponent("file.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)

        let done = expectation(description: "complete")
        var result: Bool?
        let sut = LegacyMigrationViewController(type: .encrypt, directory: testDirectory) { completedFully in
            result = completedFully
            done.fulfill()
        }
        _ = presentAndWait(sut, timeout: 1)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(result, true)
    }

    // MARK: - Failure Summary / Skip
    func testFailedFileAppearsInSummaryAndSkipCompletesWithFalse() throws {
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        let goodURL = testDirectory.diskURL.appendingPathComponent("good.txt")
        let badURL = testDirectory.diskURL.appendingPathComponent("bad.txt")
        try "content".write(to: goodURL, atomically: true, encoding: .utf8)
        try "content".write(to: badURL, atomically: true, encoding: .utf8)
        FileSystem.testForcedMigrationFailureFileName = "bad.txt"

        let done = expectation(description: "complete")
        var result: Bool?
        let sut = LegacyMigrationViewController(type: .encrypt, directory: testDirectory) { completedFully in
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
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        let url = testDirectory.diskURL.appendingPathComponent("flaky.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        FileSystem.testForcedMigrationFailureFileName = "flaky.txt"

        let done = expectation(description: "complete")
        var result: Bool?
        let sut = LegacyMigrationViewController(type: .encrypt, directory: testDirectory) { completedFully in
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
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        let url = testDirectory.diskURL.appendingPathComponent("file.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        TestCrypto.keyStore.wipeKey()  // key gone before migration ever starts

        let sut = LegacyMigrationViewController(type: .encrypt, directory: testDirectory) { _ in
            XCTFail("should not complete while paused")
        }
        _ = presentAndWait(sut)

        XCTAssertTrue(sut.testIsPaused)
        XCTAssertEqual(sut.testStatusText, "Paused — unlock to continue")
    }

    // MARK: - Resume After Unlock
    func testMigrationResumesOnUnlockNotification() throws {
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        let url = testDirectory.diskURL.appendingPathComponent("file.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        TestCrypto.keyStore.wipeKey()  // start already keyless, so it pauses immediately

        let done = expectation(description: "complete")
        let sut = LegacyMigrationViewController(type: .encrypt, directory: testDirectory) { completedFully in
            XCTAssertTrue(completedFully)
            done.fulfill()
        }
        _ = presentAndWait(sut, timeout: 1)
        XCTAssertTrue(sut.testIsPaused)

        try TestCrypto.keyStore.unlock(password: "testpassword")
        NotificationCenter.default.post(name: AuthService.vaultUnlockedNotification, object: nil)

        wait(for: [done], timeout: 10)
    }

    // MARK: - Lock screen dismissed over the migration (baseline fix 15)
    func testReappearingWhilePausedDoesNotRestartAndUnlockCompletesOnce() throws {
        try TestCrypto.keyStore.createMasterKey(password: "testpassword")
        let url = testDirectory.diskURL.appendingPathComponent("file.txt")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        TestCrypto.keyStore.wipeKey()  // paused before any file is migrated

        let done = expectation(description: "complete once")
        done.assertForOverFulfill = true
        var results: [Bool] = []
        let sut = LegacyMigrationViewController(type: .encrypt, directory: testDirectory) { completedFully in
            results.append(completedFully)
            done.fulfill()
        }
        _ = presentAndWait(sut, timeout: 1)
        XCTAssertTrue(sut.testIsPaused)
        let originalTask = try XCTUnwrap(sut.testMigrationTask)

        sut.viewDidAppear(false)  // the lock screen was dismissed over this screen

        XCTAssertEqual(sut.testMigrationTask, originalTask, "No second migration loop is started")
        XCTAssertTrue(sut.testIsPaused)

        try TestCrypto.keyStore.unlock(password: "testpassword")
        NotificationCenter.default.post(name: AuthService.vaultUnlockedNotification, object: nil)

        wait(for: [done], timeout: 10)
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settle.fulfill() }
        wait(for: [settle], timeout: 5)

        XCTAssertEqual(results, [true])
        XCTAssertTrue(sut.testFailedFileNames.isEmpty)
        XCTAssertNil(sut.presentedViewController, "No failure alert")
        XCTAssertTrue(try FileSystem.shared.filesToMigrate(toEncrypted: true, in: testDirectory).isEmpty)
    }
}
