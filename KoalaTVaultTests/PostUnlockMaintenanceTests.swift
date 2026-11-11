import Foundation
import Testing

@testable import KoalaTVault

@Suite struct PostUnlockMaintenanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func maintenanceCalls(_ vault: MockVaultStoring) -> [MockVaultStoring.Call] {
        vault.calls.filter { $0 == .purgeExpiredTrash || $0 == .sweepOrphans }
    }

    @Test("Purge runs first and then the orphan sweep")
    func purgesThenSweeps() async {
        let vault = MockVaultStoring()
        await PostUnlockMaintenance.run(vaultStore: vault, now: now)
        #expect(maintenanceCalls(vault) == [.purgeExpiredTrash, .sweepOrphans])
    }

    @Test("Purge uses the given time: an item trashed before now minus 30 days is purged, a newer one stays")
    func purgeUsesGivenNow() async throws {
        let vault = MockVaultStoring()
        let before = try await vault.trashContents().count
        #expect(before == 1)
        // The sample trash item was deleted about 3 days ago; 40 days later it has expired.
        let later = Date().addingTimeInterval(40 * 24 * 60 * 60)
        await PostUnlockMaintenance.run(vaultStore: vault, now: later)
        #expect(try await vault.trashContents().isEmpty)

        let fresh = MockVaultStoring()
        await PostUnlockMaintenance.run(vaultStore: fresh, now: Date())
        #expect(try await fresh.trashContents().count == 1)
    }

    @Test("A purge that throws is ignored and the sweep still runs")
    func purgeFailureIsIgnored() async {
        let vault = MockVaultStoring()
        vault.errorToThrow = .indexUnreadable(folder: "")
        await PostUnlockMaintenance.run(vaultStore: vault, now: now)
        #expect(maintenanceCalls(vault) == [.purgeExpiredTrash, .sweepOrphans])
    }

    @Test("The sweep runs after the purge exactly once, with no other maintenance calls")
    func runsEachStepOnce() async {
        let vault = MockVaultStoring()
        await PostUnlockMaintenance.run(vaultStore: vault, now: now)
        #expect(vault.calls.filter { $0 == .purgeExpiredTrash }.count == 1)
        #expect(vault.calls.filter { $0 == .sweepOrphans }.count == 1)
    }
}
