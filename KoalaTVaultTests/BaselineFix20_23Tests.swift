import XCTest
@testable import KoalaTVault

// Regression tests for adoption baseline fixes 20 and 23 (docs/adopt/baseline-fixes.md).

// MARK: - Fix 20: folders export from an encrypted vault as decrypted copies
final class FolderExportDecryptedCopyTests: VaultTestCase {

    private func makeSource(_ name: String, _ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func allRelativePaths(under root: URL) -> [String] {
        let rootPath = root.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var result: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            result.append(String(url.resolvingSymlinksInPath().path.dropFirst(rootPath.count + 1)))
        }
        return result.sorted()
    }

    func testEncryptedFolderExportsAsDecryptedCopyWithRealNamesAndNesting() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let folder = try FileSystem.shared.createFolder(named: "Trip", in: testDirectory)
        let inner = try FileSystem.shared.createFolder(named: "Day1", in: folder)
        try FileSystem.shared.importItems(from: [try makeSource("a.txt", "alpha secret")], to: folder)
        try FileSystem.shared.importItems(from: [try makeSource("b.txt", "beta secret")], to: inner)

        let folderItem = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first { $0.name == "Trip" })
        let urls = try FileSystem.shared.prepareForExport([folderItem])

        XCTAssertEqual(urls.count, 1)
        let exported = urls[0]
        XCTAssertEqual(exported.lastPathComponent, "Trip")
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("a.txt"), encoding: .utf8), "alpha secret")
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("Day1/b.txt"), encoding: .utf8), "beta secret")
        XCTAssertEqual(allRelativePaths(under: exported), ["Day1", "Day1/b.txt", "a.txt"])
    }

    func testEncryptedFolderExportContainsNoIndexFileOrUUIDNames() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let folder = try FileSystem.shared.createFolder(named: "Docs", in: testDirectory)
        try FileSystem.shared.importItems(from: [try makeSource("x.txt", "x content")], to: folder)
        let folderItem = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first { $0.name == "Docs" })

        let exported = try XCTUnwrap(try FileSystem.shared.prepareForExport([folderItem]).first)

        for path in allRelativePaths(under: exported) {
            XCTAssertFalse(path.contains(".vault_map"), "index leaked: \(path)")
            XCTAssertNil(UUID(uuidString: (path as NSString).lastPathComponent), "UUID name leaked: \(path)")
        }
    }

    func testEncryptedFolderExportFileIsNotCiphertext() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let folder = try FileSystem.shared.createFolder(named: "Docs", in: testDirectory)
        try FileSystem.shared.importItems(from: [try makeSource("x.txt", "plain marker text")], to: folder)
        let folderItem = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first { $0.name == "Docs" })

        let exported = try XCTUnwrap(try FileSystem.shared.prepareForExport([folderItem]).first)
        let data = try Data(contentsOf: exported.appendingPathComponent("x.txt"))
        XCTAssertEqual(data, Data("plain marker text".utf8))
    }

    func testEncryptedFolderNeedsDecryptedCopy() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let folder = try FileSystem.shared.createFolder(named: "Docs", in: testDirectory)
        try FileSystem.shared.importItems(from: [try makeSource("x.txt", "x")], to: folder)
        let folderItem = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first { $0.name == "Docs" })
        XCTAssertTrue(FileSystem.shared.needsDecryptedCopy(folderItem))
    }

    func testEncryptedFolderHoldingIndexOnlyInASubfolderNeedsDecryptedCopy() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        let outer = try FileSystem.shared.createFolder(named: "Outer", in: testDirectory)
        let inner = try FileSystem.shared.createFolder(named: "Inner", in: outer)
        try FileSystem.shared.importItems(from: [try makeSource("x.txt", "x")], to: inner)
        let outerItem = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first { $0.name == "Outer" })
        XCTAssertTrue(FileSystem.shared.needsDecryptedCopy(outerItem))
    }

    func testNoLockFolderExportStillWorksAsPlainFolder() throws {
        let folder = try FileSystem.shared.createFolder(named: "Plain", in: testDirectory)
        try FileSystem.shared.importItems(from: [try makeSource("p.txt", "plain")], to: folder)
        let folderItem = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first { $0.name == "Plain" })

        XCTAssertFalse(FileSystem.shared.needsDecryptedCopy(folderItem))
        let exported = try XCTUnwrap(try FileSystem.shared.prepareForExport([folderItem]).first)
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("p.txt"), encoding: .utf8), "plain")
    }

    func testPlaintextFileDoesNotNeedDecryptedCopy() throws {
        let url = testDirectory.diskURL.appendingPathComponent("p.txt")
        try "plain".write(to: url, atomically: true, encoding: .utf8)
        let item = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first)
        XCTAssertFalse(FileSystem.shared.needsDecryptedCopy(item))
    }

    func testEncryptedFileNeedsDecryptedCopy() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword")
        try FileSystem.shared.importItems(from: [try makeSource("e.txt", "e")], to: testDirectory)
        let item = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first)
        XCTAssertTrue(FileSystem.shared.needsDecryptedCopy(item))
    }
}

