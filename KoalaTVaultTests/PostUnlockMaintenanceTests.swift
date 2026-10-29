import Foundation
import Testing

@testable import KoalaTVault

@Suite struct PostUnlockMaintenanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func maintenanceCalls(_ vault: MockVaultStoring) -> [MockVaultStoring.Call] {
        vault.calls.filter { $0 == .purgeExpiredTrash || $0 == .sweepOrphans }
    }

    @Test("With no migration pending, purge runs and then the orphan sweep")
    func purgesThenSweepsWhenNothingPending() async {
        let vault = MockVaultStoring()
        let prefs = MockPreferencesStoring(pendingMigration: nil)
        await PostUnlockMaintenance.run(vaultStore: vault, preferences: prefs, now: now)
        #expect(maintenanceCalls(vault) == [.purgeExpiredTrash, .sweepOrphans])
    }

    @Test("Purge uses the given time: an item trashed before now minus 30 days is purged, a newer one stays")
    func purgeUsesGivenNow() async throws {
        let vault = MockVaultStoring()
        let prefs = MockPreferencesStoring()
        let before = try await vault.trashContents().count
        #expect(before == 1)
        // The sample trash item was deleted about 3 days ago; 40 days later it has expired.
        let later = Date().addingTimeInterval(40 * 24 * 60 * 60)
        await PostUnlockMaintenance.run(vaultStore: vault, preferences: prefs, now: later)
        #expect(try await vault.trashContents().isEmpty)

        let fresh = MockVaultStoring()
        await PostUnlockMaintenance.run(vaultStore: fresh, preferences: prefs, now: Date())
        #expect(try await fresh.trashContents().count == 1)
    }

    @Test(
        "With a migration pending, purge runs but the orphan sweep never does",
        arguments: [MigrationKind.encrypt, .decrypt])
    func skipsSweepWhenMigrationPending(kind: MigrationKind) async {
        let vault = MockVaultStoring()
        let prefs = MockPreferencesStoring(pendingMigration: PendingMigration(kind: kind, targetLockMode: .password))
        await PostUnlockMaintenance.run(vaultStore: vault, preferences: prefs, now: now)
        #expect(maintenanceCalls(vault) == [.purgeExpiredTrash])
        #expect(!vault.calls.contains(.sweepOrphans))
    }

    @Test("A purge that throws is ignored and the sweep still runs when nothing is pending")
    func purgeFailureIsIgnored() async {
        let vault = MockVaultStoring()
        vault.errorToThrow = .indexUnreadable(folder: "")
        let prefs = MockPreferencesStoring()
        await PostUnlockMaintenance.run(vaultStore: vault, preferences: prefs, now: now)
        #expect(maintenanceCalls(vault) == [.purgeExpiredTrash, .sweepOrphans])
    }

    @Test("A purge that throws with a migration pending still skips the sweep")
    func purgeFailureWithPendingMigration() async {
        let vault = MockVaultStoring()
        vault.errorToThrow = .indexUnreadable(folder: "")
        let prefs = MockPreferencesStoring(pendingMigration: PendingMigration(kind: .encrypt, targetLockMode: nil))
        await PostUnlockMaintenance.run(vaultStore: vault, preferences: prefs, now: now)
        #expect(maintenanceCalls(vault) == [.purgeExpiredTrash])
    }
}
