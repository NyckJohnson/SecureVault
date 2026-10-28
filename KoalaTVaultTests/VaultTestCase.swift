//
//  VaultTestCase.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 9/14/26.
//

import XCTest
@testable import KoalaTVault

/// Base class for tests that need an isolated, disk-backed `LegacyVaultDirectory`.
/// Subclasses should call `super.setUp()` first and `super.tearDown()` last,
/// adding only their test-specific setup/teardown around it.
class VaultTestCase: XCTestCase {

    var testDirectory: LegacyVaultDirectory!

    override func tearDown() {
        TestCrypto.reset()
        try? FileManager.default.removeItem(at: testDirectory.diskURL)
        FileSystem.shared.cleanupTempFiles()
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        TestCrypto.requireInMemoryKeychain()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        testDirectory = LegacyVaultDirectory(name: "test", diskURL: tempURL, rootURL: tempURL)
    }
}
