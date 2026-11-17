import Foundation
import Testing
import os

@testable import KoalaTVault

/// Batch `moveToTrash` when a source folder's index can't be read: that folder's items each get the error and stay
/// where they are, items of other folders still move, and the failing index is read once for the whole batch.
@Suite struct VaultTrashUnreadableSourceTests {
    private struct Setup {
        let vault: VaultStoreFixture
        let broken: VaultDirectory
        let brokenItems: [VaultItem]
        let rootItem: VaultItem
        let garbage: Data
    }

    private func makeSetup() async throws -> Setup {
        let vault = try VaultStoreFixture(lockMode: .password, selective: true)
        let broken = try vault.folder("Broken")
        let one = try await vault.add("one.txt", "1", to: broken)
        let two = try await vault.add("two.txt", "2", to: broken)
        let three = try await vault.add("three.txt", "3", to: broken)
        let rootItem = try await vault.add("fine.txt", "fine")
        let garbage = Data("not an index at all".utf8)
        try vault.writeRawIndex(garbage, in: broken)
        return Setup(
            vault: vault, broken: broken, brokenItems: [one, two, three], rootItem: rootItem, garbage: garbage)
    }

    @Test("Items of a source folder whose index is unreadable each get that error and stay put")
    func unreadableSourceIndexFailsItsItems() async throws {
        let setup = try await makeSetup()
        defer { setup.vault.cleanUp() }
        let brokenIndexBefore = setup.vault.rawIndex(in: setup.broken)

        let batch = [setup.brokenItems[0], setup.rootItem, setup.brokenItems[1]]
        let failures = await setup.vault.store.moveToTrash(batch)

        #expect(Set(failures.keys) == [setup.brokenItems[0].id, setup.brokenItems[1].id])
        for id in failures.keys { #expect(isIndexUnreadable(failures[id])) }
        for item in setup.brokenItems { #expect(FileManager.default.fileExists(atPath: item.diskURL.path)) }
        #expect(setup.vault.rawIndex(in: setup.broken) == brokenIndexBefore)
        #expect(try await setup.vault.store.trashContents().map(\.name) == ["fine.txt"])
        #expect(!FileManager.default.fileExists(atPath: setup.rootItem.diskURL.path))
    }

    @Test("The unreadable index of a source folder is read once however many of its items are trashed")
    func unreadableSourceIndexReadOnce() async throws {
        let setup = try await makeSetup()
        defer { setup.vault.cleanUp() }
        let failing = try #require(setup.vault.failing)
        let garbage = setup.garbage
        let reads = OSAllocatedUnfairLock(initialState: 0)
        failing.decryptErrorFor = { data in
            if data == garbage { reads.withLock { $0 += 1 } }
            return nil
        }

        let failures = await setup.vault.store.moveToTrash(setup.brokenItems)

        #expect(Set(failures.keys) == Set(setup.brokenItems.map(\.id)))
        for item in setup.brokenItems { #expect(isIndexUnreadable(failures[item.id])) }
        #expect(reads.withLock { $0 } == 1)
    }
}
