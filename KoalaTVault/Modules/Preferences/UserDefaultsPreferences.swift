import Foundation
import os

/// The live `PreferencesStoring`: typed settings in an injected UserDefaults suite.
///
/// Keys and raw values match what earlier app versions wrote, so existing settings stay readable.
/// Unknown raw values read as the documented defaults. Every access goes through one lock, so the
/// two pending-migration keys are always cleared together and never tear.
final class UserDefaultsPreferences: PreferencesStoring {
    private enum Key {
        static let lockMode = "lockMode"
        static let sortOption = "sortOption"
        static let sortDirection = "sortDirection"
        static let pendingMigrationType = "pendingMigrationType"
        static let pendingMigrationTargetLockMode = "pendingMigrationTargetLockMode"
        static let vaultsUpgraded = "vaultsUpgraded"
    }

    /// The suite, reachable only while holding the lock. `UserDefaults` is not `Sendable`, so the
    /// lock owns it: no other reference to it escapes this class.
    private let suite: OSAllocatedUnfairLock<UserDefaults>

    /// A store reading and writing `defaults` (the app passes its suite; tests a throwaway one).
    init(defaults: UserDefaults) {
        suite = OSAllocatedUnfairLock(uncheckedState: defaults)
    }

    var lockMode: LockMode {
        get { suite.withLock { defaults in defaults.enumValue(forKey: Key.lockMode) ?? LockMode.none } }
        set { suite.withLock { defaults in defaults.set(newValue.rawValue, forKey: Key.lockMode) } }
    }

    var sortOption: SortOption {
        get { suite.withLock { defaults in defaults.enumValue(forKey: Key.sortOption) ?? .name } }
        set { suite.withLock { defaults in defaults.set(newValue.rawValue, forKey: Key.sortOption) } }
    }

    var sortDirection: SortDirection {
        get { suite.withLock { defaults in defaults.enumValue(forKey: Key.sortDirection) ?? .ascending } }
        set { suite.withLock { defaults in defaults.set(newValue.rawValue, forKey: Key.sortDirection) } }
    }

    /// True only when `pendingMigrationType` is "encrypt"; `pendingMigrationTargetLockMode` is never read.
    var hasPendingEncryptMigration: Bool {
        suite.withLock { defaults in defaults.string(forKey: Key.pendingMigrationType) == "encrypt" }
    }

    func clearPendingMigration() {
        suite.withLock { defaults in
            defaults.removeObject(forKey: Key.pendingMigrationType)
            defaults.removeObject(forKey: Key.pendingMigrationTargetLockMode)
        }
    }

    var vaultsUpgraded: Bool {
        get { suite.withLock { defaults in defaults.bool(forKey: Key.vaultsUpgraded) } }
        set { suite.withLock { defaults in defaults.set(newValue, forKey: Key.vaultsUpgraded) } }
    }
}

private extension UserDefaults {
    /// The string stored under `key` as a `Value`, or nil when it is missing or not a known raw value.
    func enumValue<Value: RawRepresentable>(forKey key: String) -> Value? where Value.RawValue == String {
        string(forKey: key).flatMap(Value.init(rawValue:))
    }
}
