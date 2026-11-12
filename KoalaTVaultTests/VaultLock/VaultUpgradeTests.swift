import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultUpgradeTests {
    private struct Fixture {
        let root: URL
        let documents: URL
        let vaults: URL
        let primary: URL
        let keychain: MockKeychainAccessing
        let preferences: MockPreferencesStoring
        let upgrade: VaultUpgrade

        init(
            lockMode: LockMode = .none,
            pending: Bool = false,
            upgraded: Bool = false,
            hasBlob: Bool = false
        ) throws {
            let manager = FileManager.default
            root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            documents = root.appendingPathComponent("Documents")
            vaults = root.appendingPathComponent("AppSupport").appendingPathComponent("Vaults")
            primary = vaults.appendingPathComponent("primary")
            try manager.createDirectory(at: documents, withIntermediateDirectories: true)
            try manager.createDirectory(
                at: vaults.deletingLastPathComponent(), withIntermediateDirectories: true)
            let items = hasBlob ? [VaultCatalog.blobAccount(for: "primary"): Data([1])] : [:]
            keychain = MockKeychainAccessing(items: items)
            preferences = MockPreferencesStoring(
                lockMode: lockMode, hasPendingEncryptMigration: pending, vaultsUpgraded: upgraded)
            upgrade = VaultUpgrade(
                documents: documents, vaultsFolder: vaults, keychain: keychain, preferences: preferences)
        }

        /// Adds the entries of a typical 1.2 encrypted vault to Documents.
        func populateDocuments() throws {
            let manager = FileManager.default
            try Data("map".utf8).write(to: documents.appendingPathComponent(".vault_map"))
            try Data("file".utf8).write(to: documents.appendingPathComponent("11111111"))
            try manager.createDirectory(
                at: documents.appendingPathComponent(".trash"), withIntermediateDirectories: true)
            try Data("trashmap".utf8).write(
                to: documents.appendingPathComponent(".trash").appendingPathComponent(".trash_map"))
            try manager.createDirectory(
                at: documents.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("inner".utf8).write(to: documents.appendingPathComponent("sub").appendingPathComponent("22"))
        }

        func documentNames() -> [String] {
            let names = try? FileManager.default.contentsOfDirectory(atPath: documents.path)
            return (names ?? []).sorted()
        }

        func primaryNames() -> [String] {
            let names = try? FileManager.default.contentsOfDirectory(atPath: primary.path)
            return (names ?? []).sorted()
        }

        var marker: Data? { keychain.items[VaultCatalog.markerAccount] }
        var primaryExists: Bool { FileManager.default.fileExists(atPath: primary.path) }
    }

    private struct UnchangedCase {
        let mode: LockMode
        let migration: Bool
        let blob: Bool
    }

    private typealias KeychainCall = MockKeychainAccessing.Call
    private static let expectedEntries = [".trash", ".vault_map", "11111111", "sub"]

    // MARK: Already upgraded

    @Test("When vaultsUpgraded is true nothing is touched")
    func alreadyUpgradedTouchesNothing() throws {
        let fixture = try Fixture(
            lockMode: .passwordAndBiometrics, pending: true,
            upgraded: true, hasBlob: true)
        try fixture.populateDocuments()
        try fixture.upgrade.run()
        #expect(fixture.documentNames() == Self.expectedEntries.sorted())
        #expect(!fixture.primaryExists)
        #expect(fixture.marker == nil)
        #expect(fixture.keychain.calls.isEmpty)
        #expect(fixture.preferences.hasPendingEncryptMigration)
        #expect(fixture.preferences.writes.isEmpty)
    }

    // MARK: Lock mode password

    @Test("With a password lock every Documents entry, hidden ones included, moves into Vaults/primary")
    func passwordLockMovesEverything() throws {
        let fixture = try Fixture(lockMode: .password, hasBlob: true)
        try fixture.populateDocuments()
        try fixture.upgrade.run()
        #expect(fixture.primaryNames() == Self.expectedEntries.sorted())
        #expect(fixture.documentNames().isEmpty)
    }

    @Test("Moved folders keep their contents whole")
    func movedFoldersKeepContents() throws {
        let fixture = try Fixture(lockMode: .password, hasBlob: true)
        try fixture.populateDocuments()
        try fixture.upgrade.run()
        let inner = try Data(contentsOf: fixture.primary.appendingPathComponent("sub").appendingPathComponent("22"))
        let trashMap = try Data(
            contentsOf: fixture.primary.appendingPathComponent(".trash").appendingPathComponent(".trash_map"))
        let map = try Data(contentsOf: fixture.primary.appendingPathComponent(".vault_map"))
        #expect(inner == Data("inner".utf8))
        #expect(trashMap == Data("trashmap".utf8))
        #expect(map == Data("map".utf8))
    }

    @Test("With a password lock and an empty Documents the primary folder is still created")
    func passwordLockEmptyDocuments() throws {
        let fixture = try Fixture(lockMode: .password, hasBlob: true)
        try fixture.upgrade.run()
        #expect(fixture.primaryExists)
        #expect(fixture.primaryNames().isEmpty)
        #expect(fixture.preferences.vaultsUpgraded)
    }

    @Test("An entry whose name is already in primary stays in Documents and is not overwritten")
    func existingNameLeftInDocuments() throws {
        let fixture = try Fixture(lockMode: .password, hasBlob: true)
        try fixture.populateDocuments()
        try FileManager.default.createDirectory(at: fixture.primary, withIntermediateDirectories: true)
        try Data("already".utf8).write(to: fixture.primary.appendingPathComponent("11111111"))
        try fixture.upgrade.run()
        #expect(fixture.documentNames() == ["11111111"])
        let kept = try Data(contentsOf: fixture.documents.appendingPathComponent("11111111"))
        #expect(kept == Data("file".utf8))
        let existing = try Data(contentsOf: fixture.primary.appendingPathComponent("11111111"))
        #expect(existing == Data("already".utf8))
        #expect(fixture.primaryNames() == Self.expectedEntries.sorted())
        #expect(fixture.preferences.vaultsUpgraded)
    }

    @Test("passwordAndBiometrics sets the Face ID marker to primary")
    func biometricsLockSetsMarker() throws {
        let fixture = try Fixture(lockMode: .passwordAndBiometrics, hasBlob: true)
        try fixture.populateDocuments()
        try fixture.upgrade.run()
        #expect(fixture.marker == Data("primary".utf8))
        #expect(fixture.primaryNames() == Self.expectedEntries.sorted())
    }

    @Test("A password-only lock sets no marker")
    func passwordLockSetsNoMarker() throws {
        let fixture = try Fixture(lockMode: .password, hasBlob: true)
        try fixture.upgrade.run()
        #expect(fixture.marker == nil)
        let markerWrite = KeychainCall.write(account: VaultCatalog.markerAccount, accessibility: .whenUnlocked)
        #expect(!fixture.keychain.calls.contains(markerWrite))
    }

    // MARK: Pending encrypt

    @Test("A pending encrypt with a blob counts as a lock")
    func pendingEncryptWithBlobIsLock() throws {
        let pending = true
        let fixture = try Fixture(lockMode: .none, pending: pending, hasBlob: true)
        try fixture.populateDocuments()
        try fixture.upgrade.run()
        #expect(fixture.primaryNames() == Self.expectedEntries.sorted())
        #expect(fixture.documentNames().isEmpty)
        #expect(!fixture.preferences.hasPendingEncryptMigration)
        #expect(fixture.preferences.vaultsUpgraded)
        #expect(fixture.marker == nil)
    }

    @Test("A Keychain error reading the blob counts as a blob")
    func keychainErrorCountsAsBlob() throws {
        let pending = true
        let fixture = try Fixture(lockMode: .none, pending: pending, hasBlob: false)
        try fixture.populateDocuments()
        fixture.keychain.errorToThrow = .keychain(-25308)
        try fixture.upgrade.run()
        #expect(fixture.primaryNames() == Self.expectedEntries.sorted())
        #expect(fixture.documentNames().isEmpty)
        #expect(!fixture.preferences.hasPendingEncryptMigration)
        #expect(fixture.preferences.vaultsUpgraded)
    }

    @Test("A pending encrypt with no blob is dropped and nothing moves")
    func pendingEncryptWithoutBlobIsDropped() throws {
        let pending = true
        let fixture = try Fixture(lockMode: .none, pending: pending, hasBlob: false)
        try fixture.populateDocuments()
        try fixture.upgrade.run()
        #expect(fixture.documentNames() == Self.expectedEntries.sorted())
        #expect(!fixture.primaryExists)
        #expect(!fixture.preferences.hasPendingEncryptMigration)
        #expect(fixture.preferences.vaultsUpgraded)
        #expect(fixture.marker == nil)
    }

    // MARK: No lock

    @Test("With no lock vaultsUpgraded is set and nothing moves")
    func noLockSetsFlagOnly() throws {
        let fixture = try Fixture(lockMode: .none, hasBlob: false)
        try fixture.populateDocuments()
        try fixture.upgrade.run()
        #expect(fixture.documentNames() == Self.expectedEntries.sorted())
        #expect(!fixture.primaryExists)
        #expect(fixture.marker == nil)
        #expect(fixture.preferences.vaultsUpgraded)
    }

    // MARK: Ordering and failure

    @Test("vaultsUpgraded is written last, after the pending migration is cleared")
    func upgradedFlagIsLastWrite() throws {
        let pending = true
        let fixture = try Fixture(lockMode: .password, pending: pending, hasBlob: true)
        try fixture.upgrade.run()
        #expect(fixture.preferences.writes.last == .vaultsUpgraded(true))
        let cleared = fixture.preferences.writes.firstIndex(of: .clearPendingMigration)
        let flagged = fixture.preferences.writes.firstIndex(of: .vaultsUpgraded(true))
        #expect(try #require(cleared) < #require(flagged))
    }

    @Test("A lock upgrade with nothing pending still clears once")
    func lockUpgradeWithNothingPendingStillClearsOnce() throws {
        let fixture = try Fixture(lockMode: .password, pending: false, hasBlob: true)
        try fixture.upgrade.run()
        #expect(fixture.preferences.clearPendingMigrationCallCount == 1)
        #expect(fixture.preferences.vaultsUpgraded)
    }

    @Test("A lock upgrade with a pending encrypt clears the pending migration exactly once, before vaultsUpgraded")
    func lockPathClearsOnceBeforeFlag() throws {
        let fixture = try Fixture(lockMode: .none, pending: true, hasBlob: true)
        try fixture.upgrade.run()
        #expect(fixture.preferences.clearPendingMigrationCallCount == 1)
        let writes = fixture.preferences.writes
        let cleared = try #require(writes.firstIndex(of: .clearPendingMigration))
        let flagged = try #require(writes.firstIndex(of: .vaultsUpgraded(true)))
        #expect(cleared < flagged)
    }

    @Test("A pending encrypt with no blob clears the pending migration exactly once, before vaultsUpgraded")
    func noLockPathClearsOnceBeforeFlag() throws {
        let fixture = try Fixture(lockMode: .none, pending: true, hasBlob: false)
        try fixture.upgrade.run()
        #expect(fixture.preferences.clearPendingMigrationCallCount == 1)
        let writes = fixture.preferences.writes
        let cleared = try #require(writes.firstIndex(of: .clearPendingMigration))
        let flagged = try #require(writes.firstIndex(of: .vaultsUpgraded(true)))
        #expect(cleared < flagged)
    }

    @Test("With nothing stored and no lock the pending migration is still cleared exactly once, before vaultsUpgraded")
    func nothingStoredClearsOnceBeforeFlag() throws {
        let fixture = try Fixture(lockMode: .none, pending: false, hasBlob: false)
        try fixture.upgrade.run()
        #expect(fixture.preferences.clearPendingMigrationCallCount == 1)
        let writes = fixture.preferences.writes
        let cleared = try #require(writes.firstIndex(of: .clearPendingMigration))
        let flagged = try #require(writes.firstIndex(of: .vaultsUpgraded(true)))
        #expect(cleared < flagged)
    }

    @Test("When vaultsUpgraded is already true the pending migration is not cleared")
    func alreadyUpgradedDoesNotClear() throws {
        let fixture = try Fixture(lockMode: .none, pending: true, upgraded: true, hasBlob: false)
        try fixture.upgrade.run()
        #expect(fixture.preferences.clearPendingMigrationCallCount == 0)
    }

    @Test("lockMode is unchanged in every case")
    func lockModeUnchanged() throws {
        let pending = true
        let cases = [
            UnchangedCase(mode: .password, migration: false, blob: true),
            UnchangedCase(mode: .passwordAndBiometrics, migration: false, blob: true),
            UnchangedCase(mode: .none, migration: pending, blob: true),
            UnchangedCase(mode: .none, migration: pending, blob: false),
            UnchangedCase(mode: .none, migration: false, blob: false),
        ]
        for item in cases {
            let mode = item.mode
            let fixture = try Fixture(lockMode: mode, pending: item.migration, hasBlob: item.blob)
            try fixture.upgrade.run()
            #expect(fixture.preferences.lockMode == mode)
            #expect(!fixture.preferences.writes.contains { if case .lockMode = $0 { true } else { false } })
        }
    }

    @Test("A failure before the end throws, leaves vaultsUpgraded false and a rerun completes the move")
    func failureThenRerunCompletes() throws {
        let pending = true
        let fixture = try Fixture(lockMode: .password, pending: pending, hasBlob: true)
        try fixture.populateDocuments()
        // A plain file where the Application Support folder should be makes the Vaults folder unwritable.
        let blocker = fixture.vaults.deletingLastPathComponent()
        try FileManager.default.removeItem(at: blocker)
        try Data("block".utf8).write(to: blocker)

        #expect(throws: (any Error).self) { try fixture.upgrade.run() }
        #expect(!fixture.preferences.vaultsUpgraded)
        #expect(fixture.preferences.hasPendingEncryptMigration == pending)
        #expect(fixture.documentNames() == Self.expectedEntries.sorted())

        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try fixture.upgrade.run()
        #expect(fixture.primaryNames() == Self.expectedEntries.sorted())
        #expect(fixture.documentNames().isEmpty)
        #expect(!fixture.preferences.hasPendingEncryptMigration)
        #expect(fixture.preferences.vaultsUpgraded)
    }

    @Test("A rerun after a partial move carries on with what is left")
    func rerunAfterPartialMove() throws {
        let fixture = try Fixture(lockMode: .passwordAndBiometrics, hasBlob: true)
        try fixture.populateDocuments()
        try FileManager.default.createDirectory(at: fixture.primary, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fixture.documents.appendingPathComponent(".vault_map"),
            to: fixture.primary.appendingPathComponent(".vault_map"))
        try fixture.upgrade.run()
        #expect(fixture.primaryNames() == Self.expectedEntries.sorted())
        #expect(fixture.documentNames().isEmpty)
        #expect(fixture.marker == Data("primary".utf8))
        #expect(fixture.preferences.vaultsUpgraded)
    }
}
