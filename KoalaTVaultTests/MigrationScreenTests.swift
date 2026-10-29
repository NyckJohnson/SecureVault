import XCTest
@testable import KoalaTVault

/// A lock migration that publishes a fixed list of phases when `start` is called, for the states the
/// shared mock can't reach (paused, a failure with no file names).
@MainActor
private final class ScriptedLockMigrator: LockMigrating {
    private(set) var phase: MigrationPhase = .idle
    let pending: PendingMigration? = nil
    private let script: [MigrationPhase]
    private var continuation: AsyncStream<MigrationPhase>.Continuation?
    private(set) var startCount = 0

    init(script: [MigrationPhase]) { self.script = script }

    func phaseUpdates() -> AsyncStream<MigrationPhase> {
        AsyncStream { continuation = $0 }
    }

    func start(_ kind: MigrationKind, target: LockMode?) async {
        startCount += 1
        for next in script {
            phase = next
            continuation?.yield(next)
        }
    }

    func resumeIfPending() async {}
    func retryFailed() async {}
    func skipFailed() async {}
}

@MainActor
final class MigrationViewControllerTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() async throws {
        window?.rootViewController?.dismiss(animated: false)
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    private func makeMigration(
        migrator: any LockMigrating,
        onComplete: @escaping (_ completedFully: Bool) -> Void
    ) -> LegacyMigrationViewController {
        LegacyMigrationViewController(
            type: .encrypt, migrator: migrator,
            begin: { await $0.start(.encrypt, target: .password) }, onComplete: onComplete)
    }

    private func presentAndSettle(_ sut: LegacyMigrationViewController) async {
        let window = UIWindow()
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        window.rootViewController?.present(sut, animated: false)

        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        await fulfillment(of: [settle], timeout: 10)
    }

    private var failureMessage: (LegacyMigrationViewController) -> String? {
        { ($0.presentedViewController as? UIAlertController)?.message }
    }

    // MARK: - Full Success
    func testAllFilesSucceedCallsOnCompleteTrue() async throws {
        let done = expectation(description: "complete")
        var result: Bool?
        let sut = makeMigration(migrator: MockLockMigrating()) { completedFully in
            result = completedFully
            done.fulfill()
        }
        await presentAndSettle(sut)
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(result, true)
    }

    // MARK: - Failure Summary / Skip
    func testFailedFileAppearsInSummaryAndSkipCompletesWithFalse() async throws {
        let migrator = MockLockMigrating(failingNames: ["bad.txt"])
        let done = expectation(description: "complete")
        var result: Bool?
        let sut = makeMigration(migrator: migrator) { completedFully in
            result = completedFully
            done.fulfill()
        }
        await presentAndSettle(sut)

        XCTAssertTrue(try XCTUnwrap(failureMessage(sut)).contains("bad.txt"))
        sut.testTapSkip()

        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(result, false)
        XCTAssertTrue(migrator.calls.contains(.skipFailed))
    }

    // MARK: - Retry
    func testRetrySucceedsAfterClearingFailureCondition() async throws {
        let migrator = MockLockMigrating(failingNames: ["flaky.txt"])
        let done = expectation(description: "complete")
        var result: Bool?
        let sut = makeMigration(migrator: migrator) { completedFully in
            result = completedFully
            done.fulfill()
        }
        await presentAndSettle(sut)
        XCTAssertTrue(try XCTUnwrap(failureMessage(sut)).contains("flaky.txt"))

        sut.testTapRetry()

        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(result, true)
        XCTAssertTrue(migrator.calls.contains(.retryFailed))
    }

    // MARK: - Generic failure
    func testFailureWithNoNamesShowsGenericMessage() async throws {
        let migrator = ScriptedLockMigrator(script: [.failed(names: [])])
        let sut = makeMigration(migrator: migrator) { _ in XCTFail("should not complete") }
        await presentAndSettle(sut)

        XCTAssertEqual(
            failureMessage(sut), "The migration couldn't finish. Retry, or Skip to stop for now.")
    }

    // MARK: - Paused
    func testMigrationShowsPausedAndDoesNotComplete() async throws {
        let migrator = ScriptedLockMigrator(script: [.paused(done: 0, total: 1)])
        let sut = makeMigration(migrator: migrator) { _ in XCTFail("should not complete while paused") }
        await presentAndSettle(sut)

        XCTAssertEqual(sut.testStatusText, "Paused — unlock to continue")
    }

    // MARK: - Lock screen dismissed over the migration (baseline fix 15)
    func testReappearingWhilePausedDoesNotBeginAgain() async throws {
        let migrator = ScriptedLockMigrator(script: [.paused(done: 0, total: 1)])
        let sut = makeMigration(migrator: migrator) { _ in XCTFail("should not complete while paused") }
        await presentAndSettle(sut)
        XCTAssertEqual(migrator.startCount, 1)

        sut.viewDidAppear(false)  // the lock screen was dismissed over this screen
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(migrator.startCount, 1, "No second migration loop is started")
        XCTAssertEqual(sut.testStatusText, "Paused — unlock to continue")
    }
}
