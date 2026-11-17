import Foundation
import Testing

@testable import KoalaTVault

struct BiometricFailureCase: Sendable {
    let crypto: VaultCryptoError
    let expected: VaultLockError
}

/// The vault registry: launch state, opening (password and Face ID), creating and closing vaults.
/// Management of an open vault (password, Face ID, delete, transfer, upgrade) is in the extension file.
@MainActor
@Suite struct LiveVaultLockTests {
    static let alpha = SeedVault(id: "aaaa-1", name: "Alpha", password: "alpha pw")
    static let bravo = SeedVault(id: "bbbb-2", name: "Bravo", password: "bravo pw")

    // MARK: Launch and publishing

    @MainActor @Suite struct Launch {
        @Test("At launch the unencrypted vault is current, named KoalaTVault, over the injected plaintext store")
        func launchesInUnencryptedVault() throws {
            let fixture = try VaultLockFixture()
            let current = fixture.lock.current
            #expect(current.id == "unencrypted")
            #expect(current.name == "KoalaTVault")
            #expect(!current.isEncrypted)
            #expect((current.store as? MockVaultStoring) === fixture.unencryptedStore)
        }

        @Test("unencryptedVault is the same vault as the launch state and stays after opening another vault")
        func unencryptedVaultAlwaysThere() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            #expect(fixture.lock.unencryptedVault.id == "unencrypted")
            #expect((fixture.lock.unencryptedVault.store as? MockVaultStoring) === fixture.unencryptedStore)
            try await fixture.lock.open(password: "alpha pw")
            #expect(fixture.lock.unencryptedVault.id == "unencrypted")
            #expect(!fixture.lock.unencryptedVault.isEncrypted)
        }

        @Test("Biometric kind and availability come from the injected info")
        func biometricInfoFromProbe() throws {
            let touch = try VaultLockFixture(canEvaluate: true, biometricKind: .touchID)
            #expect(touch.lock.biometricKind == .touchID)
            #expect(touch.lock.biometricsAvailable)
            let none = try VaultLockFixture(canEvaluate: false, biometricKind: .none)
            #expect(none.lock.biometricKind == BiometricKind.none)
            #expect(!none.lock.biometricsAvailable)
        }

        @Test("currentUpdates publishes nothing until current changes")
        func noInitialValue() async throws {
            let fixture = try VaultLockFixture()
            let collector = CurrentCollector(fixture.lock.currentUpdates())
            await collector.settle()
            #expect(collector.ids.isEmpty)
        }

