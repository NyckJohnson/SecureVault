import Foundation
import Testing

@testable import KoalaTVault

@Suite struct HousekeepingBatchTests {
    /// The files in a folder of `count` encrypted-form files named `f000`, `f001`, ...
    private func sealedFiles(_ count: Int, in folder: VaultDirectory, vault: VaultStoreFixture) throws {
        for index in 0..<count {
            try vault.diskSealedFile("f" + String(format: "%03d", index), "x", in: folder)
        }
    }

    /// A vault whose only folder "Big" holds an indexed file and `count` encrypted-form files, so the first file
    /// form check of the whole walk happens inside Big.
    private func bigFolderVault(count: Int) async throws -> (VaultStoreFixture, VaultDirectory) {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        let big = try vault.folder("Big")
        try await vault.add("a.txt", to: big)
        try sealedFiles(count, in: big, vault: vault)
        return (vault, big)
    }

    @Test("hasUnencryptedFiles checks every folder of one depth before any folder one level deeper")
    func hasUnencryptedVisitsFoldersBreadthFirst() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let folderA = try vault.folder("A")
        let folderB = try vault.folder("B")
        let folderA1 = try vault.folder("A1", in: folderA)
        let folderB1 = try vault.folder("B1", in: folderB)
        try vault.diskSealedFile("mark-R")
        try vault.diskSealedFile("mark-A", in: folderA)
        try vault.diskSealedFile("mark-B", in: folderB)
        try vault.diskSealedFile("mark-A1", in: folderA1)
        try vault.diskSealedFile("mark-B1", in: folderB1)

        #expect(try await vault.store.hasUnencryptedFiles() == false)

        let order = failing.streamInfoURLs.map(\.lastPathComponent)
        let position = { (mark: String) in order.firstIndex(of: "mark-" + mark) ?? Int.max }
        #expect(order.count == 5)
        #expect(position("R") < position("A") && position("R") < position("B"))
        #expect(position("A") < position("A1") && position("B") < position("A1"))
        #expect(position("A") < position("B1") && position("B") < position("B1"))
    }

    @Test("A listing asked for while hasUnencryptedFiles is in a large folder's first batch finishes before the check")
    func listingRunsBetweenBatchesOfOneFolder() async throws {
        let (vault, big) = try await bigFolderVault(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let gate = HousekeepingGate()
        failing.onFirstStreamInfo = { _ in gate.pass() }
        let store = vault.store
        let log = EventLog()
        let aboutToList = Signal()

        let check = Task {
            let answer = try await store.hasUnencryptedFiles()
            log.add("check")
            return answer
        }
        #expect(await gate.waitUntilEntered())
        let listing = Task {
            aboutToList.raise()
            let items = try await store.contents(of: big, sortedBy: .name, .ascending)
            log.add("listing")
            return items.map(\.name)
        }
        #expect(await aboutToList.waitUntilRaised())
        gate.release()
        let listed = try await listing.value
        let answer = try await check.value

        #expect(log.events == ["listing", "check"])
        #expect(listed.contains("a.txt"))
        #expect(listed.count == 601)
        #expect(answer == false)
    }

    @Test("hasUnencryptedFiles checks every file of a folder larger than one batch and answers false")
    func hasUnencryptedChecksAllBatches() async throws {
        let (vault, _) = try await bigFolderVault(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)

        #expect(try await vault.store.hasUnencryptedFiles() == false)

        // The 600 loose files and the indexed one are each checked.
        #expect(failing.streamInfoURLs.count >= 601)
    }

    @Test("hasUnencryptedFiles finds a plaintext file that is in a later batch of a large folder")
    func hasUnencryptedFindsPlaintextInLaterBatch() async throws {
        let (vault, big) = try await bigFolderVault(count: 600)
        defer { vault.cleanUp() }
        // Replace the ~500th file (by name) with a plaintext one.
        try vault.diskFile("f499", "plain", in: big)

        #expect(try await vault.store.hasUnencryptedFiles())
    }

    @Test("hasUnencryptedFiles skips a file removed before its batch and still answers as before")
    func hasUnencryptedSkipsFilesRemovedBetweenBatches() async throws {
        let (vault, big) = try await bigFolderVault(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let folderURL = big.diskURL
        // At the first file check (first batch) the later files are removed; the one being checked stays.
        failing.onFirstStreamInfo = { url in
            for index in 300..<600 {
                let name = "f" + String(format: "%03d", index)
                guard name != url.lastPathComponent else { continue }
                try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(name))
            }
        }

        #expect(try await vault.store.hasUnencryptedFiles() == false)
        #expect(!FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("f450").path))
    }

    @Test("hasUnencryptedFiles throws CancellationError when cancelled between a large folder's batches")
    func hasUnencryptedThrowsWhenCancelledBetweenBatches() async throws {
        let (vault, _) = try await bigFolderVault(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let gate = HousekeepingGate()
        failing.onFirstStreamInfo = { _ in gate.pass() }
        let store = vault.store

        let check = Task { try await store.hasUnencryptedFiles() }
        #expect(await gate.waitUntilEntered())
        check.cancel()
        gate.release()
        let error = await caught { _ = try await check.value }

        #expect(error is CancellationError)
    }

    @Test("hasUnencryptedFiles throws locked when the vault locks between a large folder's batches")
    func hasUnencryptedThrowsLockedBetweenBatches() async throws {
        let (vault, _) = try await bigFolderVault(count: 600)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        let keys = vault.keys
        let gate = HousekeepingGate(waits: false) { keys.wipeKey() }
        failing.onFirstStreamInfo = { _ in gate.pass() }

        let error = await caught { _ = try await vault.store.hasUnencryptedFiles() }

        #expect(error as? VaultStoreError == .locked)
    }

    @Test("hasUnencryptedFiles throws io when the vault's root folder is missing")
    func hasUnencryptedThrowsIOWhenRootMissing() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        try FileManager.default.removeItem(at: vault.rootURL)

        let error = await caught { _ = try await vault.store.hasUnencryptedFiles() }
        guard case .io? = error as? VaultStoreError else {
            Issue.record("expected VaultStoreError.io, got \(String(describing: error))")
            return
        }
    }
}
