import Foundation
import Testing
import os

@testable import KoalaTVault

/// A throwaway UserDefaults suite, removed by `cleanup()`.
private struct TestSuite {
    let name = "PreferencesTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        guard let suite = UserDefaults(suiteName: name) else {
            preconditionFailure("cannot create suite")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: name)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: name)
    }

    func makeStore() -> UserDefaultsPreferences {
        UserDefaultsPreferences(defaults: defaults)
    }
}

@Suite struct UserDefaultsPreferencesTests {
    // MARK: Defaults

    @Test("An empty store reads the documented defaults")
    func defaultsOnEmptyStore() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        #expect(store.lockMode == .none)
        #expect(store.sortOption == .name)
        #expect(store.sortDirection == .ascending)
        #expect(store.hasPendingEncryptMigration == false)
        #expect(store.vaultsUpgraded == false)
    }

    // MARK: Round trips and raw values

    static let lockModeRows: [(mode: LockMode, raw: String)] = {
        var rows: [(mode: LockMode, raw: String)] = []
        rows.append((LockMode.none, "none"))
        rows.append((.password, "password"))
        rows.append((.passwordAndBiometrics, "passwordAndBiometrics"))
        return rows
    }()

    @Test("lockMode round-trips and stores its raw string", arguments: lockModeRows)
    func lockModeRoundTrip(mode: LockMode, raw: String) {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.lockMode = mode
        #expect(store.lockMode == mode)
        #expect(suite.defaults.string(forKey: "lockMode") == raw)
    }

    static let sortOptionRows: [(option: SortOption, raw: String)] = {
        var rows: [(option: SortOption, raw: String)] = []
        rows.append((.name, "name"))
        rows.append((.type, "type"))
        rows.append((.dateModified, "dateModified"))
        return rows
    }()

    @Test("sortOption round-trips and stores its raw string", arguments: sortOptionRows)
    func sortOptionRoundTrip(option: SortOption, raw: String) {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.sortOption = option
        #expect(store.sortOption == option)
        #expect(suite.defaults.string(forKey: "sortOption") == raw)
    }

    static let sortDirectionRows: [(direction: SortDirection, raw: String)] = {
        var rows: [(direction: SortDirection, raw: String)] = []
        rows.append((.ascending, "ascending"))
        rows.append((.descending, "descending"))
        return rows
    }()

    @Test("sortDirection round-trips and stores its raw string", arguments: sortDirectionRows)
    func sortDirectionRoundTrip(direction: SortDirection, raw: String) {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.sortDirection = direction
        #expect(store.sortDirection == direction)
        #expect(suite.defaults.string(forKey: "sortDirection") == raw)
    }

    // MARK: Persistence

    @Test("Values written by one store are read by a new store on the same suite")
    func persistenceAcrossStores() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let first = suite.makeStore()
        first.lockMode = .passwordAndBiometrics
        first.sortOption = .dateModified
        first.sortDirection = .descending

        let second = suite.makeStore()
        #expect(second.lockMode == .passwordAndBiometrics)
        #expect(second.sortOption == .dateModified)
        #expect(second.sortDirection == .descending)
    }

    @Test("Stores on different suites do not share values")
    func suitesAreIsolated() {
        let first = TestSuite()
        let second = TestSuite()
        defer {
            first.cleanup()
            second.cleanup()
        }
        first.makeStore().lockMode = .password
        #expect(second.makeStore().lockMode == .none)
    }

    // MARK: Unknown raw values

    @Test("An unknown lockMode raw value reads as none")
    func unknownLockMode() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set("bogus", forKey: "lockMode")
        #expect(suite.makeStore().lockMode == .none)
    }

    @Test("An unknown sortOption raw value reads as name")
    func unknownSortOption() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set("bogus", forKey: "sortOption")
        #expect(suite.makeStore().sortOption == .name)
    }

    @Test("An unknown sortDirection raw value reads as ascending")
    func unknownSortDirection() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set("bogus", forKey: "sortDirection")
        #expect(suite.makeStore().sortDirection == .ascending)
    }

    // MARK: Legacy-written values

    @Test("Raw values written directly under the documented keys are read back")
    func readsDocumentedKeys() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set("passwordAndBiometrics", forKey: "lockMode")
        suite.defaults.set("type", forKey: "sortOption")
        suite.defaults.set("descending", forKey: "sortDirection")
        suite.defaults.set("encrypt", forKey: "pendingMigrationType")
        suite.defaults.set("password", forKey: "pendingMigrationTargetLockMode")
        let store = suite.makeStore()
        #expect(store.lockMode == .passwordAndBiometrics)
        #expect(store.sortOption == .type)
        #expect(store.sortDirection == .descending)
        #expect(store.hasPendingEncryptMigration == true)
    }

    // MARK: vaultsUpgraded (feature multiple-vaults-duress-password)

    @Test("vaultsUpgraded defaults to false on an empty store")
    func vaultsUpgradedDefaultsToFalse() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        #expect(suite.makeStore().vaultsUpgraded == false)
    }

    @Test("vaultsUpgraded round-trips under its key")
    func vaultsUpgradedRoundTrip() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.vaultsUpgraded = true
        #expect(store.vaultsUpgraded == true)
        #expect(suite.defaults.bool(forKey: "vaultsUpgraded") == true)
        store.vaultsUpgraded = false
        #expect(store.vaultsUpgraded == false)
        #expect(suite.defaults.bool(forKey: "vaultsUpgraded") == false)
    }

    @Test("vaultsUpgraded written directly under its key is read back")
    func vaultsUpgradedReadsDocumentedKey() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set(true, forKey: "vaultsUpgraded")
        #expect(suite.makeStore().vaultsUpgraded == true)
    }

    @Test("vaultsUpgraded set by one store is read by a new store on the same suite")
    func vaultsUpgradedPersistsAcrossStores() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.makeStore().vaultsUpgraded = true
        #expect(suite.makeStore().vaultsUpgraded == true)
    }

    @Test("vaultsUpgraded does not change other settings")
    func vaultsUpgradedLeavesOtherSettingsAlone() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.vaultsUpgraded = true
        #expect(store.lockMode == .none)
    }

    // MARK: hasPendingEncryptMigration and clearPendingMigration (minors clean-up)

    static let pendingTypeRows: [(raw: String?, expected: Bool)] = {
        var rows: [(raw: String?, expected: Bool)] = []
        rows.append(("encrypt", true))
        rows.append(("decrypt", false))
        rows.append(("bogus", false))
        rows.append(("", false))
        rows.append((nil, false))
        return rows
    }()

    @Test("hasPendingEncryptMigration is true only for an encrypt pendingMigrationType", arguments: pendingTypeRows)
    func pendingEncryptFlag(raw: String?, expected: Bool) {
        let suite = TestSuite()
        defer { suite.cleanup() }
        if let raw { suite.defaults.set(raw, forKey: "pendingMigrationType") }
        #expect(suite.makeStore().hasPendingEncryptMigration == expected)
    }

    @Test("A stored pendingMigrationTargetLockMode alone does not make the flag true")
    func targetLockModeAloneIsNotPending() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set("password", forKey: "pendingMigrationTargetLockMode")
        #expect(suite.makeStore().hasPendingEncryptMigration == false)
    }

    @Test("The pending flag is unaffected by the target lock mode when the type is decrypt")
    func decryptWithTargetIsNotPending() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set("decrypt", forKey: "pendingMigrationType")
        suite.defaults.set("password", forKey: "pendingMigrationTargetLockMode")
        #expect(suite.makeStore().hasPendingEncryptMigration == false)
    }

    @Test("hasPendingEncryptMigration written under the documented key is read by a new store")
    func pendingEncryptReadByNewStore() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        _ = suite.makeStore()
        suite.defaults.set("encrypt", forKey: "pendingMigrationType")
        #expect(suite.makeStore().hasPendingEncryptMigration == true)
    }

    @Test("clearPendingMigration removes both pending-migration keys and the flag turns false")
    func clearRemovesBothKeys() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set("encrypt", forKey: "pendingMigrationType")
        suite.defaults.set("password", forKey: "pendingMigrationTargetLockMode")
        let store = suite.makeStore()
        #expect(store.hasPendingEncryptMigration == true)
        store.clearPendingMigration()
        #expect(store.hasPendingEncryptMigration == false)
        #expect(suite.defaults.object(forKey: "pendingMigrationType") == nil)
        #expect(suite.defaults.object(forKey: "pendingMigrationTargetLockMode") == nil)
        #expect(suite.makeStore().hasPendingEncryptMigration == false)
    }

    @Test("clearPendingMigration leaves every other key untouched")
    func clearLeavesOtherKeysAlone() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.lockMode = .passwordAndBiometrics
        store.sortOption = .dateModified
        store.sortDirection = .descending
        store.vaultsUpgraded = true
        suite.defaults.set(true, forKey: "hasCompletedSetup")
        suite.defaults.set("encrypt", forKey: "pendingMigrationType")
        suite.defaults.set("password", forKey: "pendingMigrationTargetLockMode")

        store.clearPendingMigration()

        #expect(store.lockMode == .passwordAndBiometrics)
        #expect(store.sortOption == .dateModified)
        #expect(store.sortDirection == .descending)
        #expect(store.vaultsUpgraded == true)
        #expect(suite.defaults.object(forKey: "hasCompletedSetup") != nil)
        #expect(suite.defaults.bool(forKey: "hasCompletedSetup") == true)
    }

    @Test("clearPendingMigration on an empty store is harmless")
    func clearOnEmptyStore() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.clearPendingMigration()
        store.clearPendingMigration()
        #expect(store.hasPendingEncryptMigration == false)
        #expect(store.lockMode == .none)
        #expect(store.sortOption == .name)
        #expect(store.sortDirection == .ascending)
        #expect(store.vaultsUpgraded == false)
    }

    // MARK: Thread safety

    @Test("Concurrent reads and writes from several threads neither crash nor tear")
    func concurrentAccess() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            store.lockMode = LockMode.allCases[i % LockMode.allCases.count]
            store.sortOption = SortOption.allCases[i % SortOption.allCases.count]
            store.sortDirection = SortDirection.allCases[i % SortDirection.allCases.count]
            store.vaultsUpgraded = i.isMultiple(of: 3)
            if i.isMultiple(of: 5) { store.clearPendingMigration() }

            _ = store.lockMode
            _ = store.sortOption
            _ = store.sortDirection
            _ = store.vaultsUpgraded
            _ = store.hasPendingEncryptMigration
        }
        // The store still works after the storm.
        store.lockMode = .password
        #expect(store.lockMode == .password)
        store.clearPendingMigration()
        #expect(store.hasPendingEncryptMigration == false)
    }
}
