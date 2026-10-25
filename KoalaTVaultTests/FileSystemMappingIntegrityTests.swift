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
        try? CryptoService.shared.wipeMasterKeyBlob()
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

    /// Writes an *encrypted* mapping using the given AES-GCM AAD domain, bypassing FileSystem.
    /// Used to simulate maps written by different code eras (empty-AAD, relative-path, etc.).
    private func writeEncryptedMapping(_ mapping: [String: VaultMapping], authenticating domain: String, in directory: VaultDirectory) throws {
        let data = try JSONEncoder().encode(mapping)
        let encrypted = try CryptoService.shared.encrypt(data: data, authenticating: domain)
        try encrypted.write(to: directory.diskURL.appendingPathComponent(mappingFileName), options: .atomic)
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
            targetUUID: VaultMapping(originalName: "Original.txt")
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
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

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

    // MARK: - sweepOrphanedEncryptedFiles: pre-auth safety
    //
    // The critical invariant: the sweep must never delete files when it cannot read
    // the mapping. On an encrypted vault the mapping is ciphertext that can only be
    // decoded after the user authenticates. If the sweep runs at launch — before auth
    // — loadMapping throws, and the guard-let must bail rather than falling back to
    // an empty dict (which would make every encrypted file look like an orphan).

    func testSweepPreservesEncryptedFilesWhenKeyIsNotLoaded() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-preauth-\(UUID()).txt")
        try "content".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first(where: { !$0.isDirectory }))
        XCTAssertTrue(item.isEncrypted)

        // Wipe the key — this is the state the sweep runs in at app launch, before the
        // user has authenticated. Without the key, loadMapping cannot decrypt the map.
        CryptoService.shared.wipeKey()
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)

        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: item.diskURL.path),
                      "Sweep must not delete mapped encrypted files when the key is not loaded")
    }

    func testSweepPreservesEncryptedFilesInSubdirectoryWhenKeyIsNotLoaded() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        let subFolder = try FileSystem.shared.createFolder(named: "SubFolder", in: testDirectory)

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-subdir-preauth-\(UUID()).txt")
        try "data".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: subFolder)
        let item = try XCTUnwrap(try FileSystem.shared.contents(of: subFolder).first(where: { !$0.isDirectory }))
        XCTAssertTrue(item.isEncrypted)

        CryptoService.shared.wipeKey()
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)

        // Sweep from the root — it recurses into SubFolder. Without the key, the
        // subfolder's mapping is also unreadable; sweep must bail for that directory too.
        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: item.diskURL.path),
                      "Sweep must not delete encrypted files in subdirectories when the key is not loaded")
    }

    func testSweepStillDeletesOrphansAfterKeyIsReloaded() throws {
        // Verify the fix doesn't break normal orphan cleanup: once the key IS loaded,
        // a UUID file with no mapping entry must still be removed.
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        // Plant a genuine orphan (UUID-named, no mapping entry) alongside a real encrypted file.
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-file-\(UUID()).txt")
        try "data".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let realItem = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first(where: { !$0.isDirectory }))

        let orphanURL = testDirectory.diskURL.appendingPathComponent(UUID().uuidString)
        try "orphan".write(to: orphanURL, atomically: true, encoding: .utf8)

        // Key is loaded — sweep must delete the orphan and leave the real file alone.
        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path),
                       "Genuine orphan must still be deleted when the key is loaded")
        XCTAssertTrue(FileManager.default.fileExists(atPath: realItem.diskURL.path),
                      "Mapped encrypted file must survive when the key is loaded")
    }

    // MARK: - sweepOrphanedEncryptedFiles

    func testSweepDeletesUUIDNamedFileWithNoMappingEntry() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        // The folder has a readable index that lacks this file's entry.
        try writeEncryptedMapping([:], authenticating: mappingFileName, in: testDirectory)
        let orphanURL = testDirectory.diskURL.appendingPathComponent(UUID().uuidString)
        try "orphan data".write(to: orphanURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))

        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path),
                       "Orphaned UUID-named file in an indexed folder must be removed by the sweep")
    }

    func testSweepKeepsUUIDNamedFileInFolderWithNoIndex() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        // No .vault_map: this is plaintext user data, not an encrypted orphan.
        let plainURL = testDirectory.diskURL.appendingPathComponent(UUID().uuidString)
        try "plaintext data".write(to: plainURL, atomically: true, encoding: .utf8)

        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: plainURL.path),
                      "UUID-named file in a folder with no index must be kept")
    }

    func testSweepKeepsUnmappedUUIDFileWhenKeyIsNotLoaded() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        try writeEncryptedMapping([:], authenticating: mappingFileName, in: testDirectory)
        let fileURL = testDirectory.diskURL.appendingPathComponent(UUID().uuidString)
        try "data".write(to: fileURL, atomically: true, encoding: .utf8)

        CryptoService.shared.wipeKey()
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)

        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "Nothing may be deleted when the key is not loaded")
    }

    func testSweepKeepsMappedEncryptedFiles() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-keep-\(UUID()).txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try FileSystem.shared.importItems(from: [sourceURL], to: testDirectory)
        let item = try FileSystem.shared.contents(of: testDirectory).first!

        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: item.diskURL.path),
                      "Mapped encrypted file must not be removed by the sweep")
    }

    func testSweepDoesNotDeleteNonUUIDNamedFiles() throws {
        let plainURL = testDirectory.diskURL.appendingPathComponent("plainfile.txt")
        try "data".write(to: plainURL, atomically: true, encoding: .utf8)

        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: plainURL.path),
                      "Non-UUID filename must not be touched by the sweep")
    }

    func testSweepRecursesIntoSubdirectories() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        let subDir = testDirectory.diskURL.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let sub = VaultDirectory(name: "subdir", diskURL: subDir, rootURL: testDirectory.rootURL)
        try writeEncryptedMapping([:], authenticating: mappingFileName, in: sub)

        let orphanURL = subDir.appendingPathComponent(UUID().uuidString)
        try "orphan".write(to: orphanURL, atomically: true, encoding: .utf8)

        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path),
                       "Orphaned UUID file inside an indexed subdirectory must be removed")
    }

    func testSweepKeepsUUIDNamedFileInSubdirectoryWithNoIndex() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        let subDir = testDirectory.diskURL.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let plainURL = subDir.appendingPathComponent(UUID().uuidString)
        try "plaintext".write(to: plainURL, atomically: true, encoding: .utf8)

        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: plainURL.path),
                      "UUID-named file in a subdirectory with no index must be kept")
    }

    // MARK: - AAD fallback chain: backward-compatibility for maps from different code eras
    //
    // loadEncryptedJSON tries three AES-GCM authenticating domains in order:
    //   1. url.lastPathComponent (".vault_map")         — current saveEncryptedJSON output
    //   2. authDomain(for: url) (relative path)         — maps from a brief debug-session window
    //   3. "" (empty AAD)                               — maps written before the authenticating:
    //                                                     parameter existed on CryptoService.encrypt
    //
    // These tests lock in that fallback chain so a future change can't silently break
    // backward-compatibility and leave users staring at empty folders.

    func testContents_ReadsMap_EncryptedWithLastPathComponentDomain() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "test-\(UUID().uuidString)")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        let uuid = UUID().uuidString
        _ = try createDummyFile(named: uuid, in: testDirectory)
        try writeEncryptedMapping([uuid: VaultMapping(originalName: "photo.jpg")],
                                  authenticating: ".vault_map", in: testDirectory)

        let items = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "photo.jpg")
    }

    func testContents_ReadsLegacyMap_EncryptedWithEmptyAAD() throws {
        // Maps written by the original encrypt(data:) API — before authenticating: existed —
        // used empty AAD. This is fallback 2 in loadEncryptedJSON.
        try CryptoService.shared.createMasterKey(wrappedBy: "test-\(UUID().uuidString)")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        let uuid = UUID().uuidString
        _ = try createDummyFile(named: uuid, in: testDirectory)
        try writeEncryptedMapping([uuid: VaultMapping(originalName: "video.mp4")],
                                  authenticating: "", in: testDirectory)

        let items = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "video.mp4")
    }

    func testImport_IntoFolderWithLegacyEmptyAADMap_PreservesExistingEntries() throws {
        // Regression: importing a new file into a folder whose .vault_map was encrypted with
        // empty AAD must not throw mappingUnreadable. importSingleFile reads the existing map
        // first; if that read fails with the wrong domain, the whole import aborts and the
        // caller sees "vault index unreadable" even though the files are perfectly fine.
        try CryptoService.shared.createMasterKey(wrappedBy: "test-\(UUID().uuidString)")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        let existingUUID = UUID().uuidString
        _ = try createDummyFile(named: existingUUID, in: testDirectory)
        try writeEncryptedMapping([existingUUID: VaultMapping(originalName: "existing.jpg")],
                                  authenticating: "", in: testDirectory)

        let srcURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("new-\(UUID().uuidString).txt")
        try "hello".write(to: srcURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srcURL) }

        XCTAssertNoThrow(try FileSystem.shared.importItems(from: [srcURL], to: testDirectory),
                         "import must not throw for a folder with a legacy empty-AAD map")

        let items = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(items.count, 2, "both the legacy file and the new import must be visible")
        XCTAssertTrue(items.contains { $0.name == "existing.jpg" }, "legacy entry must be preserved")
        XCTAssertTrue(items.contains { $0.name.hasSuffix(".txt") }, "new file must be present")
    }

    func testContents_ThrowsMappingUnreadable_ForCompletelyUnrecognizedAADDomain() throws {
        // Safety net: the fallback chain must not become a free-for-all. A map encrypted with
        // a domain that matches none of the known fallbacks must still throw mappingUnreadable.
        try CryptoService.shared.createMasterKey(wrappedBy: "test-\(UUID().uuidString)")
        defer { try? CryptoService.shared.wipeMasterKeyBlob() }

        let uuid = UUID().uuidString
        _ = try createDummyFile(named: uuid, in: testDirectory)
        try writeEncryptedMapping([uuid: VaultMapping(originalName: "file.txt")],
                                  authenticating: "not-a-recognized-domain", in: testDirectory)

        XCTAssertThrowsError(try FileSystem.shared.contents(of: testDirectory)) { error in
            guard case FileSystemError.mappingUnreadable = error else {
                XCTFail("Expected FileSystemError.mappingUnreadable for unrecognized AAD, got \(error)")
                return
            }
        }
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
