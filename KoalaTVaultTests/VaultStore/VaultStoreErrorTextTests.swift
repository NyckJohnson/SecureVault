import Foundation
import Testing

@testable import KoalaTVault

/// The user-facing text of `VaultStoreError` (`LocalizedError`); alerts show `localizedDescription`.
@Suite struct VaultStoreErrorTextTests {
    private func expectText(_ error: VaultStoreError, _ expected: String) {
        #expect(error.errorDescription == expected)
        #expect(error.localizedDescription == expected)
    }

    @Test("indexUnreadable explains the index may be locked or corrupted")
    func indexUnreadableText() {
        expectText(
            .indexUnreadable(folder: "Docs"),
            "Couldn't read the vault's file index. It may still be locked, or a file may have become corrupted."
        )
    }

    @Test("indexUnreadable text does not depend on the folder")
    func indexUnreadableTextIgnoresFolder() {
        #expect(
            VaultStoreError.indexUnreadable(folder: "A").errorDescription
                == VaultStoreError.indexUnreadable(folder: "B").errorDescription
        )
    }

    @Test("locked uses the text of VaultCryptoError.noKeyLoaded")
    func lockedText() {
        expectText(.locked, VaultCryptoError.noKeyLoaded.localizedDescription)
        expectText(.locked, "No encryption key is loaded.")
    }

    @Test("invalidName says names can't contain / or start with .")
    func invalidNameText() {
        expectText(.invalidName, "Names can't contain / or start with .")
    }

    @Test("notFound says the item no longer exists")
    func notFoundText() {
        expectText(.notFound, "This item no longer exists.")
    }

    @Test("moveIntoItself says a folder can't be moved into itself")
    func moveIntoItselfText() {
        expectText(.moveIntoItself, "A folder can't be moved into itself")
    }

    @Test("io returns its message itself")
    func ioText() {
        expectText(.io("Disk full"), "Disk full")
    }

    @Test("io with an empty message returns the empty string")
    func ioEmptyText() {
        #expect(VaultStoreError.io("").errorDescription?.isEmpty == true)
    }
}
