//
//  FileSystemMappingIntegrityTests.swift
//  KoalaTVaultTests
//
//  Regression coverage for the mapping-corruption / silent-data-loss bug:
//  previously, a `.vault_map` (or `.trash_map`) file that failed to decrypt/decode
//  (torn write, or read attempted before the key was loaded) was silently treated
//  as an *empty* mapping. Any subsequent save then overwrote the real file with
//  just the entries touched in that operation, permanently losing the rest.
//
//  These tests exercise the fix: loads now throw `FileSystemError.mappingUnreadable`
//  on real corruption (distinct from "no mapping file yet", which is a legitimate
//  empty case), and mutating operations must propagate that error instead of
//  silently proceeding to save.
//
//  NOTE: hardcodes the private mapping filenames (".vault_map" / ".trash_map") to
//  write/corrupt them directly. If FileSystem.swift's `mappingFileName`/`trashMapName`
//  ever change, update these constants to match.
//

import XCTest
@testable import KoalaTVault

final class FileSystemMappingIntegrityTests: XCTestCase {

    private let mappingFileName = ".vault_map"
    private let trashMapFileName = ".trash_map"

    private var testDirectory: VaultDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Isolated scratch folder per test, as its own vault root — trash for anything
        // created here now lives under this temp root, never the real app vault's trash.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrityTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        testDirectory = VaultDirectory(name: "IntegrityTest", diskURL: tempURL, rootURL: tempURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory.diskURL)
        CryptoService.shared.wipeKey()
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var mappingURL: URL {
        testDirectory.diskURL.appendingPathComponent(mappingFileName)
    }

    /// Writes a plaintext (unencrypted) mapping directly to disk, bypassing FileSystem,
    /// to simulate a mapping that already exists on disk before the test runs.
    private func writeRawMapping(_ mapping: [String: VaultMapping]) throws {
        let data = try JSONEncoder().encode(mapping)
        try data.write(to: mappingURL, options: .atomic)
    }

    /// Overwrites the mapping file with bytes that can't decrypt or decode as JSON,
    /// simulating a torn write or reading real ciphertext without the key loaded.
    private func corruptMapping() throws {
        try Data([0x00, 0xFF, 0x13, 0x37, 0xDE, 0xAD]).write(to: mappingURL, options: .atomic)
    }

    private func createDummyFile(named name: String, in directory: VaultDirectory, content: String = "dummy") throws -> URL {
        let url = directory.diskURL.appendingPathComponent(name)
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Absent vs. corrupted mapping

    func testAbsentMappingIsTreatedAsEmpty_NotAnError() throws {
        // No .vault_map file has been written at all — this is the normal case for a
        // brand-new folder and must NOT throw.
        _ = try createDummyFile(named: "plain.txt", in: testDirectory)

        let items = try FileSystem.shared.contents(of: testDirectory)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.isEncrypted, false)
    }

    func testCorruptedMappingThrows_InsteadOfSilentlyAppearingEmpty() throws {
        _ = try createDummyFile(named: "some-uuid-like-name", in: testDirectory)
        try corruptMapping()

        XCTAssertThrowsError(try FileSystem.shared.contents(of: testDirectory)) { error in
            guard case FileSystemError.mappingUnreadable = error else {
                XCTFail("Expected FileSystemError.mappingUnreadable, got \(error)")
                return
            }
        }
    }

    // MARK: - Regression: mutating ops must not overwrite a mapping they failed to read

    func testRename_DoesNotOverwriteMapping_WhenExistingMappingIsCorrupted() throws {
        let keptUUID = UUID().uuidString
        let targetUUID = UUID().uuidString
        _ = try createDummyFile(named: keptUUID, in: testDirectory)
        _ = try createDummyFile(named: targetUUID, in: testDirectory)

        // A real mapping with two entries would have existed here before corruption.
        try writeRawMapping([
            keptUUID: VaultMapping(originalName: "DoNotLose.txt"),
            targetUUID: VaultMapping(originalName: "Original.txt"),
        ])
        try corruptMapping()
        let corruptedBytesBeforeAttempt = try Data(contentsOf: mappingURL)

        let itemToRename = VaultItem(
            id: UUID(), name: "Original.txt", isDirectory: false, dateModified: Date(), fileSize: nil,
            diskURL: testDirectory.diskURL.appendingPathComponent(targetUUID), rootURL: testDirectory.rootURL, isEncrypted: true
        )

        XCTAssertThrowsError(try FileSystem.shared.rename(itemToRename, to: "Renamed.txt")) { error in
            guard case FileSystemError.mappingUnreadable = error else {
                XCTFail("Expected FileSystemError.mappingUnreadable, got \(error)")
                return
            }
        }

        // The critical assertion: the file on disk must be byte-for-byte unchanged.
        // Before the fix, rename() would have loaded the "corrupted" mapping as [:],
        // added just the renamed entry, and saved — permanently losing `keptUUID`.
        let bytesAfterAttempt = try Data(contentsOf: mappingURL)
        XCTAssertEqual(corruptedBytesBeforeAttempt, bytesAfterAttempt,
                        "rename() must not write to a mapping it failed to load")
    }

    func testMove_DoesNotOverwriteDestinationMapping_WhenDestinationMappingIsCorrupted() throws {
        let destination = try FileSystem.shared.createFolder(named: "Destination-\(UUID().uuidString)", in: .root)
        defer { try? FileManager.default.removeItem(at: destination.diskURL) }

        // Destination already has an unrelated encrypted file that must survive the move.
        let survivingUUID = UUID().uuidString
        _ = try createDummyFile(named: survivingUUID, in: destination)
        let destMappingURL = destination.diskURL.appendingPathComponent(mappingFileName)
        try JSONEncoder().encode([survivingUUID: VaultMapping(originalName: "MustSurvive.txt")])
            .write(to: destMappingURL, options: .atomic)
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: destMappingURL, options: .atomic) // corrupt it
        let destBytesBeforeMove = try Data(contentsOf: destMappingURL)

