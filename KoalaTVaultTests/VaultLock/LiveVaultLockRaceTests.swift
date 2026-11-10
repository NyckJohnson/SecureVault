import Foundation
import Testing

@testable import KoalaTVault

/// Password checks and races: fresh key stores, results dropped when the lock changes mid-check, serial creation.
extension LiveVaultLockTests {
    // MARK: Fresh key stores

    @MainActor @Suite struct FreshStores {
        @Test("Opening the open vault's own password leaves it open, its key store untouched, and wipes the probe")
        func ownPasswordUsesFreshStore() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha])
            try await fixture.lock.open(password: "alpha pw")
            try await fixture.lock.open(password: "alpha pw")
            let stores = fixture.shelf.instances(account: fixture.blobAccount("aaaa-1"))
            #expect(stores.count == 2)
            let own = try #require(stores.first)
            let probe = try #require(stores.last)
            #expect(own.unlockCalls == 1)
            #expect(own.wipeCalls == 0)
            #expect(own.isKeyLoaded)
            #expect(probe.unlockCalls == 1)
            #expect(!probe.isKeyLoaded)
            #expect(fixture.lock.current.id == "aaaa-1")
        }

        @Test("Probes that did not become current are wiped")
        func losingProbesAreWiped() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            try await fixture.lock.open(password: "bravo pw")
            #expect(fixture.shelf.loadedAccounts() == [fixture.blobAccount("bbbb-2")])
            let alphaStores = fixture.shelf.instances(account: fixture.blobAccount("aaaa-1"))
            #expect(alphaStores.allSatisfy { !$0.isKeyLoaded })
        }

        @Test("A transfer target check with a wrong password leaves no extra key loaded")
        func wrongTransferPasswordLoadsNothing() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            await expectLockError(.wrongPassword) { _ = try await fixture.lock.openTransferTarget(password: "nope") }
            #expect(fixture.shelf.loadedAccounts() == [fixture.blobAccount("aaaa-1")])
        }
    }

    // MARK: A check interrupted by close, background or another open

    @MainActor @Suite struct Interrupted {
        private func expectedLoaded(_ fixture: VaultLockFixture, _ interrupt: Interrupt) -> [String] {
            interrupt == .openBravo ? [fixture.blobAccount("bbbb-2")] : []
        }

        @Test("open(password:) interrupted throws notOpen and opens nothing", arguments: Interrupt.allCases)
        func openInterrupted(interrupt: Interrupt) async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            let result = await fixture.runHeld("unlock", interrupt: interrupt) {
                try await fixture.lock.open(password: "alpha pw")
            }
            expectFailure(result, .notOpen)
            #expect(fixture.lock.current.id == interrupt.currentID)
            #expect(fixture.shelf.loadedAccounts() == expectedLoaded(fixture, interrupt))
        }

        @Test("openWithBiometrics interrupted throws notOpen and opens nothing", arguments: Interrupt.allCases)
        func biometricInterrupted(interrupt: Interrupt) async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha, LiveVaultLockTests.bravo])
            let result = await fixture.runHeld("unlockWithBiometricKey", interrupt: interrupt) {
                try await fixture.lock.openWithBiometrics()
            }
            expectFailure(result, .notOpen)
            #expect(fixture.lock.current.id == interrupt.currentID)
            #expect(fixture.shelf.loadedAccounts() == expectedLoaded(fixture, interrupt))
        }

        @Test("openTransferTarget interrupted throws notOpen and leaves no target key", arguments: Interrupt.allCases)
        func transferInterrupted(interrupt: Interrupt) async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            let result = await fixture.runHeld("unlock", interrupt: interrupt) {
                _ = try await fixture.lock.openTransferTarget(password: "alpha pw")
            }
            expectFailure(result, .notOpen)
            #expect(fixture.lock.current.id == interrupt.currentID)
            #expect(fixture.shelf.loadedAccounts() == expectedLoaded(fixture, interrupt))
        }

        @Test("changePassword interrupted throws notOpen and leaves the blob unchanged", arguments: Interrupt.allCases)
        func changePasswordInterrupted(interrupt: Interrupt) async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            let result = await fixture.runHeld("unlock", interrupt: interrupt) {
                try await fixture.lock.changePassword(current: "alpha pw", new: "new pw")
            }
            expectFailure(result, .notOpen)
            #expect(fixture.blob(of: "aaaa-1") == Data("alpha pw".utf8))
            #expect(fixture.lock.current.id == interrupt.currentID)
            #expect(fixture.shelf.loadedAccounts() == expectedLoaded(fixture, interrupt))
        }

        @Test("deleteCurrentVault interrupted throws notOpen and erases nothing", arguments: Interrupt.allCases)
        func deleteInterrupted(interrupt: Interrupt) async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            let result = await fixture.runHeld("unlock", interrupt: interrupt) {
                try await fixture.lock.deleteCurrentVault(password: "alpha pw")
            }
            expectFailure(result, .notOpen)
            #expect(fixture.folderExists("aaaa-1"))
            #expect(fixture.blob(of: "aaaa-1") == Data("alpha pw".utf8))
            #expect(fixture.marker == "aaaa-1")
            #expect(fixture.biometricItem == KeyShelf.keyData(for: fixture.blobAccount("aaaa-1")))
            #expect(fixture.lock.current.id == interrupt.currentID)
        }

        @Test("setUsesBiometrics(true) interrupted throws notOpen and changes nothing", arguments: Interrupt.allCases)
        func enableFaceIDInterrupted(interrupt: Interrupt) async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.alpha, LiveVaultLockTests.bravo])
            try await fixture.lock.open(password: "alpha pw")
            let result = await fixture.runHeld("storeBiometricKey", interrupt: interrupt) {
                try await fixture.lock.setUsesBiometrics(true)
            }
            expectFailure(result, .notOpen)
            #expect(fixture.marker == nil)
            #expect(fixture.biometricItem == nil)
            #expect(fixture.blob(of: "aaaa-1") == Data("alpha pw".utf8))
            #expect(fixture.folderExists("aaaa-1"))
        }

        @Test("createVault interrupted by close keeps the vault, wipes its key and stays unencrypted")
        func createInterrupted() async throws {
            for interrupt in [Interrupt.close, .background] {
                let fixture = try VaultLockFixture(pro: true)
                let result = await fixture.runHeld("createMasterKey", interrupt: interrupt) {
                    try await fixture.lock.createVault(name: "Work", password: "work pw")
                }
                if case .failure(let error) = result { Issue.record("createVault threw \(error)") }
                let id = try #require(fixture.vaultFolderNames.first)
                #expect(fixture.vaultFolderNames.count == 1)
                #expect(fixture.blob(of: id) != nil)
                #expect(fixture.lock.current.id == "unencrypted")
                #expect(fixture.shelf.loadedAccounts().isEmpty)
                try await fixture.lock.open(password: "work pw")
                #expect(fixture.lock.current.id == id)
            }
        }

        @Test("Two concurrent createVault calls with one password make one vault and one passwordInUse")
        func concurrentCreate() async throws {
            let fixture = try VaultLockFixture(pro: true)
            fixture.shelf.hold("createMasterKey")
            let first = Task { @MainActor in try await fixture.lock.createVault(name: "One", password: "same") }
            await fixture.waitUntilEntered("createMasterKey")
            let second = Task { @MainActor in try await fixture.lock.createVault(name: "Two", password: "same") }
            try await Task.sleep(for: .milliseconds(100))
            fixture.shelf.release("createMasterKey")
            let firstResult = await first.result
            let secondResult = await second.result
            if case .failure(let error) = firstResult { Issue.record("The first createVault threw \(error)") }
            expectFailure(secondResult, .passwordInUse)
            #expect(fixture.vaultFolderNames.count == 1)
        }
    }

    // MARK: setUsesBiometrics(false) in the unencrypted vault

    @MainActor @Suite struct DisableInUnencrypted {
        @Test("setUsesBiometrics(false) in the unencrypted vault does nothing and throws nothing")
        func noOp() async throws {
            let fixture = try VaultLockFixture(vaults: [LiveVaultLockTests.faceAlpha])
            let before = fixture.keychain.calls.count
            try await fixture.lock.setUsesBiometrics(false)
            #expect(fixture.marker == "aaaa-1")
            #expect(fixture.biometricItem == KeyShelf.keyData(for: fixture.blobAccount("aaaa-1")))
            let deletes = fixture.keychain.calls.dropFirst(before).filter { $0 != .read(account: "", prompt: nil) }
            #expect(!deletes.contains { if case .delete = $0 { true } else { false } })
            #expect(fixture.lock.current.id == "unencrypted")
        }
    }
}
