//
//  CryptoServiceTests.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/20/26.
//

import XCTest
@testable import KoalaTVault

final class CryptoServiceTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try CryptoService.shared.createMasterKey(wrappedBy: "testpassword123")
    }

    override func tearDownWithError() throws {
        CryptoService.shared.wipeKey()
        try CryptoService.shared.wipeMasterKeyBlob()
        tempURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        try super.tearDownWithError()
    }

    // MARK: - Key Loading
    func testKeyLoadsSuccessfully() throws {
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
    }

    func testKeyWipesSuccessfully() {
        CryptoService.shared.wipeKey()
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)
    }

    func testSamePasswordUnwrapsSameMasterKey() throws {
        let data = "test".data(using: .utf8)!
        let encrypted1 = try CryptoService.shared.encrypt(data: data, authenticating: "test")
        CryptoService.shared.wipeKey()
        try CryptoService.shared.unwrapMasterKey(with: "testpassword123")
        XCTAssertNoThrow(try CryptoService.shared.decrypt(data: encrypted1, authenticating: "test"))
    }

    // MARK: - Encrypt/Decrypt
    func testEncryptThenDecryptReturnsOriginal() throws {
        let original = "Hello, Koala T Vault!".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: original, authenticating: "test")
        let decrypted = try CryptoService.shared.decrypt(data: encrypted, authenticating: "test")
        XCTAssertEqual(original, decrypted)
    }

    func testEncryptedDataDiffersFromOriginal() throws {
        let original = "Hello, Koala T Vault!".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: original, authenticating: "test")
        XCTAssertNotEqual(original, encrypted)
    }

    func testEncryptProducesDifferentOutputEachTime() throws {
        let original = "Hello".data(using: .utf8)!
        let encrypted1 = try CryptoService.shared.encrypt(data: original, authenticating: "test")
        let encrypted2 = try CryptoService.shared.encrypt(data: original, authenticating: "test")
        XCTAssertNotEqual(encrypted1, encrypted2)
    }

    func testDecryptWithDifferentMasterKeyFails() throws {
        let original = "Hello".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: original, authenticating: "test")
        CryptoService.shared.wipeKey()
        try CryptoService.shared.wipeMasterKeyBlob()
        try CryptoService.shared.createMasterKey(wrappedBy: "differentpassword")
        XCTAssertThrowsError(try CryptoService.shared.decrypt(data: encrypted, authenticating: "test"))
    }

    func testDecryptWithNoKeyThrows() throws {
        let original = "Hello".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: original, authenticating: "test")
        CryptoService.shared.wipeKey()
        XCTAssertThrowsError(try CryptoService.shared.decrypt(data: encrypted, authenticating: "test"))
    }

    func testEncryptEmptyDataSucceeds() throws {
        let empty = Data()
        let encrypted = try CryptoService.shared.encrypt(data: empty, authenticating: "test")
        let decrypted = try CryptoService.shared.decrypt(data: encrypted, authenticating: "test")
        XCTAssertEqual(empty, decrypted)
    }

    func testEncryptLargeDataSucceeds() throws {
        let large = Data(repeating: 0xAB, count: 1024 * 1024) // 1MB
        let encrypted = try CryptoService.shared.encrypt(data: large, authenticating: "test")
        let decrypted = try CryptoService.shared.decrypt(data: encrypted, authenticating: "test")
        XCTAssertEqual(large, decrypted)
    }

    // MARK: - Master Key
    func testHasMasterKeyBlobTrueAfterCreate() throws {
        XCTAssertTrue(try CryptoService.shared.hasMasterKeyBlob())
    }

    func testHasMasterKeyBlobFalseAfterWipe() throws {
        try CryptoService.shared.wipeMasterKeyBlob()
        XCTAssertFalse(try CryptoService.shared.hasMasterKeyBlob())
    }

    func testUnwrapMasterKeyWithWrongPasswordThrows() {
        XCTAssertThrowsError(try CryptoService.shared.unwrapMasterKey(with: "wrongpassword")) {
            XCTAssertEqual($0 as? CryptoError, .wrongPassword)
        }
    }

    func testUnwrapMasterKeyWithNoBlobThrows() throws {
        try CryptoService.shared.wipeMasterKeyBlob()
        XCTAssertThrowsError(try CryptoService.shared.unwrapMasterKey(with: "anything")) {
            XCTAssertEqual($0 as? CryptoError, .noMasterKeyBlob)
        }
    }

    func testRewrapAllowsUnwrapWithNewPassword() throws {
        try CryptoService.shared.rewrapMasterKey(with: "newpassword456")
        CryptoService.shared.wipeKey()
        XCTAssertNoThrow(try CryptoService.shared.unwrapMasterKey(with: "newpassword456"))
    }

    func testRewrapWithoutLoadedKeyThrows() {
        CryptoService.shared.wipeKey()
        XCTAssertThrowsError(try CryptoService.shared.rewrapMasterKey(with: "x"))
    }

    /// Regression test for the bug this feature fixes: changing the password must not
    /// change which key files are encrypted under.
    func testRewrapPreservesEncryptionKey() throws {
        let data = "preserve me".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: data, authenticating: "test")

        try CryptoService.shared.rewrapMasterKey(with: "newpassword456")
        CryptoService.shared.wipeKey()
        try CryptoService.shared.unwrapMasterKey(with: "newpassword456")

        XCTAssertEqual(try CryptoService.shared.decrypt(data: encrypted, authenticating: "test"), data)
    }
    
    // MARK: - File Encryption
    func testEncryptFileThenDecryptReturnsOriginal() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL    = tempDir.appendingPathComponent("test_\(UUID().uuidString).txt")
        let encryptedURL = tempDir.appendingPathComponent("encrypted_\(UUID().uuidString)")
        let decryptedURL = tempDir.appendingPathComponent("decrypted_\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: encryptedURL)
            try? FileManager.default.removeItem(at: decryptedURL)
        }
        let content = "Test file content"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        try CryptoService.shared.encryptFile(at: sourceURL, to: encryptedURL)
        try CryptoService.shared.decryptFile(at: encryptedURL, to: decryptedURL)
        let result = try String(contentsOf: decryptedURL, encoding: .utf8)
        XCTAssertEqual(result, content)
    }

    func testEncryptedFileIsUnreadableAsText() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL    = tempDir.appendingPathComponent("test_\(UUID().uuidString).txt")
        let encryptedURL = tempDir.appendingPathComponent("encrypted_\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: encryptedURL)
        }
        let content = "Test file content"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        try CryptoService.shared.encryptFile(at: sourceURL, to: encryptedURL)
        let encryptedData = try Data(contentsOf: encryptedURL)
        // encrypted data should not contain the original string
        XCTAssertFalse(encryptedData.contains("Test file content".data(using: .utf8)!))
    }

    func testEncryptedFileSizeIsLargerThanOriginal() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL    = tempDir.appendingPathComponent("test_\(UUID().uuidString).txt")
        let encryptedURL = tempDir.appendingPathComponent("encrypted_\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: encryptedURL)
        }
        let content = "Test file content"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        try CryptoService.shared.encryptFile(at: sourceURL, to: encryptedURL)
        let originalSize  = try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as! Int
        let encryptedSize = try FileManager.default.attributesOfItem(atPath: encryptedURL.path)[.size] as! Int
        XCTAssertGreaterThan(encryptedSize, originalSize)
    }

    // MARK: - Helpers

    // Mirrors CryptoService's SVC5 layout
    private let chunkSize = 1024 * 1024
    private let headerSize = 32
    private let fullChunkOnDisk = 4 + 1024 * 1024 + 28 // length prefix + nonce/ciphertext/tag

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cst_\(UUID().uuidString)")
        tempURLs.append(url)
        return url
    }

    private func randomData(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    private func makeEncryptedFile(_ data: Data) throws -> URL {
        let source = tempURL()
        let encrypted = tempURL()
        try data.write(to: source)
        try CryptoService.shared.encryptFile(at: source, to: encrypted)
        return encrypted
    }

    private func decryptToData(_ url: URL) throws -> Data {
        let out = tempURL()
        try CryptoService.shared.decryptFile(at: url, to: out)
        return try Data(contentsOf: out)
    }

    // MARK: - Chunked Format

    func testEmptyFileRoundTrips() throws {
        let encrypted = try makeEncryptedFile(Data())
        XCTAssertEqual(try decryptToData(encrypted), Data())
        XCTAssertEqual(try CryptoService.shared.streamInfo(for: encrypted).totalSize, 0)
    }

    func testExactChunkBoundaryRoundTrips() throws {
        let original = randomData(count: chunkSize)
        XCTAssertEqual(try decryptToData(try makeEncryptedFile(original)), original)
    }

    func testMultiChunkRoundTrips() throws {
        let original = randomData(count: chunkSize * 2 + chunkSize / 2)
        XCTAssertEqual(try decryptToData(try makeEncryptedFile(original)), original)
    }

    func testStreamInfoReportsSizes() throws {
        let original = randomData(count: chunkSize + 123)
        let info = try CryptoService.shared.streamInfo(for: try makeEncryptedFile(original))
        XCTAssertEqual(info.totalSize, original.count)
        XCTAssertEqual(info.chunkSize, chunkSize)
    }

    func testDecryptChunkMatchesSourceRanges() throws {
        let original = randomData(count: chunkSize * 2 + 500)
        let encrypted = try makeEncryptedFile(original)
        let info = try CryptoService.shared.streamInfo(for: encrypted)
        for index in 0..<3 {
            let chunk = try CryptoService.shared.decryptChunk(
                at: index, from: encrypted, chunkSize: info.chunkSize, totalSize: info.totalSize)
            let start = index * chunkSize
            XCTAssertEqual(chunk, original[start..<min(start + chunkSize, original.count)], "chunk \(index)")
        }
    }

    func testDecryptChunkOutOfRangeThrows() throws {
        let encrypted = try makeEncryptedFile(randomData(count: 100))
        let info = try CryptoService.shared.streamInfo(for: encrypted)
        for index in [-1, 1] {
            XCTAssertThrowsError(try CryptoService.shared.decryptChunk(
                at: index, from: encrypted, chunkSize: info.chunkSize, totalSize: info.totalSize))
        }
    }

    func testFileOpsWithNoKeyThrowNoKeyLoaded() throws {
        let encrypted = try makeEncryptedFile(randomData(count: 100))
        CryptoService.shared.wipeKey()
        let out = tempURL()
        XCTAssertThrowsError(try CryptoService.shared.decryptFile(at: encrypted, to: out)) {
            XCTAssertEqual($0 as? CryptoError, .noKeyLoaded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - Tamper Detection

    func testTamperedHeaderFailsDecryption() throws {
        // offset 8 = totalSize (passes range checks, caught by AAD); offset 20 = inside fileID
        for offset in [8, 20] {
            let encrypted = try makeEncryptedFile(randomData(count: 1000))
            var bytes = try Data(contentsOf: encrypted)
            bytes[offset] ^= 0x01
            try bytes.write(to: encrypted)
            XCTAssertThrowsError(try decryptToData(encrypted), "offset \(offset)")
        }
    }

    func testWrongMagicFails() throws {
        let encrypted = try makeEncryptedFile(randomData(count: 100))
        var bytes = try Data(contentsOf: encrypted)
        bytes[0] = 0x00
        try bytes.write(to: encrypted)
        XCTAssertThrowsError(try decryptToData(encrypted))
        XCTAssertThrowsError(try CryptoService.shared.streamInfo(for: encrypted))
    }

    func testSwappedChunksFailDecryption() throws {
        let encrypted = try makeEncryptedFile(randomData(count: chunkSize * 2 + 100))
        var bytes = try Data(contentsOf: encrypted)
        let first = headerSize..<(headerSize + fullChunkOnDisk)
        let second = first.upperBound..<(first.upperBound + fullChunkOnDisk)
        let a = Data(bytes[first]), b = Data(bytes[second])
        bytes.replaceSubrange(second, with: a)
        bytes.replaceSubrange(first, with: b)
        try bytes.write(to: encrypted)
        XCTAssertThrowsError(try decryptToData(encrypted))
    }

    func testChunkFromAnotherFileFailsDecryption() throws {
        // Same size → identical layout; only the fileID in the AAD differs
        let encA = try makeEncryptedFile(randomData(count: chunkSize + 100))
        let encB = try makeEncryptedFile(randomData(count: chunkSize + 100))
        var bytesA = try Data(contentsOf: encA)
        let bytesB = try Data(contentsOf: encB)
        let chunk0 = headerSize..<(headerSize + fullChunkOnDisk)
        bytesA.replaceSubrange(chunk0, with: bytesB[chunk0])
        try bytesA.write(to: encA)
        XCTAssertThrowsError(try decryptToData(encA))
    }

    func testDroppedFinalChunkFailsDecryption() throws {
        let encrypted = try makeEncryptedFile(randomData(count: chunkSize * 2))
        let bytes = try Data(contentsOf: encrypted)
        try bytes.prefix(headerSize + fullChunkOnDisk).write(to: encrypted)
        XCTAssertThrowsError(try decryptToData(encrypted))
    }

    func testTruncatedMidChunkFailsAndLeavesNoOutput() throws {
        let encrypted = try makeEncryptedFile(randomData(count: 5000))
        let bytes = try Data(contentsOf: encrypted)
        try bytes.dropLast(10).write(to: encrypted)
        let out = tempURL()
        XCTAssertThrowsError(try CryptoService.shared.decryptFile(at: encrypted, to: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - Destination Safety

    func testInPlaceEncryptAndDecryptRoundTrips() throws {
        let original = randomData(count: chunkSize + 100)
        let url = tempURL()
        try original.write(to: url)

        try CryptoService.shared.encryptFile(at: url, to: url)
        XCTAssertNotEqual(try Data(contentsOf: url), original)

        try CryptoService.shared.decryptFile(at: url, to: url)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFailedDecryptLeavesExistingDestinationIntact() throws {
        let encrypted = try makeEncryptedFile(randomData(count: 5000))
        let bytes = try Data(contentsOf: encrypted)
        try bytes.dropLast(10).write(to: encrypted)

        let existing = Data("keep me".utf8)
        let out = tempURL()
        try existing.write(to: out)

        XCTAssertThrowsError(try CryptoService.shared.decryptFile(at: encrypted, to: out))
        XCTAssertEqual(try Data(contentsOf: out), existing)
    }

    func testSuccessfulDecryptReplacesExistingDestination() throws {
        let original = randomData(count: 1000)
        let encrypted = try makeEncryptedFile(original)
        let out = tempURL()
        try Data("stale".utf8).write(to: out)

        try CryptoService.shared.decryptFile(at: encrypted, to: out)
        XCTAssertEqual(try Data(contentsOf: out), original)
    }

    // MARK: - exportMasterKeyData / loadMasterKey

    func testExportMasterKeyDataReturns32Bytes() throws {
        let data = try CryptoService.shared.exportMasterKeyData()
        XCTAssertEqual(data.count, 32)
    }

    func testExportMasterKeyDataThrowsWhenNoKeyLoaded() {
        CryptoService.shared.wipeKey()
        XCTAssertThrowsError(try CryptoService.shared.exportMasterKeyData()) {
            XCTAssertEqual($0 as? CryptoError, .noKeyLoaded)
        }
    }

    func testLoadMasterKeyFromExportedDataRestoresKey() throws {
        let keyData = try CryptoService.shared.exportMasterKeyData()
        CryptoService.shared.wipeKey()
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)
        try CryptoService.shared.loadMasterKey(from: keyData)
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
    }

    func testLoadMasterKeyPreservesEncryptionAbility() throws {
        let original = "preserved".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: original, authenticating: "domain")
        let keyData = try CryptoService.shared.exportMasterKeyData()
        CryptoService.shared.wipeKey()
        try CryptoService.shared.loadMasterKey(from: keyData)
        XCTAssertEqual(try CryptoService.shared.decrypt(data: encrypted, authenticating: "domain"), original)
    }

    func testLoadMasterKeyWithTooFewBytesThrows() {
        XCTAssertThrowsError(try CryptoService.shared.loadMasterKey(from: Data(count: 16))) {
            XCTAssertEqual($0 as? CryptoError, .decryptionFailed)
        }
    }

    func testLoadMasterKeyWithEmptyDataThrows() {
        XCTAssertThrowsError(try CryptoService.shared.loadMasterKey(from: Data())) {
            XCTAssertEqual($0 as? CryptoError, .decryptionFailed)
        }
    }

    func testLoadMasterKeyWith33BytesThrows() {
        XCTAssertThrowsError(try CryptoService.shared.loadMasterKey(from: Data(count: 33))) {
            XCTAssertEqual($0 as? CryptoError, .decryptionFailed)
        }
    }

    // MARK: - createMasterKey guard

    func testCreateMasterKeyWhenBlobAlreadyExistsThrows() {
        XCTAssertThrowsError(try CryptoService.shared.createMasterKey(wrappedBy: "another")) {
            XCTAssertEqual($0 as? CryptoError, .masterKeyAlreadyExists)
        }
    }

    // MARK: - CryptoError LocalizedError

    func testAllCryptoErrorDescriptionsAreNonNilAndNonEmpty() {
        let errors: [CryptoError] = [
            .noKeyLoaded, .noMasterKeyBlob, .masterKeyAlreadyExists,
            .wrongPassword, .encryptionFailed, .decryptionFailed,
            .keychain(errSecItemNotFound)
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "errorDescription nil for \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty, "errorDescription empty for \(error)")
        }
    }

    func testKeychainErrorDescriptionIncludesStatusCode() {
        let status = OSStatus(-25300)
        let error = CryptoError.keychain(status)
        XCTAssertTrue(error.errorDescription?.contains("\(status)") == true)
    }
}