// MARK: - Fix 23: the encrypt migration survives the key being wiped; a stuck vault recovers
final class EncryptMigrationSafetyTests: VaultTestCase {

    override func tearDown() {
        PreferencesService.shared.pendingMigrationType = nil
        PreferencesService.shared.pendingMigrationTargetLockMode = nil
        super.tearDown()
    }

    private var mapURL: URL { testDirectory.diskURL.appendingPathComponent(".vault_map") }

    private func write(_ name: String, _ content: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? testDirectory.diskURL).appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func plaintextItems() throws -> [(item: VaultItem, directory: VaultDirectory)] {
        try FileSystem.shared.filesToMigrate(toEncrypted: true, in: testDirectory)
    }

    func testMigratingAFileEncryptsItAndRemovesThePlaintext() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        let url = try write("a.txt", "alpha")
        let entry = try XCTUnwrap(try plaintextItems().first)

        try FileSystem.shared.migrateFileToEncrypted(entry.item, in: entry.directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let items = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(items.map(\.name), ["a.txt"])
        XCTAssertTrue(items[0].isEncrypted)
        let opened = try FileSystem.shared.open(items[0])
        XCTAssertEqual(try String(contentsOf: opened, encoding: .utf8), "alpha")
    }

    func testMigratingWithoutKeyThrowsKeepsPlaintextAndWritesNoPlaintextIndex() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        let url = try write("a.txt", "alpha")
        let entry = try XCTUnwrap(try plaintextItems().first)
        CryptoService.shared.wipeKey()

