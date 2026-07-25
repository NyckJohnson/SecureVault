//
//  CryptoServiceTests.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/20/26.
//

import XCTest
@testable import SecureVault

final class CryptoServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? CryptoService.shared.loadKey(from: "testpassword123")
    }

    override func tearDown() {
        super.tearDown()
        CryptoService.shared.wipeKey()
    }

    // MARK: - Key Loading
    func testKeyLoadsSuccessfully() throws {
        XCTAssertTrue(CryptoService.shared.isKeyLoaded)
    }

    func testKeyWipesSuccessfully() {
        CryptoService.shared.wipeKey()
        XCTAssertFalse(CryptoService.shared.isKeyLoaded)
    }

    func testSamePasswordProducesSameKey() throws {
        try CryptoService.shared.loadKey(from: "testpassword123")
        let data = "test".data(using: .utf8)!
        let encrypted1 = try CryptoService.shared.encrypt(data: data)
        CryptoService.shared.wipeKey()
        try CryptoService.shared.loadKey(from: "testpassword123")
        // should be able to decrypt with reloaded key
        XCTAssertNoThrow(try CryptoService.shared.decrypt(data: encrypted1))
    }

    // MARK: - Encrypt/Decrypt
    func testEncryptThenDecryptReturnsOriginal() throws {
        let original = "Hello, SecureVault!".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: original)
        let decrypted = try CryptoService.shared.decrypt(data: encrypted)
        XCTAssertEqual(original, decrypted)
    }

    func testEncryptedDataDiffersFromOriginal() throws {
        let original = "Hello, SecureVault!".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: original)
        XCTAssertNotEqual(original, encrypted)
    }

    func testEncryptProducesDifferentOutputEachTime() throws {
        let original = "Hello".data(using: .utf8)!
        let encrypted1 = try CryptoService.shared.encrypt(data: original)
        let encrypted2 = try CryptoService.shared.encrypt(data: original)
        XCTAssertNotEqual(encrypted1, encrypted2)
    }

    func testDecryptWithWrongKeyFails() throws {
        let original = "Hello".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: original)
        CryptoService.shared.wipeKey()
        try CryptoService.shared.loadKey(from: "wrongpassword")
        XCTAssertThrowsError(try CryptoService.shared.decrypt(data: encrypted))
    }

    func testDecryptWithNoKeyThrows() throws {
        let original = "Hello".data(using: .utf8)!
        let encrypted = try CryptoService.shared.encrypt(data: original)
        CryptoService.shared.wipeKey()
        XCTAssertThrowsError(try CryptoService.shared.decrypt(data: encrypted))
    }

    func testEncryptEmptyDataSucceeds() throws {
        let empty = Data()
        let encrypted = try CryptoService.shared.encrypt(data: empty)
        let decrypted = try CryptoService.shared.decrypt(data: encrypted)
        XCTAssertEqual(empty, decrypted)
    }

    func testEncryptLargeDataSucceeds() throws {
        let large = Data(repeating: 0xAB, count: 1024 * 1024) // 1MB
        let encrypted = try CryptoService.shared.encrypt(data: large)
        let decrypted = try CryptoService.shared.decrypt(data: encrypted)
        XCTAssertEqual(large, decrypted)
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
}