        @Test("currentUpdates publishes each change of current once, in order")
        func publishesEachChangeOnce() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            let collector = CurrentCollector(fixture.lock.currentUpdates())
            try await fixture.lock.open(password: "alpha pw")
            try await fixture.lock.open(password: "bravo pw")
            fixture.lock.close()
            await collector.settle()
            #expect(collector.ids == ["aaaa-1", "bbbb-2", "unencrypted"])
        }

        @Test("currentUpdates publishes nothing when current does not change")
        func doesNotPublishNonChanges() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            let collector = CurrentCollector(fixture.lock.currentUpdates())
            fixture.lock.close()
            await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "nope") }
            try await fixture.lock.open(password: "alpha pw")
            try await fixture.lock.open(password: "alpha pw")
            await collector.settle()
            #expect(collector.ids == ["aaaa-1"])
        }
    }

    // MARK: open(password:)

    @MainActor @Suite struct Open {
        @Test("An empty password throws emptyPassword and tries no vault")
        func emptyPassword() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            await expectLockError(.emptyPassword) { try await fixture.lock.open(password: "") }
            #expect(fixture.shelf.events.isEmpty)
            #expect(fixture.lock.current.id == "unencrypted")
        }

        @Test("A wrong password throws wrongPassword, leaves the unencrypted vault current and no key loaded")
        func wrongPassword() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "nope") }
            #expect(fixture.lock.current.id == "unencrypted")
            #expect(!fixture.isLoaded("aaaa-1"))
            #expect(!fixture.isLoaded("bbbb-2"))
        }

        @Test("With no encrypted vault any password throws wrongPassword")
        func wrongPasswordWithNoVaults() async throws {
            let fixture = try VaultLockFixture()
            await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "anything") }
            #expect(fixture.lock.current.id == "unencrypted")
        }

        @Test("A password opens the vault it belongs to, with its name, encrypted, key loaded")
        func opensTheMatchingVault() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "bravo pw")
            let current = fixture.lock.current
            #expect(current.id == "bbbb-2")
            #expect(current.name == "Bravo")
            #expect(current.isEncrypted)
            #expect(current.store.isEncrypted)
            #expect(fixture.isLoaded("bbbb-2"))
            #expect(!fixture.isLoaded("aaaa-1"))
        }

        @Test("When two vaults share a password the first one found opens and later ones are not tried")
        func firstMatchWins() async throws {
            let first = SeedVault(id: "aaaa-1", name: "First", password: "same")
            let second = SeedVault(id: "bbbb-2", name: "Second", password: "same")
            let fixture = try VaultLockFixture(vaults: [second, first])
            try await fixture.lock.open(password: "same")
            #expect(fixture.lock.current.id == "aaaa-1")
            #expect(!fixture.shelf.events.contains("unlock:bbbb-2"))
        }

        @Test("Opening the vault that is already open changes nothing")
        func alreadyOpenIsNoChange() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            let collector = CurrentCollector(fixture.lock.currentUpdates())
            try await fixture.lock.open(password: "alpha pw")
            await collector.settle()
            #expect(collector.ids.isEmpty)
            #expect(fixture.lock.current.id == "aaaa-1")
            #expect(fixture.isLoaded("aaaa-1"))
            let first = try #require(fixture.shelf.instances(account: fixture.blobAccount("aaaa-1")).first)
            #expect(first.isKeyLoaded)
            #expect(first.wipeCalls == 0)
        }

        @Test("Opening another vault first closes the open one: key wiped, temp files removed")
        func switchingClosesTheOldVaultFirst() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            try await fixture.lock.open(password: "bravo pw")
            #expect(fixture.lock.current.id == "bbbb-2")
            #expect(!fixture.isLoaded("aaaa-1"))
            #expect(fixture.isLoaded("bbbb-2"))
            #expect(fixture.registry.removedTemporaryFiles("aaaa-1"))
            #expect(!fixture.registry.removedTemporaryFiles("bbbb-2"))
        }

        @Test("A missing .vault_info shows the name My Vault and writes it")
        func missingNameIsWritten() async throws {
            let nameless = SeedVault(id: "cccc-3", name: nil, password: "charlie pw")
            let fixture = try VaultLockFixture(vaults: [nameless])
            #expect(fixture.storedName(of: "cccc-3") == nil)
            try await fixture.lock.open(password: "charlie pw")
            #expect(fixture.lock.current.name == "My Vault")
            #expect(fixture.storedName(of: "cccc-3") == "My Vault")
        }

        @Test("A vault's own name is read from its .vault_info and not overwritten")
        func existingNameIsKept() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            #expect(fixture.lock.current.name == "Alpha")
            #expect(fixture.storedName(of: "aaaa-1") == "Alpha")
        }
    }

    // MARK: openWithBiometrics

    @MainActor @Suite struct BiometricOpen {
        private static let faceVault = SeedVault(id: "aaaa-1", name: "Alpha", password: "alpha pw", faceID: true)

        @Test("With no marker it throws noBiometricVault, even when biometrics are unavailable")
        func noMarker() async throws {
            let fixture = try VaultLockFixture(canEvaluate: false, vaults: [LiveVaultLockTests.alpha])
            await expectLockError(.noBiometricVault) { try await fixture.lock.openWithBiometrics() }
            #expect(fixture.lock.current.id == "unencrypted")
        }

        @Test("A marker naming a vault that is gone throws noBiometricVault")
        func markerNamesMissingVault() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try fixture.giveFaceID(to: "gone-9")
            await expectLockError(.noBiometricVault) { try await fixture.lock.openWithBiometrics() }
        }

        @Test("When biometrics are unavailable it throws biometricsUnavailable and loads no key")
        func unavailable() async throws {
            let fixture = try VaultLockFixture(canEvaluate: false, vaults: [Self.faceVault])
            await expectLockError(.biometricsUnavailable) { try await fixture.lock.openWithBiometrics() }
            #expect(!fixture.isLoaded("aaaa-1"))
            #expect(fixture.lock.current.id == "unencrypted")
        }

        @Test("Success opens the Face ID vault like open(password:), with its name and key")
        func success() async throws {
            let fixture = try VaultLockFixture(vaults: [Self.faceVault, LiveVaultLockTests.bravo])
            let collector = CurrentCollector(fixture.lock.currentUpdates())
            try await fixture.lock.openWithBiometrics()
            await collector.settle()
            #expect(fixture.lock.current.id == "aaaa-1")
            #expect(fixture.lock.current.name == "Alpha")
            #expect(fixture.lock.current.isEncrypted)
            #expect(fixture.isLoaded("aaaa-1"))
            #expect(collector.ids == ["aaaa-1"])
            #expect(fixture.marker == "aaaa-1")
        }

        @Test("Success while another vault is open closes that vault first")
        func successClosesOpenVault() async throws {
            let fixture = try VaultLockFixture(vaults: [Self.faceVault, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "bravo pw")
            try await fixture.lock.openWithBiometrics()
            #expect(fixture.lock.current.id == "aaaa-1")
            #expect(!fixture.isLoaded("bbbb-2"))
            #expect(fixture.registry.removedTemporaryFiles("bbbb-2"))
        }

        @Test("A key that does not open the vault wipes it, deletes the item and marker, throws biometricChanged")
        func keyDoesNotMatchVault() async throws {
            let fixture = try VaultLockFixture(vaults: [Self.faceVault])
            fixture.registry.keyDoesNotMatch("aaaa-1")
            await expectLockError(.biometricChanged) { try await fixture.lock.openWithBiometrics() }
            #expect(!fixture.isLoaded("aaaa-1"))
            #expect(fixture.biometricItem == nil)
            #expect(fixture.marker == nil)
            #expect(fixture.lock.current.id == "unencrypted")
            #expect(!fixture.lock.hasBiometricVault)
        }

        @Test("A missing biometric item deletes the marker and throws biometricChanged")
        func itemMissing() async throws {
            let fixture = try VaultLockFixture(vaults: [Self.faceVault])
            try fixture.keychain.delete(account: KeyShelf.biometricAccount)
            await expectLockError(.biometricChanged) { try await fixture.lock.openWithBiometrics() }
            #expect(fixture.marker == nil)
            #expect(!fixture.isLoaded("aaaa-1"))
            #expect(fixture.lock.current.id == "unencrypted")
        }

        static let failureCases = [
            BiometricFailureCase(crypto: .biometricCancelled, expected: .biometricCancelled),
            BiometricFailureCase(crypto: .biometryLockedOut, expected: .biometryLockedOut),
            BiometricFailureCase(crypto: .biometryNotEnrolled, expected: .biometryNotEnrolled),
            BiometricFailureCase(crypto: .passcodeNotSet, expected: .passcodeNotSet),
        ]

        @Test("Cancel, lockout, not enrolled and no passcode map to their own errors and keep the Face ID setup")
        func mappedFailures() async throws {
            for failure in Self.failureCases {
                let fixture = try VaultLockFixture(vaults: [Self.faceVault])
                fixture.shelf.fail("unlockWithBiometricKey", with: failure.crypto)
                await expectLockError(failure.expected) { try await fixture.lock.openWithBiometrics() }
                #expect(fixture.marker == "aaaa-1")
                #expect(fixture.biometricItem != nil)
                #expect(fixture.lock.current.id == "unencrypted")
            }
        }
    }

    // MARK: canCreateVault and createVault

    @MainActor @Suite struct Create {
        @Test("With no encrypted vault a free user can create one")
        func canCreateFirstVault() async throws {
            let fixture = try VaultLockFixture(pro: false)
            #expect(await fixture.lock.canCreateVault())
        }

        @Test("A free user with an encrypted vault cannot create another")
        func freeUserLimit() async throws {
            let fixture = try VaultLockFixture(pro: false, vaults: [LiveVaultLockTests.alpha])
            #expect(await !fixture.lock.canCreateVault())
        }

        @Test("A Pro user can create more vaults")
        func proUserCanCreateMore() async throws {
            let fixture = try VaultLockFixture(pro: true, vaults: [LiveVaultLockTests.alpha])
            #expect(await fixture.lock.canCreateVault())
        }

        @Test("An empty or whitespace-only name throws emptyName and creates nothing")
        func emptyName() async throws {
            let fixture = try VaultLockFixture()
            await expectLockError(.emptyName) { try await fixture.lock.createVault(name: "", password: "pw") }
            await expectLockError(.emptyName) { try await fixture.lock.createVault(name: " \n ", password: "pw") }
            #expect(fixture.vaultFolderNames.isEmpty)
            #expect(fixture.keychain.items.isEmpty)
        }

        @Test("The name is checked before the password")
        func emptyNameBeforeEmptyPassword() async throws {
            let fixture = try VaultLockFixture()
            await expectLockError(.emptyName) { try await fixture.lock.createVault(name: "", password: "") }
        }

        @Test("An empty password throws emptyPassword and creates nothing")
        func emptyPassword() async throws {
            let fixture = try VaultLockFixture()
            await expectLockError(.emptyPassword) { try await fixture.lock.createVault(name: "Work", password: "") }
            #expect(fixture.vaultFolderNames.isEmpty)
            #expect(fixture.keychain.items.isEmpty)
        }

        @Test("A free user with a vault gets vaultLimitReached and nothing is created")
        func limitReached() async throws {
            let fixture = try VaultLockFixture(pro: false, vaults: [LiveVaultLockTests.alpha])
            await expectLockError(.vaultLimitReached) { try await fixture.lock.createVault(name: "Two", password: "x") }
            #expect(fixture.vaultFolderNames == ["aaaa-1"])
            #expect(fixture.lock.current.id == "unencrypted")
        }

        @Test("A password that opens an existing vault throws passwordInUse and creates nothing")
        func passwordInUse() async throws {
            let fixture = try VaultLockFixture(pro: true, vaults: [LiveVaultLockTests.alpha])
            await expectLockError(.passwordInUse) {
                try await fixture.lock.createVault(name: "Two", password: "alpha pw")
            }
            #expect(fixture.vaultFolderNames == ["aaaa-1"])
            #expect(fixture.lock.current.id == "unencrypted")
        }

        @Test("Creating makes a UUID folder, its blob account and .vault_info, and opens it as current")
        func createsAndOpensTheVault() async throws {
            let fixture = try VaultLockFixture()
            let collector = CurrentCollector(fixture.lock.currentUpdates())
            try await fixture.lock.createVault(name: "  Work  ", password: "work pw")
            await collector.settle()
            let names = fixture.vaultFolderNames
            let id = try #require(names.first)
            #expect(names.count == 1)
            #expect(UUID(uuidString: id) != nil)
            #expect(fixture.keychain.items["com.KoalaTVault.masterKeyBlob.\(id)"] != nil)
            #expect(fixture.storedName(of: id) == "Work")
            let current = fixture.lock.current
            #expect(current.id == id)
            #expect(current.name == "Work")
            #expect(current.isEncrypted)
            #expect(fixture.isLoaded(id))
            #expect(collector.ids == [id])
        }

        @Test("The new vault opens again by its password after closing")
        func newVaultOpensByPassword() async throws {
            let fixture = try VaultLockFixture()
            try await fixture.lock.createVault(name: "Work", password: "work pw")
            let id = fixture.lock.current.id
            fixture.lock.close()
            try await fixture.lock.open(password: "work pw")
            #expect(fixture.lock.current.id == id)
        }

        @Test("A Pro user's second vault gets its own folder and blob, and the first vault is closed")
        func secondVault() async throws {
            let fixture = try VaultLockFixture(pro: true, vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            try await fixture.lock.createVault(name: "Two", password: "two pw")
            #expect(fixture.vaultFolderNames.count == 2)
            #expect(fixture.lock.current.id != "aaaa-1")
            #expect(fixture.lock.current.name == "Two")
            #expect(!fixture.isLoaded("aaaa-1"))
        }

        @Test("A failure after the folder and blob exist removes both and rethrows")
        func failureCleansUp() async throws {
            let fixture = try VaultLockFixture()
            fixture.failCiphers(with: .encryptionFailed)
            var thrown = false
            do {
                try await fixture.lock.createVault(name: "Work", password: "work pw")
            } catch {
                thrown = true
            }
            #expect(thrown)
            #expect(fixture.vaultFolderNames.isEmpty)
            #expect(fixture.keychain.items.isEmpty)
            #expect(fixture.lock.current.id == "unencrypted")
        }

        @Test("A key creation failure throws its error and leaves no folder and no blob")
        func keyCreationFailure() async throws {
            let fixture = try VaultLockFixture()
            fixture.shelf.fail("createMasterKey", with: .keychain(-25299))
            await expectLockError(.keychain(-25299)) { try await fixture.lock.createVault(name: "W", password: "pw") }
            #expect(fixture.vaultFolderNames.isEmpty)
            #expect(fixture.keychain.items.isEmpty)
            #expect(fixture.lock.current.id == "unencrypted")
        }
    }

    // MARK: close and backgrounding

    @MainActor @Suite struct Close {
        @Test("Closing an open encrypted vault wipes its key, removes its temp files and returns to unencrypted")
        func closeEncrypted() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            let collector = CurrentCollector(fixture.lock.currentUpdates())
            fixture.lock.close()
            await collector.settle()
            #expect(fixture.lock.current.id == "unencrypted")
            #expect(!fixture.isLoaded("aaaa-1"))
            #expect(fixture.registry.removedTemporaryFiles("aaaa-1"))
            #expect(collector.ids == ["unencrypted"])
        }

        @Test("Closing while the unencrypted vault is current does nothing")
        func closeUnencrypted() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            let collector = CurrentCollector(fixture.lock.currentUpdates())
            fixture.lock.close()
            await collector.settle()
            #expect(fixture.lock.current.id == "unencrypted")
            #expect(collector.ids.isEmpty)
            #expect(fixture.shelf.events.isEmpty)
            #expect(fixture.unencryptedStore.calls.isEmpty)
        }

        @Test("Closing also closes an open transfer target")
        func closeClosesTransferTarget() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            _ = try await fixture.lock.openTransferTarget(password: "bravo pw")
            #expect(fixture.isLoaded("bbbb-2"))
            fixture.lock.close()
            #expect(!fixture.isLoaded("bbbb-2"))
            #expect(fixture.registry.removedTemporaryFiles("bbbb-2"))
            #expect(!fixture.isLoaded("aaaa-1"))
        }

        @Test("appWillResignActive asks for the privacy cover only while an encrypted vault is open")
        func resignActive() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            #expect(!fixture.lock.appWillResignActive())
            try await fixture.lock.open(password: "alpha pw")
            #expect(fixture.lock.appWillResignActive())
            #expect(fixture.lock.current.id == "aaaa-1")
        }

        @Test("appDidEnterBackground closes an open encrypted vault like close()")
        func backgroundCloses() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            fixture.lock.appDidEnterBackground()
            #expect(fixture.lock.current.id == "unencrypted")
            #expect(!fixture.isLoaded("aaaa-1"))
            #expect(fixture.registry.removedTemporaryFiles("aaaa-1"))
        }

        @Test("appDidEnterBackground with the unencrypted vault current changes nothing")
        func backgroundOnUnencrypted() async throws {
            let fixture = try VaultLockFixture()
            fixture.lock.appDidEnterBackground()
            #expect(fixture.lock.current.id == "unencrypted")
            #expect(fixture.shelf.events.isEmpty)
        }
    }
}
