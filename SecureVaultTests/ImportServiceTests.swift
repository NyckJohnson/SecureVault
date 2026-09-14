//
//  ImportServiceTests.swift
//  SecureVaultTests
//

import XCTest
@testable import SecureVault

final class FakeCameraRollDeleter: CameraRollDeleting {
    private(set) var deletedIdentifiers: [String]?
    private(set) var deleteCallCount = 0

    func deleteAssets(withIdentifiers identifiers: [String]) {
        deletedIdentifiers = identifiers
        deleteCallCount += 1
    }
}

final class ImportServiceTests: XCTestCase {
    var sut: ImportService!
    var fakeDeleter: FakeCameraRollDeleter!

    override func setUp() {
        super.setUp()
        sut = ImportService()
        fakeDeleter = FakeCameraRollDeleter()
        sut.cameraRollDeleter = fakeDeleter
    }

    override func tearDown() {
        sut = nil
        fakeDeleter = nil
        super.tearDown()
    }

    // MARK: - confirmDeleteFromCameraRoll

    func testConfirmDelete_forwardsIdentifiersToDeleter() {
        sut.confirmDeleteFromCameraRoll(identifiers: ["asset-1", "asset-2"])

        XCTAssertEqual(fakeDeleter.deleteCallCount, 1)
        XCTAssertEqual(fakeDeleter.deletedIdentifiers, ["asset-1", "asset-2"])
    }

    func testConfirmDelete_withEmptyIdentifiers_stillCallsDeleterWithEmptyArray() {
        // confirmDeleteFromCameraRoll itself has no guard; the empty-array guard
        // lives in promptDeleteFromCameraRoll before the alert is ever shown.
        sut.confirmDeleteFromCameraRoll(identifiers: [])

        XCTAssertEqual(fakeDeleter.deleteCallCount, 1)
        XCTAssertEqual(fakeDeleter.deletedIdentifiers, [])
    }
}