        XCTAssertThrowsError(try FileSystem.shared.migrateFileToEncrypted(entry.item, in: entry.directory)) { error in
            XCTAssertEqual(error as? CryptoError, .noKeyLoaded)
        }

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "alpha")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapURL.path), "no index of any kind written")
        let others = try FileManager.default.contentsOfDirectory(atPath: testDirectory.diskURL.path)
        XCTAssertEqual(others, ["a.txt"], "no stray encrypted copy left")
    }

    func testMigrationWithKeyWipedLeavesNoReadablePlaintextIndexAfterPartialFolder() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        _ = try write("a.txt", "alpha")
        _ = try write("b.txt", "beta")
        let entries = try plaintextItems()
        try FileSystem.shared.migrateFileToEncrypted(entries[0].item, in: entries[0].directory)
        CryptoService.shared.wipeKey()  // device locks mid-folder
        XCTAssertThrowsError(try FileSystem.shared.migrateFileToEncrypted(entries[1].item, in: entries[1].directory))

        let data = try Data(contentsOf: mapURL)
        XCTAssertNil(try? JSONDecoder().decode([String: VaultMapping].self, from: data),
                     "the index on disk is never plaintext JSON")
    }

    func testResumeAfterKeyWipeFinishesTheFolder() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        _ = try write("a.txt", "alpha")
        _ = try write("b.txt", "beta")
        _ = try write("c.txt", "gamma")
        let first = try plaintextItems()
        try FileSystem.shared.migrateFileToEncrypted(first[0].item, in: first[0].directory)
        CryptoService.shared.wipeKey()
        for entry in first.dropFirst() {
            XCTAssertThrowsError(try FileSystem.shared.migrateFileToEncrypted(entry.item, in: entry.directory))
        }
        try CryptoService.shared.unwrapMasterKey(with: "pw")

        for entry in try plaintextItems() {
            try FileSystem.shared.migrateFileToEncrypted(entry.item, in: entry.directory)
        }

        XCTAssertTrue(try plaintextItems().isEmpty)
        let items = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(Set(items.map(\.name)), ["a.txt", "b.txt", "c.txt"])
        XCTAssertTrue(items.allSatisfy(\.isEncrypted))
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: testDirectory.diskURL.path)
        XCTAssertFalse(onDisk.contains("a.txt") || onDisk.contains("b.txt") || onDisk.contains("c.txt"))
    }

    func testLegacyPlaintextIndexIsRecoveredAndReEncrypted() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        // An older build left a plaintext index next to its encrypted copy.
        _ = try write("a.txt", "alpha")
        let entry = try XCTUnwrap(try plaintextItems().first)
        try FileSystem.shared.migrateFileToEncrypted(entry.item, in: entry.directory)
        let encryptedItem = try XCTUnwrap(try FileSystem.shared.contents(of: testDirectory).first)
        let uuid = encryptedItem.diskURL.lastPathComponent
        let plaintextIndex = try JSONEncoder().encode([uuid: VaultMapping(originalName: "a.txt")])
        try plaintextIndex.write(to: mapURL, options: .atomic)

        // The plaintext index still lists the file.
        let items = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(items.map(\.name), ["a.txt"])
        XCTAssertTrue(items[0].isEncrypted)

        try FileSystem.shared.encryptPlaintextIndexes(in: testDirectory)

        let data = try Data(contentsOf: mapURL)
        XCTAssertNil(try? JSONDecoder().decode([String: VaultMapping].self, from: data), "index is no longer plaintext")
        XCTAssertEqual(try FileSystem.shared.contents(of: testDirectory).map(\.name), ["a.txt"])
    }

    func testEncryptPlaintextIndexesRecursesIntoSubfolders() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        let sub = try FileSystem.shared.createFolder(named: "Sub", in: testDirectory)
        let subMap = sub.diskURL.appendingPathComponent(".vault_map")
        let plain = try JSONEncoder().encode(["X": VaultMapping(originalName: "x.txt")])
        try plain.write(to: subMap)

        try FileSystem.shared.encryptPlaintextIndexes(in: testDirectory)

        XCTAssertNil(try? JSONDecoder().decode([String: VaultMapping].self, from: Data(contentsOf: subMap)))
    }

    func testEncryptPlaintextIndexesWithoutKeyThrowsNoKeyLoaded() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        CryptoService.shared.wipeKey()
        XCTAssertThrowsError(try FileSystem.shared.encryptPlaintextIndexes(in: testDirectory)) { error in
            XCTAssertEqual(error as? CryptoError, .noKeyLoaded)
        }
    }

    func testRerunDeletesLeftoverPlaintextWhenEncryptedCopyMatchesByteForByte() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        _ = try write("a.txt", "same content")
        let entry = try XCTUnwrap(try plaintextItems().first)
        try FileSystem.shared.migrateFileToEncrypted(entry.item, in: entry.directory)
        // A crash before the delete left the plaintext behind.
        let leftover = try write("a.txt", "same content")
        let rerun = try XCTUnwrap(try plaintextItems().first)

        try FileSystem.shared.migrateFileToEncrypted(rerun.item, in: rerun.directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        let items = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(items.map(\.name), ["a.txt"], "no duplicate was made")
    }

    func testRerunKeepsDifferingSameNamePlaintextAndEncryptsItUnderAFreeName() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        _ = try write("a.txt", "original")
        let entry = try XCTUnwrap(try plaintextItems().first)
        try FileSystem.shared.migrateFileToEncrypted(entry.item, in: entry.directory)
        let different = try write("a.txt", "something else entirely")
        let rerun = try XCTUnwrap(try plaintextItems().first)

        try FileSystem.shared.migrateFileToEncrypted(rerun.item, in: rerun.directory)

        // Never silently dropped: both contents survive, under different visible names.
        XCTAssertFalse(FileManager.default.fileExists(atPath: different.path) && (try? String(contentsOf: different, encoding: .utf8)) == "original")
        let items = try FileSystem.shared.contents(of: testDirectory)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.name)).count, 2)
        var contents: Set<String> = []
        for item in items {
            let url = item.isEncrypted ? try FileSystem.shared.open(item) : item.diskURL
            contents.insert(try String(contentsOf: url, encoding: .utf8))
        }
        XCTAssertEqual(contents, ["original", "something else entirely"])
    }

    func testRerunKeepsSameSizeDifferentPlaintextInsteadOfDeletingIt() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        _ = try write("a.txt", "AAAAAAAA")
        let entry = try XCTUnwrap(try plaintextItems().first)
        try FileSystem.shared.migrateFileToEncrypted(entry.item, in: entry.directory)
        _ = try write("a.txt", "BBBBBBBB")  // same length, different bytes
        let rerun = try XCTUnwrap(try plaintextItems().first)

        try FileSystem.shared.migrateFileToEncrypted(rerun.item, in: rerun.directory)

        var contents: Set<String> = []
        for item in try FileSystem.shared.contents(of: testDirectory) {
            let url = item.isEncrypted ? try FileSystem.shared.open(item) : item.diskURL
            contents.insert(try String(contentsOf: url, encoding: .utf8))
        }
        XCTAssertEqual(contents, ["AAAAAAAA", "BBBBBBBB"])
    }

    func testIsCompleteEncryptedCopyRejectsTruncatedCopyAndWrongSize() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        let source = try write("a.txt", "0123456789")
        let copy = testDirectory.diskURL.appendingPathComponent("copy.bin")
        try CryptoService.shared.encryptFile(at: source, to: copy)

        XCTAssertTrue(CryptoService.shared.isCompleteEncryptedCopy(at: copy, plaintextSize: 10))
        XCTAssertFalse(CryptoService.shared.isCompleteEncryptedCopy(at: copy, plaintextSize: 9))
        let truncated = try Data(contentsOf: copy).dropLast(3)
        try Data(truncated).write(to: copy)
        XCTAssertFalse(CryptoService.shared.isCompleteEncryptedCopy(at: copy, plaintextSize: 10))
    }

    func testIsCompleteEncryptedCopyIsFalseWithoutKey() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        let source = try write("a.txt", "0123456789")
        let copy = testDirectory.diskURL.appendingPathComponent("copy.bin")
        try CryptoService.shared.encryptFile(at: source, to: copy)
        CryptoService.shared.wipeKey()
        XCTAssertFalse(CryptoService.shared.isCompleteEncryptedCopy(at: copy, plaintextSize: 10))
    }

    func testEncryptedFileComparisonMatchesDiffersAndThrowsWithoutKey() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        let source = try write("a.txt", "0123456789")
        let other = try write("b.txt", "0123456780")
        let copy = testDirectory.diskURL.appendingPathComponent("copy.bin")
        try CryptoService.shared.encryptFile(at: source, to: copy)

        XCTAssertTrue(try CryptoService.shared.encryptedFile(at: copy, hasSameContentAs: source))
        XCTAssertFalse(try CryptoService.shared.encryptedFile(at: copy, hasSameContentAs: other))
        CryptoService.shared.wipeKey()
        XCTAssertThrowsError(try CryptoService.shared.encryptedFile(at: copy, hasSameContentAs: source)) { error in
            XCTAssertEqual(error as? CryptoError, .noKeyLoaded)
        }
    }

    func testOrphanSweepDoesNothingWhileAMigrationIsPending() throws {
        try CryptoService.shared.createMasterKey(wrappedBy: "pw")
        // An indexed encrypted file makes the folder an indexed one; the stray file is unindexed.
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try "x".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }
        try FileSystem.shared.importItems(from: [source], to: testDirectory)
        let stray = try write(UUID().uuidString, "unindexed copy awaiting its index entry")

        PreferencesService.shared.pendingMigrationType = .encrypt
        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path), "kept while a migration is pending")

        PreferencesService.shared.pendingMigrationType = nil
        FileSystem.shared.sweepOrphanedEncryptedFiles(in: testDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "swept once nothing is pending")
    }
}

