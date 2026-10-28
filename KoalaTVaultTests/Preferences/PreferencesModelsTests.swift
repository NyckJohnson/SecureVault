import Foundation
import Testing

@testable import KoalaTVault

@Suite struct PreferencesModelsTests {
    @Test("SortOption display names are the user-facing labels",
          arguments: [(SortOption.name, "Name"), (.type, "Type"), (.dateModified, "Date Modified")])
    func displayName(option: SortOption, label: String) {
        #expect(option.displayName == label)
    }

    @Test("SortOption lists every case once")
    func sortOptionCases() {
        #expect(SortOption.allCases == [.name, .type, .dateModified])
    }

    @Test("Enum raw values match the stored strings")
    func rawValues() {
        #expect(LockMode.allCases.map(\.rawValue) == ["none", "password", "passwordAndBiometrics"])
        #expect(SortOption.allCases.map(\.rawValue) == ["name", "type", "dateModified"])
        #expect(SortDirection.allCases.map(\.rawValue) == ["ascending", "descending"])
        #expect(MigrationKind.encrypt.rawValue == "encrypt")
        #expect(MigrationKind.decrypt.rawValue == "decrypt")
    }

    @Test("PendingMigration equality and hashing consider kind and target")
    func pendingMigrationEquality() {
        let a = PendingMigration(kind: .encrypt, targetLockMode: .password)
        #expect(a == PendingMigration(kind: .encrypt, targetLockMode: .password))
        #expect(a != PendingMigration(kind: .encrypt, targetLockMode: .none))
        #expect(a != PendingMigration(kind: .decrypt, targetLockMode: .password))
        #expect(Set([a, PendingMigration(kind: .encrypt, targetLockMode: .password)]).count == 1)
    }

    @Test("PendingMigration survives a Codable round trip")
    func pendingMigrationCodable() throws {
        for migration in [
            PendingMigration(kind: .encrypt, targetLockMode: .passwordAndBiometrics),
            PendingMigration(kind: .decrypt, targetLockMode: nil),
        ] {
            let data = try JSONEncoder().encode(migration)
            #expect(try JSONDecoder().decode(PendingMigration.self, from: data) == migration)
        }
    }
}
