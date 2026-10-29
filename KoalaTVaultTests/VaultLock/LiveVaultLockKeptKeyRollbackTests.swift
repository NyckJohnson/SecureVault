import Testing

@testable import KoalaTVault

/// Repointed from baseline fix 25: when enabling Face ID fails after a password was set against an existing
/// key, the existing key and its blob stay.
@MainActor
@Suite struct LiveVaultLockKeptKeyRollbackTests {
    @Test("A biometric failure when adding a lock over an existing key keeps the blob unlockable")
    func keptKeyRollback() async throws {
        let harness = try await VaultLockHarness(blobPassword: "old-password", vaultHasEncryptedData: true)
        harness.keys.failures = ["storeBiometricKey": .keychain(-25293)]

        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await harness.lock.prepareToAddLock(mode: .passwordAndBiometrics, password: "old-password")
        }

        #expect(harness.keys.password == "old-password")
        #expect(!harness.log.events.contains("deleteMasterKeyBlob"))
        #expect(!harness.log.events.contains("createMasterKey"))
        #expect(!harness.keys.hasBiometricKey)
        #expect(!harness.keys.isKeyLoaded)
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.lockMode == .none)
        try await harness.lock.unlock(password: "old-password")
        #expect(harness.keys.isKeyLoaded)
    }
}