        // Source item being moved has a valid mapping of its own.
        let movingUUID = UUID().uuidString
        _ = try createDummyFile(named: movingUUID, in: testDirectory)
        try writeRawMapping([movingUUID: VaultMapping(originalName: "Moving.txt")])

        let itemToMove = VaultItem(
            id: UUID(), name: "Moving.txt", isDirectory: false, dateModified: Date(), fileSize: nil,
            diskURL: testDirectory.diskURL.appendingPathComponent(movingUUID), rootURL: testDirectory.rootURL, isEncrypted: true
        )

        XCTAssertThrowsError(try FileSystem.shared.move(itemToMove, to: destination)) { error in
            guard case FileSystemError.mappingUnreadable = error else {
                XCTFail("Expected FileSystemError.mappingUnreadable, got \(error)")
                return
            }
        }

        let destBytesAfterMove = try Data(contentsOf: destMappingURL)
        XCTAssertEqual(destBytesBeforeMove, destBytesAfterMove,
                        "move() must not write to a destination mapping it failed to load")
    }

    // MARK: - Trash map: verifying the deliberately-swallowed path stays safe

    func testCleanupExpiredTrashItems_DoesNotThrowOrWipe_WhenTrashMapIsCorrupted() throws {
        let trashMapURL = FileSystem.shared.trashDirectory(for: testDirectory.rootURL).diskURL.appendingPathComponent(trashMapFileName)
        try Data([0x01, 0x02, 0x03]).write(to: trashMapURL, options: .atomic)
        let corruptedBytes = try Data(contentsOf: trashMapURL)

        // Must not throw (it's non-throwing by design) and must not crash.
        FileSystem.shared.cleanupExpiredTrashItems(for: testDirectory)

        // And critically, must not have overwritten the corrupted file with an empty one —
        // per the "safe to swallow" reasoning: a failed read means nothing to remove, so
        // `changed` never becomes true and saveTrashMap is never reached.
        let bytesAfter = try Data(contentsOf: trashMapURL)
        XCTAssertEqual(corruptedBytes, bytesAfter,
                        "cleanupExpiredTrashItems() must not write when the existing map failed to load")
    }

    func testContentsOfTrash_ThrowsOnCorruptedMap_RatherThanReturningEmpty() throws {
        let trashMapURL = FileSystem.shared.trashDirectory(for: testDirectory.rootURL).diskURL.appendingPathComponent(trashMapFileName)
        try Data([0x01, 0x02, 0x03]).write(to: trashMapURL, options: .atomic)

        XCTAssertThrowsError(try FileSystem.shared.contentsOfTrash(for: testDirectory)) { error in
            guard case FileSystemError.mappingUnreadable = error else {
                XCTFail("Expected FileSystemError.mappingUnreadable, got \(error)")
                return
            }
        }
    }

    // MARK: - Migration resume idempotency

    func testFilesToMigrate_ExcludesAlreadyMigratedFiles_OnASecondCall() throws {
        // Mirrors the "kill mid-migration, relaunch, resume" scenario: filesToMigrate must
        // be computed fresh from actual on-disk state each time, not from in-memory progress,
        // so a second call after partial migration only returns the genuine remainder.
        try CryptoService.shared.createMasterKey(wrappedBy: "test-password-\(UUID().uuidString)")
        defer { CryptoService.shared.wipeMasterKeyBlob() }

        _ = try createDummyFile(named: "one.txt", in: testDirectory, content: "content one")
        _ = try createDummyFile(named: "two.txt", in: testDirectory, content: "content two")

        let firstPass = try FileSystem.shared.filesToMigrate(toEncrypted: true, in: testDirectory)
        XCTAssertEqual(firstPass.count, 2, "Both plaintext files should need encryption")

        guard let fileOne = firstPass.first(where: { $0.item.name == "one.txt" }) else {
            return XCTFail("Expected to find one.txt in the pending migration list")
        }
        try FileSystem.shared.migrateFileToEncrypted(fileOne.item, in: fileOne.directory)

        let secondPass = try FileSystem.shared.filesToMigrate(toEncrypted: true, in: testDirectory)
        XCTAssertEqual(secondPass.count, 1, "Already-migrated file must not reappear on a fresh query")
        XCTAssertEqual(secondPass.first?.item.name, "two.txt")
    }

    // MARK: - Save/load round trip smoke test
    //
    // True atomicity (surviving a kill mid-write) isn't practically unit-testable in-process.
    // This just guards against a regression in the round trip itself now that writes pass
    // `options: .atomic`.

    func testMappingRoundTrip_SurvivesSaveAndLoad_ViaRealOperations() throws {
        // isEncrypted: true routes rename() through loadMapping/saveMapping (the .atomic
        // write path) rather than a plain FileManager move — that's the path this smoke
        // test needs to exercise.
        let uuid = UUID().uuidString
        _ = try createDummyFile(named: uuid, in: testDirectory)
        try writeRawMapping([uuid: VaultMapping(originalName: "roundtrip.txt")])

        let item = VaultItem(
            id: UUID(), name: "roundtrip.txt", isDirectory: false, dateModified: Date(), fileSize: nil,
            diskURL: testDirectory.diskURL.appendingPathComponent(uuid), rootURL: testDirectory.rootURL, isEncrypted: true
        )
        try FileSystem.shared.rename(item, to: "renamed-roundtrip.txt")

        let items = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertTrue(items.contains { $0.name == "renamed-roundtrip.txt" && $0.isEncrypted })
    }
}
