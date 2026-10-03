//
//  VaultTestCase.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 9/14/26.
//

import XCTest
@testable import KoalaTVault

/// Base class for tests that need an isolated, disk-backed `VaultDirectory`.
/// Subclasses should call `super.setUp()` first and `super.tearDown()` last,
/// adding only their test-specific setup/teardown around it.
class VaultTestCase: XCTestCase {

    var testDirectory: VaultDirectory!

    override func tearDown() {
        CryptoService.shared.wipeKey()
        try? CryptoService.shared.wipeMasterKeyBlob()
        try? FileManager.default.removeItem(at: testDirectory.diskURL)
        FileSystem.shared.cleanupTempFiles()
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        testDirectory = VaultDirectory(name: "test", diskURL: tempURL, rootURL: tempURL)
    }
}
