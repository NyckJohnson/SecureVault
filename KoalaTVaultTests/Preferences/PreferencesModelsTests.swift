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
        // feature multiple-vaults-duress-password: signature updated
        #expect(LockMode.allCases.map(\.rawValue) == ["none", "password", "passwordAndBiometrics"])
        #expect(SortOption.allCases.map(\.rawValue) == ["name", "type", "dateModified"])
        #expect(SortDirection.allCases.map(\.rawValue) == ["ascending", "descending"])
    }
}
