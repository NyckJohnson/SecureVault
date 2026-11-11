import Foundation
import Testing

@testable import KoalaTVault

/// Failure paths of the lock: what is thrown and what is left behind when a Keychain, key store or file step fails.
@MainActor
@Suite struct LiveVaultLockFailureTests {
    private static let alpha = LiveVaultLockTests.alpha
    private static let denied = VaultCryptoError.keychain(-25293)

    @Test("A failed Face ID marker write in the upgrade throws the Keychain error and leaves vaultsUpgraded false")
    func upgradeKeychainFailure() async throws {
        let fixture = try VaultLockFixture(upgraded: false, lockMode: .passwordAndBiometrics)
        fixture.keychain.errorToThrow = Self.denied
        await expectLockError(.keychain(-25293)) { try await fixture.lock.upgradeIfNeeded() }
        #expect(!fixture.preferences.vaultsUpgraded)
    }

    @Test("A failed name write and a failed blob delete while creating throw the cipher error and remove the folder")
    func createVaultCleanupSurvivesBlobDeleteFailure() async throws {
        let fixture = try VaultLockFixture()
        fixture.failCiphers(with: .encryptionFailed)
        fixture.shelf.fail("deleteMasterKeyBlob", with: Self.denied)
        await expectLockError(.io(VaultCryptoError.encryptionFailed.localizedDescription)) {
            try await fixture.lock.createVault(name: "Docs", password: "docs pw")
        }
        #expect(fixture.vaultFolderNames.isEmpty)
        #expect(fixture.lock.current.id == "unencrypted")
    }

    @Test("A failed rewrap throws the mapped error and the old password still opens the vault")
    func changePasswordRewrapFailure() async throws {
        let fixture = try VaultLockFixture(vaults: [Self.alpha])
        try await fixture.lock.open(password: "alpha pw")
        fixture.shelf.fail("rewrap", with: Self.denied)
        await expectLockError(.keychain(-25293)) {
            try await fixture.lock.changePassword(current: "alpha pw", new: "new pw")
        }
        fixture.lock.close()
        try await fixture.lock.open(password: "alpha pw")
        #expect(fixture.lock.current.id == "aaaa-1")
    }

    @Test("Enabling Face ID interrupted by close throws notOpen even when removing the biometric key fails")
    func enableBiometricsInterruptedWithDeleteFailure() async throws {
        let fixture = try VaultLockFixture(vaults: [Self.alpha])
        try await fixture.lock.open(password: "alpha pw")
        fixture.shelf.fail("deleteBiometricKey", with: Self.denied)
        let result = await fixture.runHeld("storeBiometricKey", interrupt: .close) {
            try await fixture.lock.setUsesBiometrics(true)
        }
        expectFailure(result, .notOpen)
        #expect(fixture.marker == nil)
        #expect(fixture.lock.current.id == "unencrypted")
    }

    @Test("A vault with no name file and a failing name write still opens, named My Vault")
    func openWithoutNameFileWhenNameWriteFails() async throws {
        let fixture = try VaultLockFixture(vaults: [SeedVault(id: "aaaa-1", name: nil, password: "alpha pw")])
        fixture.failCiphers(with: .encryptionFailed)
        try await fixture.lock.open(password: "alpha pw")
        #expect(fixture.lock.current.id == "aaaa-1")
        #expect(fixture.lock.current.name == "My Vault")
    }

    @Test("A missing biometric item with a failing biometric key delete throws biometricChanged and clears the marker")
    func faceIDOpenMissingItemDeleteFails() async throws {
        let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha])
        fixture.shelf.fail("unlockWithBiometricKey", with: .biometricItemMissing)
        fixture.shelf.fail("deleteBiometricKey", with: Self.denied)
        await expectLockError(.biometricChanged) { try await fixture.lock.openWithBiometrics() }
        #expect(fixture.marker == nil)
        #expect(fixture.lock.current.id == "unencrypted")
    }

    @Test("A failing marker delete during a Face ID open still throws biometricChanged")
    func faceIDOpenMarkerDeleteFails() async throws {
        let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha])
        fixture.shelf.fail("unlockWithBiometricKey", with: .biometricItemMissing)
        fixture.keychain.failDeletes(of: VaultCatalog.markerAccount, with: Self.denied)
        await expectLockError(.biometricChanged) { try await fixture.lock.openWithBiometrics() }
        #expect(fixture.biometricItem == nil)
        #expect(fixture.lock.current.id == "unencrypted")
    }

    @Test("Creating a vault whose name write fails and whose folder cannot be removed throws the original error")
    func createVaultFolderRemovalFails() async throws {
        let fixture = try VaultLockFixture()
        fixture.failCiphers(with: .encryptionFailed)
        let parent = fixture.vaultsFolder
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }

        // The folder is made before the key is created: lock the parent while the key creation is held.
        fixture.shelf.hold("createMasterKey")
        let task = Task { @MainActor in try await fixture.lock.createVault(name: "Docs", password: "docs pw") }
        await fixture.waitUntilEntered("createMasterKey")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        fixture.shelf.release("createMasterKey")
        let result: Result<Void, any Error> = await task.result
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        expectFailure(result, .io(VaultCryptoError.encryptionFailed.localizedDescription))
        #expect(!fixture.vaultFolderNames.isEmpty)
        #expect(fixture.lock.current.id == "unencrypted")
    }
}
