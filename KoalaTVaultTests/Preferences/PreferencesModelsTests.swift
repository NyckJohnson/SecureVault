import Foundation
import Testing

@testable import KoalaTVault

@Suite struct PreferencesModelsTests {
    static let displayNames: [(option: SortOption, label: String)] = {
        var rows: [(option: SortOption, label: String)] = []
        rows.append((.name, "Name"))
        rows.append((.type, "Type"))
        rows.append((.dateModified, "Date Modified"))
        return rows
    }()

    @Test("SortOption display names are the user-facing labels", arguments: displayNames)
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
        let base = PendingMigration(kind: .encrypt, targetLockMode: .password)
        #expect(base == PendingMigration(kind: .encrypt, targetLockMode: .password))
        #expect(base != PendingMigration(kind: .encrypt, targetLockMode: LockMode.none))
        #expect(base != PendingMigration(kind: .encrypt, targetLockMode: nil))
        #expect(base != PendingMigration(kind: .decrypt, targetLockMode: .password))
        #expect(Set([base, PendingMigration(kind: .encrypt, targetLockMode: .password)]).count == 1)
    }

    @Test("PendingMigration survives a Codable round trip")
    func pendingMigrationCodable() throws {
        var migrations: [PendingMigration] = []
        migrations.append(PendingMigration(kind: .encrypt, targetLockMode: .passwordAndBiometrics))
        migrations.append(PendingMigration(kind: .encrypt, targetLockMode: LockMode.none))
        migrations.append(PendingMigration(kind: .decrypt, targetLockMode: nil))
        for migration in migrations {
            let data = try JSONEncoder().encode(migration)
            #expect(try JSONDecoder().decode(PendingMigration.self, from: data) == migration)
        }
    }
}
