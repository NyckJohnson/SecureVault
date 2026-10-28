import Foundation
import Testing

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
        #expect(store.hasCompletedSetup == false)
        #expect(store.lockMode == .none)
        #expect(store.sortOption == .name)
        #expect(store.sortDirection == .ascending)
        #expect(store.pendingMigration == nil)
    }

    // MARK: Round trips and raw values

    @Test("hasCompletedSetup round-trips under its key")
    func hasCompletedSetupRoundTrip() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.hasCompletedSetup = true
        #expect(store.hasCompletedSetup == true)
        #expect(suite.defaults.bool(forKey: "hasCompletedSetup") == true)
        store.hasCompletedSetup = false
        #expect(store.hasCompletedSetup == false)
        #expect(suite.defaults.bool(forKey: "hasCompletedSetup") == false)
    }

    @Test("lockMode round-trips and stores its raw string",
          arguments: [(LockMode.none, "none"), (.password, "password"), (.passwordAndBiometrics, "passwordAndBiometrics")])
    func lockModeRoundTrip(mode: LockMode, raw: String) {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.lockMode = mode
        #expect(store.lockMode == mode)
        #expect(suite.defaults.string(forKey: "lockMode") == raw)
    }

    @Test("sortOption round-trips and stores its raw string",
          arguments: [(SortOption.name, "name"), (.type, "type"), (.dateModified, "dateModified")])
    func sortOptionRoundTrip(option: SortOption, raw: String) {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.sortOption = option
        #expect(store.sortOption == option)
        #expect(suite.defaults.string(forKey: "sortOption") == raw)
    }

    @Test("sortDirection round-trips and stores its raw string",
          arguments: [(SortDirection.ascending, "ascending"), (.descending, "descending")])
    func sortDirectionRoundTrip(direction: SortDirection, raw: String) {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.sortDirection = direction
        #expect(store.sortDirection == direction)
        #expect(suite.defaults.string(forKey: "sortDirection") == raw)
    }

    @Test("An encrypt migration with a target stores both keys",
          arguments: [LockMode.none, .password, .passwordAndBiometrics])
    func encryptMigrationWithTarget(target: LockMode) {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        let migration = PendingMigration(kind: .encrypt, targetLockMode: target)
        store.pendingMigration = migration
        #expect(store.pendingMigration == migration)
        #expect(suite.defaults.string(forKey: "pendingMigrationType") == "encrypt")
        #expect(suite.defaults.string(forKey: "pendingMigrationTargetLockMode") == target.rawValue)
    }

    @Test("An encrypt migration without a target stores no target key")
    func encryptMigrationWithoutTarget() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.pendingMigration = PendingMigration(kind: .encrypt, targetLockMode: .password)
        store.pendingMigration = PendingMigration(kind: .encrypt, targetLockMode: nil)
        #expect(store.pendingMigration == PendingMigration(kind: .encrypt, targetLockMode: nil))
        #expect(suite.defaults.string(forKey: "pendingMigrationType") == "encrypt")
        #expect(suite.defaults.object(forKey: "pendingMigrationTargetLockMode") == nil)
    }

    @Test("A decrypt migration stores only its type")
    func decryptMigration() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.pendingMigration = PendingMigration(kind: .decrypt, targetLockMode: nil)
        #expect(store.pendingMigration == PendingMigration(kind: .decrypt, targetLockMode: nil))
        #expect(suite.defaults.string(forKey: "pendingMigrationType") == "decrypt")
        #expect(suite.defaults.object(forKey: "pendingMigrationTargetLockMode") == nil)
    }

    @Test("A target given with a decrypt migration is ignored and not stored")
    func decryptMigrationIgnoresTarget() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.pendingMigration = PendingMigration(kind: .decrypt, targetLockMode: .password)
        #expect(store.pendingMigration?.kind == .decrypt)
        #expect(store.pendingMigration?.targetLockMode == nil)
        #expect(suite.defaults.object(forKey: "pendingMigrationTargetLockMode") == nil)
    }

    @Test("Replacing an encrypt migration having a target with a decrypt one removes the old target")
    func decryptReplacesEncryptTarget() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.pendingMigration = PendingMigration(kind: .encrypt, targetLockMode: .passwordAndBiometrics)
        store.pendingMigration = PendingMigration(kind: .decrypt, targetLockMode: nil)
        #expect(store.pendingMigration == PendingMigration(kind: .decrypt, targetLockMode: nil))
        #expect(suite.defaults.object(forKey: "pendingMigrationTargetLockMode") == nil)
    }

    @Test("Setting pendingMigration to nil removes both keys")
    func nilPendingMigrationRemovesKeys() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.pendingMigration = PendingMigration(kind: .encrypt, targetLockMode: .password)
        store.pendingMigration = nil
        #expect(store.pendingMigration == nil)
        #expect(suite.defaults.object(forKey: "pendingMigrationType") == nil)
        #expect(suite.defaults.object(forKey: "pendingMigrationTargetLockMode") == nil)
    }

    @Test("Setting pendingMigration to nil on an empty store is harmless")
    func nilPendingMigrationOnEmptyStore() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        store.pendingMigration = nil
        #expect(store.pendingMigration == nil)
    }

    // MARK: Persistence

    @Test("Values written by one store are read by a new store on the same suite")
    func persistenceAcrossStores() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let first = suite.makeStore()
        first.hasCompletedSetup = true
        first.lockMode = .passwordAndBiometrics
        first.sortOption = .dateModified
        first.sortDirection = .descending
        first.pendingMigration = PendingMigration(kind: .encrypt, targetLockMode: .password)

        let second = suite.makeStore()
        #expect(second.hasCompletedSetup == true)
        #expect(second.lockMode == .passwordAndBiometrics)
        #expect(second.sortOption == .dateModified)
        #expect(second.sortDirection == .descending)
        #expect(second.pendingMigration == PendingMigration(kind: .encrypt, targetLockMode: .password))
    }

    @Test("Stores on different suites do not share values")
    func suitesAreIsolated() {
        let a = TestSuite()
        let b = TestSuite()
        defer { a.cleanup(); b.cleanup() }
        a.makeStore().lockMode = .password
        #expect(b.makeStore().lockMode == .none)
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

    @Test("An unknown pendingMigrationType reads as no pending migration")
    func unknownMigrationType() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set("bogus", forKey: "pendingMigrationType")
        suite.defaults.set("password", forKey: "pendingMigrationTargetLockMode")
        #expect(suite.makeStore().pendingMigration == nil)
    }

    @Test("An unknown target raw value on an encrypt migration reads as no target")
    func unknownMigrationTarget() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set("encrypt", forKey: "pendingMigrationType")
        suite.defaults.set("bogus", forKey: "pendingMigrationTargetLockMode")
        #expect(suite.makeStore().pendingMigration == PendingMigration(kind: .encrypt, targetLockMode: nil))
    }

    @Test("A stored target on a decrypt migration is not read")
    func storedTargetIgnoredForDecrypt() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set("decrypt", forKey: "pendingMigrationType")
        suite.defaults.set("password", forKey: "pendingMigrationTargetLockMode")
        #expect(suite.makeStore().pendingMigration == PendingMigration(kind: .decrypt, targetLockMode: nil))
    }

    // MARK: Legacy-written values

    @Test("Raw values written directly under the documented keys are read back")
    func readsDocumentedKeys() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        suite.defaults.set(true, forKey: "hasCompletedSetup")
        suite.defaults.set("passwordAndBiometrics", forKey: "lockMode")
        suite.defaults.set("type", forKey: "sortOption")
        suite.defaults.set("descending", forKey: "sortDirection")
        suite.defaults.set("encrypt", forKey: "pendingMigrationType")
        suite.defaults.set("password", forKey: "pendingMigrationTargetLockMode")
        let store = suite.makeStore()
        #expect(store.hasCompletedSetup == true)
        #expect(store.lockMode == .passwordAndBiometrics)
        #expect(store.sortOption == .type)
        #expect(store.sortDirection == .descending)
        #expect(store.pendingMigration == PendingMigration(kind: .encrypt, targetLockMode: .password))
    }

    // MARK: Thread safety

    @Test("Concurrent reads and writes from several threads neither crash nor tear")
    func concurrentAccess() {
        let suite = TestSuite()
        defer { suite.cleanup() }
        let store = suite.makeStore()
        let migrations: [PendingMigration?] = [
            nil,
            PendingMigration(kind: .decrypt, targetLockMode: nil),
            PendingMigration(kind: .encrypt, targetLockMode: .password),
            PendingMigration(kind: .encrypt, targetLockMode: .passwordAndBiometrics),
        ]
        let valid = Mutex(true)
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            store.hasCompletedSetup = i.isMultiple(of: 2)
            store.lockMode = LockMode.allCases[i % LockMode.allCases.count]
            store.sortOption = SortOption.allCases[i % SortOption.allCases.count]
            store.sortDirection = SortDirection.allCases[i % SortDirection.allCases.count]
            store.pendingMigration = migrations[i % migrations.count]

            _ = store.hasCompletedSetup
            _ = store.lockMode
            _ = store.sortOption
            _ = store.sortDirection
            // A read must be one of the values that was written, never a mix (e.g. decrypt with a target).
            let read = store.pendingMigration
            if let read, read.kind == .decrypt, read.targetLockMode != nil {
                valid.set(false)
            }
        }
        #expect(valid.get())
        // The store still works after the storm.
        store.lockMode = .password
        #expect(store.lockMode == .password)
    }
}

/// Minimal lock-protected flag.
private final class Mutex: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