// MARK: - Fix 23: a pending encrypt is recoverable at launch
@MainActor
final class PendingEncryptionLaunchTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        reset()
    }

    override func tearDown() async throws {
        reset()
        try await super.tearDown()
    }

    private func reset() {
        AuthService.shared.isLocked = false
        AuthService.shared.hasAuthenticated = false
        AuthService.shared.lockMode = .none
        try? AuthService.shared.removePassword()
        CryptoService.shared.wipeKey()
        PreferencesService.shared.pendingMigrationType = nil
        PreferencesService.shared.pendingMigrationTargetLockMode = nil
    }

    func testPendingEncryptWithoutAPasswordIsDroppedAndLaunchStaysUnlocked() throws {
        PreferencesService.shared.pendingMigrationType = .encrypt
        PreferencesService.shared.pendingMigrationTargetLockMode = .password

        var unlocked = false
        let token = NotificationCenter.default.addObserver(
            forName: AuthService.vaultUnlockedNotification, object: nil, queue: nil) { _ in unlocked = true }
        defer { NotificationCenter.default.removeObserver(token) }

        AuthService.shared.handleInitialLaunch(in: nil)

        XCTAssertNil(PreferencesService.shared.pendingMigrationType)
        XCTAssertNil(PreferencesService.shared.pendingMigrationTargetLockMode)
        XCTAssertEqual(AuthService.shared.lockMode, .none)
        XCTAssertFalse(AuthService.shared.isLocked)
        XCTAssertTrue(unlocked)
    }

    func testPendingEncryptWithAPasswordAsksForItEvenWhenLockModeWasNeverSaved() throws {
        try AuthService.shared.createPassword("password123")
        CryptoService.shared.wipeKey()
        AuthService.shared.lockMode = .none
        PreferencesService.shared.pendingMigrationType = .encrypt
        PreferencesService.shared.pendingMigrationTargetLockMode = .password

        AuthService.shared.handleInitialLaunch(in: nil)

        XCTAssertTrue(AuthService.shared.isLocked)
        XCTAssertEqual(PreferencesService.shared.pendingMigrationType, .encrypt, "pending encrypt is kept")
    }

    func testNoPendingMigrationAndNoLockLaunchesUnlocked() throws {
        AuthService.shared.handleInitialLaunch(in: nil)
        XCTAssertFalse(AuthService.shared.isLocked)
    }
}
