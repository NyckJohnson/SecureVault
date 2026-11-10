import Foundation
import Testing

@testable import KoalaTVault

/// The open vault's password, Face ID, deletion, the transfer target and the launch upgrade of `LiveVaultLock`.
extension LiveVaultLockTests {
    static let faceAlpha = SeedVault(id: "aaaa-1", name: "Alpha", password: "alpha pw", faceID: true)

    // MARK: changePassword

    @MainActor @Suite struct ChangePassword {
        @Test("With the unencrypted vault current it throws notOpen")
        func notOpen() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            await expectLockError(.notOpen) { try await fixture.lock.changePassword(current: "alpha pw", new: "x") }
            #expect(fixture.blob(of: "aaaa-1") == Data("alpha pw".utf8))
        }

        @Test("An empty new password throws emptyPassword and changes nothing")
        func emptyNewPassword() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            await expectLockError(.emptyPassword) {
                try await fixture.lock.changePassword(current: "alpha pw", new: "")
            }
            #expect(fixture.blob(of: "aaaa-1") == Data("alpha pw".utf8))
        }

        @Test("A wrong current password throws wrongPassword and leaves the blob unchanged")
        func wrongCurrentPassword() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            await expectLockError(.wrongPassword) { try await fixture.lock.changePassword(current: "nope", new: "new") }
            #expect(fixture.blob(of: "aaaa-1") == Data("alpha pw".utf8))
        }

        @Test("A new password that opens another vault throws passwordInUse and leaves the blob unchanged")
        func newPasswordInUse() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            await expectLockError(.passwordInUse) {
                try await fixture.lock.changePassword(current: "alpha pw", new: "bravo pw")
            }
            #expect(fixture.blob(of: "aaaa-1") == Data("alpha pw".utf8))
        }

        @Test("Changing the password rewraps the blob with the same key and the new password opens the vault")
        func changesPasswordKeepingKey() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            let keyBefore = fixture.shelf.loadedKey(account: fixture.blobAccount("aaaa-1"))
            try await fixture.lock.changePassword(current: "alpha pw", new: "new pw")
            #expect(fixture.blob(of: "aaaa-1") == Data("new pw".utf8))
            #expect(fixture.shelf.loadedKey(account: fixture.blobAccount("aaaa-1")) == keyBefore)
            #expect(fixture.lock.current.id == "aaaa-1")
            fixture.lock.close()
            await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "alpha pw") }
            try await fixture.lock.open(password: "new pw")
            #expect(fixture.lock.current.id == "aaaa-1")
            #expect(fixture.shelf.loadedKey(account: fixture.blobAccount("aaaa-1")) == keyBefore)
        }
    }

    // MARK: Face ID

    @MainActor @Suite struct FaceID {
        @Test("Enabling Face ID with the unencrypted vault current throws notOpen")
        func enableNotOpen() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            await expectLockError(.notOpen) { try await fixture.lock.setUsesBiometrics(true) }
            #expect(fixture.marker == nil)
        }

        @Test("Enabling Face ID when biometrics are unavailable throws biometricsUnavailable")
        func enableUnavailable() async throws {
            let fixture = try VaultLockFixture(canEvaluate: false, vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            await expectLockError(.biometricsUnavailable) { try await fixture.lock.setUsesBiometrics(true) }
            #expect(fixture.marker == nil)
            #expect(fixture.biometricItem == nil)
        }

        @Test("Enabling Face ID stores the vault's key in the biometric item and names the vault in the marker")
        func enable() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            #expect(!fixture.lock.currentUsesBiometrics)
            #expect(!fixture.lock.hasBiometricVault)
            try await fixture.lock.setUsesBiometrics(true)
            #expect(fixture.biometricItem == KeyShelf.keyData(for: fixture.blobAccount("aaaa-1")))
            #expect(fixture.marker == "aaaa-1")
            #expect(fixture.lock.currentUsesBiometrics)
            #expect(fixture.lock.hasBiometricVault)
        }

        @Test("Enabling Face ID for a vault replaces the item and marker of the vault that had it")
        func enableReplacesOtherVault() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "bravo pw")
            #expect(!fixture.lock.currentUsesBiometrics)
            try await fixture.lock.setUsesBiometrics(true)
            #expect(fixture.marker == "bbbb-2")
            #expect(fixture.biometricItem == KeyShelf.keyData(for: fixture.blobAccount("bbbb-2")))
            #expect(fixture.lock.currentUsesBiometrics)
        }

        @Test("A failure storing the key leaves the previous marker and item as they were")
        func enableFailureKeepsMarker() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "bravo pw")
            fixture.shelf.fail("storeBiometricKey", with: .keychain(-25293))
            await expectLockError(.keychain(-25293)) { try await fixture.lock.setUsesBiometrics(true) }
            #expect(fixture.marker == "aaaa-1")
            #expect(fixture.biometricItem == KeyShelf.keyData(for: fixture.blobAccount("aaaa-1")))
            #expect(!fixture.lock.currentUsesBiometrics)
        }

        @Test("A failure storing the key with no earlier Face ID vault leaves no marker")
        func enableFailureWithNoMarker() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            fixture.shelf.fail("storeBiometricKey", with: .keychain(-1))
            await expectLockError(.keychain(-1)) { try await fixture.lock.setUsesBiometrics(true) }
            #expect(fixture.marker == nil)
            #expect(!fixture.lock.currentUsesBiometrics)
        }

        @Test("Disabling Face ID for the vault that has it deletes the item and the marker")
        func disableOwn() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha])
            try await fixture.lock.open(password: "alpha pw")
            #expect(fixture.lock.currentUsesBiometrics)
            try await fixture.lock.setUsesBiometrics(false)
            #expect(fixture.marker == nil)
            #expect(fixture.biometricItem == nil)
            #expect(!fixture.lock.currentUsesBiometrics)
            #expect(!fixture.lock.hasBiometricVault)
        }

        @Test("Disabling Face ID in a vault that does not have it changes nothing")
        func disableOtherVaultsFaceID() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "bravo pw")
            try await fixture.lock.setUsesBiometrics(false)
            #expect(fixture.marker == "aaaa-1")
            #expect(fixture.biometricItem == KeyShelf.keyData(for: fixture.blobAccount("aaaa-1")))
            #expect(fixture.lock.hasBiometricVault)
        }

        @Test("Disabling Face ID when no vault has it changes nothing")
        func disableWithNoFaceID() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            try await fixture.lock.setUsesBiometrics(false)
            #expect(fixture.marker == nil)
            #expect(fixture.biometricItem == nil)
        }

        @Test("currentUsesBiometrics is false in the unencrypted vault even when a vault has Face ID")
        func unencryptedDoesNotUseFaceID() throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha])
            #expect(!fixture.lock.currentUsesBiometrics)
        }

        @Test("hasBiometricVault is false when the marker names a vault that is gone")
        func hasBiometricVaultWithStaleMarker() throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try fixture.giveFaceID(to: "gone-9")
            #expect(!fixture.lock.hasBiometricVault)
        }

        @Test("hasBiometricVault is true when the marker names a listed vault")
        func hasBiometricVaultWithListedVault() throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha])
            #expect(fixture.lock.hasBiometricVault)
        }
    }

    // MARK: deleteCurrentVault

    @MainActor @Suite struct Delete {
        @Test("With the unencrypted vault current it throws notOpen and erases nothing")
        func notOpen() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            await expectLockError(.notOpen) { try await fixture.lock.deleteCurrentVault(password: "alpha pw") }
            #expect(fixture.folderExists("aaaa-1"))
            #expect(fixture.blob(of: "aaaa-1") != nil)
        }

        @Test("A wrong password throws wrongPassword and erases nothing")
        func wrongPassword() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha])
            try await fixture.lock.open(password: "alpha pw")
            await expectLockError(.wrongPassword) { try await fixture.lock.deleteCurrentVault(password: "nope") }
            #expect(fixture.folderExists("aaaa-1"))
            #expect(fixture.blob(of: "aaaa-1") != nil)
            #expect(fixture.marker == "aaaa-1")
            #expect(fixture.biometricItem != nil)
            #expect(fixture.lock.current.id == "aaaa-1")
        }

        @Test("Deleting erases the folder and blob, closes the vault and leaves other vaults alone")
        func deletes() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            let collector = CurrentCollector(fixture.lock.currentUpdates())
            try await fixture.lock.deleteCurrentVault(password: "alpha pw")
            await collector.settle()
            #expect(!fixture.folderExists("aaaa-1"))
            #expect(fixture.blob(of: "aaaa-1") == nil)
            #expect(fixture.folderExists("bbbb-2"))
            #expect(fixture.blob(of: "bbbb-2") != nil)
            #expect(fixture.lock.current.id == "unencrypted")
            #expect(!fixture.isLoaded("aaaa-1"))
            #expect(fixture.registry.removedTemporaryFiles("aaaa-1"))
            #expect(collector.ids == ["unencrypted"])
        }

        @Test("Deleting the Face ID vault removes its Face ID item and marker before the folder and blob")
        func deletesFaceIDFirst() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha])
            try await fixture.lock.open(password: "alpha pw")
            try await fixture.lock.deleteCurrentVault(password: "alpha pw")
            #expect(fixture.marker == nil)
            #expect(fixture.biometricItem == nil)
            let calls = fixture.keychain.calls
            let item = calls.firstIndex(of: .delete(account: KeyShelf.biometricAccount))
            let marker = calls.firstIndex(of: .delete(account: VaultCatalog.markerAccount))
            let blob = calls.firstIndex(of: .delete(account: fixture.blobAccount("aaaa-1")))
            #expect(item != nil && marker != nil && blob != nil)
            #expect((item ?? Int.max) < (blob ?? 0))
            #expect((marker ?? Int.max) < (blob ?? 0))
        }

        @Test("The folder is gone before the blob is deleted")
        func folderBeforeBlob() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            try await fixture.lock.deleteCurrentVault(password: "alpha pw")
            #expect(fixture.shelf.events.contains("deleteBlob:folderExists=false"))
        }

        @Test("Deleting a vault keeps another vault's Face ID")
        func keepsOtherFaceID() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "bravo pw")
            try await fixture.lock.deleteCurrentVault(password: "bravo pw")
            #expect(fixture.marker == "aaaa-1")
            #expect(fixture.biometricItem != nil)
        }

        @Test("A Face ID deletion failure throws and leaves the folder and blob in place")
        func faceIDFailureLeavesVault() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha])
            try await fixture.lock.open(password: "alpha pw")
            fixture.shelf.fail("deleteBiometricKey", with: .keychain(-25244))
            await expectLockError(.keychain(-25244)) { try await fixture.lock.deleteCurrentVault(password: "alpha pw") }
            #expect(fixture.folderExists("aaaa-1"))
            #expect(fixture.blob(of: "aaaa-1") != nil)
        }

        @Test("A blob deletion failure throws after the folder is gone")
        func blobFailureThrows() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            fixture.shelf.fail("deleteMasterKeyBlob", with: .keychain(-25244))
            await expectLockError(.keychain(-25244)) { try await fixture.lock.deleteCurrentVault(password: "alpha pw") }
            #expect(!fixture.folderExists("aaaa-1"))
            #expect(fixture.folderExists("bbbb-2"))
            #expect(fixture.blob(of: "bbbb-2") != nil)
        }
    }

    // MARK: Transfer target

    @MainActor @Suite struct TransferTarget {
        @Test("An empty password throws emptyPassword")
        func emptyPassword() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            await expectLockError(.emptyPassword) { _ = try await fixture.lock.openTransferTarget(password: "") }
        }

        @Test("The open vault's own password throws sameVault and loads nothing new")
        func sameVault() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            await expectLockError(.sameVault) { _ = try await fixture.lock.openTransferTarget(password: "alpha pw") }
            #expect(fixture.lock.current.id == "aaaa-1")
            #expect(!fixture.isLoaded("bbbb-2"))
        }

        @Test("A password that opens no vault throws wrongPassword")
        func wrongPassword() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            await expectLockError(.wrongPassword) { _ = try await fixture.lock.openTransferTarget(password: "nope") }
            #expect(fixture.lock.current.id == "aaaa-1")
        }

        @Test("The target is an open vault with its own loaded key, separate from current, and current is unchanged")
        func opensSeparateTarget() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            let collector = CurrentCollector(fixture.lock.currentUpdates())
            let target = try await fixture.lock.openTransferTarget(password: "bravo pw")
            await collector.settle()
            #expect(target.id == "bbbb-2")
            #expect(target.name == "Bravo")
            #expect(target.isEncrypted)
            #expect(fixture.lock.current.id == "aaaa-1")
            #expect(collector.ids.isEmpty)
            let currentKey = fixture.shelf.loadedKey(account: fixture.blobAccount("aaaa-1"))
            let targetKey = fixture.shelf.loadedKey(account: fixture.blobAccount("bbbb-2"))
            #expect(currentKey != nil && targetKey != nil)
            #expect(currentKey != targetKey)
        }

        @Test("With the unencrypted vault current any vault can be a target")
        func targetFromUnencrypted() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            let target = try await fixture.lock.openTransferTarget(password: "alpha pw")
            #expect(target.id == "aaaa-1")
            #expect(fixture.lock.current.id == "unencrypted")
        }

        @Test("Closing the target wipes its key and temp files and leaves current open")
        func closeTarget() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            let target = try await fixture.lock.openTransferTarget(password: "bravo pw")
            fixture.lock.closeTransferTarget(target)
            #expect(!fixture.isLoaded("bbbb-2"))
            #expect(fixture.registry.removedTemporaryFiles("bbbb-2"))
            #expect(fixture.isLoaded("aaaa-1"))
            #expect(fixture.lock.current.id == "aaaa-1")
            #expect(!fixture.registry.removedTemporaryFiles("aaaa-1"))
        }
    }

    // MARK: upgradeIfNeeded

    @MainActor @Suite struct Upgrade {
        @Test("A locked 1.2 vault becomes the vault primary and opens with its old password")
        func upgradesLockedVault() async throws {
            let fixture = try VaultLockFixture(upgraded: false, lockMode: .password)
            let oldAccount = "com.KoalaTVault.masterKeyBlob"
            try fixture.keychain.write(Data("old pw".utf8), account: oldAccount, accessibility: .whenUnlocked)
            try Data("map".utf8).write(to: fixture.documents.appendingPathComponent(".vault_map"))
            try Data("file".utf8).write(to: fixture.documents.appendingPathComponent("11111111"))
            try await fixture.lock.upgradeIfNeeded()
            let documentNames = try FileManager.default.contentsOfDirectory(atPath: fixture.documents.path)
            #expect(documentNames.isEmpty)
            #expect(fixture.vaultFolderNames == ["primary"])
            #expect(fixture.preferences.vaultsUpgraded)
            try await fixture.lock.open(password: "old pw")
            #expect(fixture.lock.current.id == "primary")
            #expect(fixture.lock.current.name == "My Vault")
            #expect(fixture.lock.current.isEncrypted)
        }

        @Test("An unlocked 1.2 vault stays in Documents and only the upgraded flag is set")
        func upgradesUnlockedVault() async throws {
            let fixture = try VaultLockFixture(upgraded: false, lockMode: .none)
            try Data("photo".utf8).write(to: fixture.documents.appendingPathComponent("photo.jpg"))
            try await fixture.lock.upgradeIfNeeded()
            #expect(FileManager.default.fileExists(atPath: fixture.documents.appendingPathComponent("photo.jpg").path))
            #expect(fixture.vaultFolderNames.isEmpty)
            #expect(fixture.preferences.vaultsUpgraded)
            #expect(fixture.lock.current.id == "unencrypted")
        }

        @Test("When vaultsUpgraded is already true the upgrade moves nothing")
        func alreadyUpgraded() async throws {
            let fixture = try VaultLockFixture(upgraded: true, lockMode: .password)
            try Data("map".utf8).write(to: fixture.documents.appendingPathComponent(".vault_map"))
            try await fixture.lock.upgradeIfNeeded()
            #expect(FileManager.default.fileExists(atPath: fixture.documents.appendingPathComponent(".vault_map").path))
            #expect(fixture.vaultFolderNames.isEmpty)
        }

        @Test("upgradeIfNeeded removes an empty folder with no blob and keeps real vaults")
        func removesInterruptedCreations() async throws {
            let fixture = try VaultLockFixture(upgraded: true, vaults: [LiveVaultLockTests.alpha])
            try fixture.seedBloblessFolder("dead-1")
            try await fixture.lock.upgradeIfNeeded()
            #expect(!fixture.folderExists("dead-1"))
            #expect(fixture.folderExists("aaaa-1"))
            #expect(fixture.blob(of: "aaaa-1") != nil)
        }

        @Test("upgradeIfNeeded keeps a blobless folder that holds files")
        func keepsNonEmptyBloblessFolder() async throws {
            let fixture = try VaultLockFixture(upgraded: true)
            try fixture.seedBloblessFolder("odd-2", files: ["data"])
            try await fixture.lock.upgradeIfNeeded()
            #expect(fixture.folderExists("odd-2"))
        }
    }
}
