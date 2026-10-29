//
//  MigrationFinalizationTests.swift
//  KoalaTVault
//
//  The end of a legacy migration run (`LegacyMigrationCompletion.finalize`), against a mock vault lock.
//

import XCTest
@testable import KoalaTVault

@MainActor
final class MigrationFinalizationTests: XCTestCase {

    func testFinalizeEncryptSetsTargetLockModeOnSuccess() async throws {
        // The lock was added before the encryption started, so the lock mode already is the target.
        let lock = MockVaultLocking(lockMode: .password)
        try await LegacyMigrationCompletion.finalize(type: .encrypt, completedFully: true, vaultLock: lock)
        XCTAssertEqual(lock.lockMode, .password)
        XCTAssertFalse(lock.calls.contains(.removeKeysAfterDecryption))
    }

    func testFinalizeEncryptDoesNotSetLockModeOnFailure() async throws {
        let lock = MockVaultLocking(lockMode: .none, password: nil)
        try await LegacyMigrationCompletion.finalize(type: .encrypt, completedFully: false, vaultLock: lock)
        XCTAssertEqual(lock.lockMode, .none)
        XCTAssertTrue(lock.calls.isEmpty)
    }

    func testFinalizeDecryptClearsStateOnSuccess() async throws {
        let lock = MockVaultLocking(lockMode: .password, password: "testpassword")
        try await LegacyMigrationCompletion.finalize(type: .decrypt, completedFully: true, vaultLock: lock)
        XCTAssertEqual(lock.calls, [.removeKeysAfterDecryption])
        XCTAssertEqual(lock.lockMode, .none)
        XCTAssertNil(lock.password)
    }

    func testFinalizeDecryptKeepsStateOnFailure() async throws {
        let lock = MockVaultLocking(lockMode: .password, password: "testpassword")
        try await LegacyMigrationCompletion.finalize(type: .decrypt, completedFully: false, vaultLock: lock)
        XCTAssertEqual(lock.lockMode, .password)
        XCTAssertEqual(lock.password, "testpassword")
        XCTAssertTrue(lock.calls.isEmpty)
    }
}
