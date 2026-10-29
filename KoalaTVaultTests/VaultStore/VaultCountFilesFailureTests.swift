import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultCountFilesFailureTests {
    @Test(
        "countFiles with a subfolder that can't be read throws io, never a partial count",
        arguments: [LockMode.none, .password])
    func countFilesUnreadableSubfolderThrowsIO(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        try await vault.add("a.txt")
        let readable = try vault.folder("Readable")
        try await vault.add("b.txt", to: readable)
        let locked = try vault.folder("Locked")
        try vault.diskFile("c.txt", in: locked)
        #expect(try await vault.store.countFiles() == 3)
        let restore = try restrict(locked.diskURL, to: 0o000)
        defer { restore() }

        let error = await caught { _ = try await vault.store.countFiles() }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try await vault.store.countFiles() == 3)
    }
}
