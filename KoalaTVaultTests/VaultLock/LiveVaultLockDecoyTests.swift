import Foundation
import Testing

@testable import KoalaTVault

/// The decoy derivation: a password search with no vault to try still runs one derivation, so a wrong password
/// is not faster when there are no encrypted vaults.
@MainActor
@Suite struct LiveVaultLockDecoyTests {
    static let alpha = SeedVault(id: "aaaa-1", name: "Alpha", password: "alpha pw")
    static let bravo = SeedVault(id: "bbbb-2", name: "Bravo", password: "bravo pw")

    private static func unlockCount(_ decoy: MockMasterKeyStoring) -> Int {
        decoy.calls.filter { $0 == .unlock }.count
    }

    /// Waits (up to three seconds) until the decoy blob has been made and its key wiped.
    private static func waitForDecoyBlob(_ decoy: MockMasterKeyStoring) async {
        for _ in 0..<600 {
            if decoy.calls.contains(.createMasterKey), decoy.calls.contains(.wipeKey) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The decoy blob was never made")
    }

    // MARK: Making the decoy blob

    @Test("The decoy factory is called once per lock, however many searches run")
    func factoryCalledOncePerLock() async throws {
        let fixture = try VaultLockFixture()
        _ = fixture.lock
        await Self.waitForDecoyBlob(fixture.decoy)
        await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "a") }
        await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "b") }
        #expect(fixture.decoys.factoryCalls == 1)
    }

    @Test("The decoy blob is made when the lock is made, before any search, with its key wiped at once")
    func blobMadeAtLockCreation() async throws {
        let fixture = try VaultLockFixture()
        _ = fixture.lock
        await Self.waitForDecoyBlob(fixture.decoy)
        let calls = fixture.decoy.calls
        #expect(calls.filter { $0 == .createMasterKey }.count == 1)
        #expect(!calls.contains(.unlock))
        let created = try #require(calls.firstIndex(of: .createMasterKey))
        let wiped = try #require(calls.firstIndex(of: .wipeKey))
        #expect(created < wiped)
        #expect(!fixture.decoy.isKeyLoaded)
    }

    @Test("The decoy blob is made once, not per search")
    func blobMadeOnce() async throws {
        let fixture = try VaultLockFixture()
        await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "a") }
        await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "b") }
        await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "c") }
        #expect(fixture.decoy.calls.filter { $0 == .createMasterKey }.count == 1)
    }

    @Test("A search that comes before the decoy blob is ready waits for it")
    func searchWaitsForBlob() async throws {
        let blocking = BlockingDecoy()
        let fixture = try VaultLockFixture(decoy: blocking)
        _ = fixture.lock
        let search = Task { @MainActor in
            do {
                try await fixture.lock.open(password: "nope")
                return false
            } catch {
                return (error as? VaultLockError) == .wrongPassword
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!blocking.inner.calls.contains(.unlock))
        blocking.release()
        #expect(await search.value)
        let calls = blocking.inner.calls
        let created = try #require(calls.firstIndex(of: .createMasterKey))
        let unlocked = try #require(calls.firstIndex(of: .unlock))
        #expect(created < unlocked)
    }

    // MARK: Searches with no vault to try

    @Test("open with no vaults throws wrongPassword and runs the decoy derivation once with the typed password")
    func openNoVaults() async throws {
        let fixture = try VaultLockFixture()
        await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "typed") }
        #expect(Self.unlockCount(fixture.decoy) == 1)
    }

    @Test("The decoy is unlocked with exactly the typed password")
    func decoyReceivesTypedPassword() async throws {
        let decoy = BlockingDecoy(blocking: false)
        let fixture = try VaultLockFixture(decoy: decoy)
        await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "typed pw") }
        #expect(decoy.unlockedPasswords == ["typed pw"])
    }

    @Test("The decoy's own error is ignored: the result is still wrongPassword")
    func decoyErrorIgnored() async throws {
        let fixture = try VaultLockFixture()
        _ = fixture.lock
        await Self.waitForDecoyBlob(fixture.decoy)
        fixture.decoy.errorToThrow = .noMasterKeyBlob
        await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "typed") }
        #expect(Self.unlockCount(fixture.decoy) == 1)
    }

    @Test("openTransferTarget with no vault throws wrongPassword and runs the decoy derivation once")
    func transferTargetNoVaults() async throws {
        let fixture = try VaultLockFixture()
        await expectLockError(.wrongPassword) { _ = try await fixture.lock.openTransferTarget(password: "typed") }
        #expect(Self.unlockCount(fixture.decoy) == 1)
    }

    @Test("createVault's in-use check with no vault yet runs the decoy derivation once and the vault is created")
    func createVaultNoVaults() async throws {
        let fixture = try VaultLockFixture()
        try await fixture.lock.createVault(name: "Work", password: "work pw")
        #expect(Self.unlockCount(fixture.decoy) == 1)
        #expect(fixture.lock.current.name == "Work")
        #expect(fixture.lock.current.isEncrypted)
    }

    @Test("changePassword's in-use check with the open vault the only one runs the decoy once and the change succeeds")
    func changePasswordOnlyVault() async throws {
        let fixture = try VaultLockFixture(vaults: [Self.alpha])
        try await fixture.lock.open(password: "alpha pw")
        #expect(Self.unlockCount(fixture.decoy) == 0)
        try await fixture.lock.changePassword(current: "alpha pw", new: "new pw")
        #expect(Self.unlockCount(fixture.decoy) == 1)
        #expect(fixture.blob(of: "aaaa-1") == Data("new pw".utf8))
    }

    // MARK: Searches with a vault to try

    @Test("With vaults to try the decoy is never unlocked: open with a wrong and a right password")
    func openWithVaultsNoDecoy() async throws {
        let fixture = try VaultLockFixture(vaults: [Self.alpha])
        await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "nope") }
        try await fixture.lock.open(password: "alpha pw")
        #expect(Self.unlockCount(fixture.decoy) == 0)
    }

    @Test("With a vault to try the decoy is never unlocked: createVault and openTransferTarget")
    func createAndTransferWithVaultsNoDecoy() async throws {
        let fixture = try VaultLockFixture(pro: true, vaults: [Self.alpha])
        try await fixture.lock.createVault(name: "Two", password: "two pw")
        #expect(Self.unlockCount(fixture.decoy) == 0)
        let target = try await fixture.lock.openTransferTarget(password: "alpha pw")
        fixture.lock.closeTransferTarget(target)
        #expect(Self.unlockCount(fixture.decoy) == 0)
    }

    @Test("changePassword with another vault left to try does not run the decoy")
    func changePasswordOtherVaultNoDecoy() async throws {
        let fixture = try VaultLockFixture(vaults: [Self.alpha, Self.bravo])
        try await fixture.lock.open(password: "alpha pw")
        try await fixture.lock.changePassword(current: "alpha pw", new: "new pw")
        #expect(Self.unlockCount(fixture.decoy) == 0)
    }

    // MARK: Empty password and the decoy's invisibility

    @Test("An empty password throws emptyPassword and runs no derivation, in open and openTransferTarget")
    func emptyPasswordNoDerivation() async throws {
        let fixture = try VaultLockFixture()
        await expectLockError(.emptyPassword) { try await fixture.lock.open(password: "") }
        await expectLockError(.emptyPassword) { _ = try await fixture.lock.openTransferTarget(password: "") }
        #expect(Self.unlockCount(fixture.decoy) == 0)
    }

    @Test("The decoy never becomes current, is never listed, and its key is not left loaded after use")
    func decoyInvisibleAndWiped() async throws {
        let fixture = try VaultLockFixture()
        _ = fixture.lock
        await Self.waitForDecoyBlob(fixture.decoy)
        await expectLockError(.wrongPassword) { try await fixture.lock.open(password: "typed") }
        #expect(fixture.lock.current.id == "unencrypted")
        #expect(fixture.vaultFolderNames.isEmpty)
        #expect(!fixture.decoy.isKeyLoaded)
        #expect(fixture.decoy.calls.last == .wipeKey)
    }
}
