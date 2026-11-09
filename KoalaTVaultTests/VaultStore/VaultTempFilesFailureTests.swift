import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultTempFilesFailureTests {
    @Test("makeTempDirectory with an unwritable temporary root throws io")
    func makeTempDirectoryUnwritableRootThrowsIO() throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let restore = try restrict(vault.tempRoot)
        defer { restore() }

        let error = VaultTempFilesFailureTests.thrown { _ = try vault.store.makeTempDirectory() }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(vault.tempContents().isEmpty)

    }

    @Test("open of an encrypted item with an unwritable temporary root throws io and leaves no temp file")
    func openWithUnwritableTempRootThrowsIO() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("Report.pdf", "pdf bytes")
        let restore = try restrict(vault.tempRoot)
        defer { restore() }

        let error = await caught { _ = try await vault.store.open(item) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(vault.tempContents().isEmpty)

        #expect(try await vault.openedContent(item) == "pdf bytes")
    }

    private static func thrown(_ body: () throws -> Void) -> (any Error)? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }
}
