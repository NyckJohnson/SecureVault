import Foundation
import os

/// The live `PreferencesStoring`: typed settings in an injected UserDefaults suite.
///
/// Keys and raw values match what earlier app versions wrote, so existing settings stay readable.
/// Unknown raw values read as the documented defaults. Every access goes through one lock, so the
/// two keys of `pendingMigration` are always read and written together and never tear.
final class UserDefaultsPreferences: PreferencesStoring {
    private enum Key {
        static let hasCompletedSetup = "hasCompletedSetup"
        static let lockMode = "lockMode"
        static let sortOption = "sortOption"
        static let sortDirection = "sortDirection"
        static let pendingMigrationType = "pendingMigrationType"
        static let pendingMigrationTargetLockMode = "pendingMigrationTargetLockMode"
    }

    /// The suite, reachable only while holding the lock. `UserDefaults` is not `Sendable`, so the
    /// lock owns it: no other reference to it escapes this class.
    private let suite: OSAllocatedUnfairLock<UserDefaults>

    /// A store reading and writing `defaults` (the app passes its suite; tests a throwaway one).
    init(defaults: UserDefaults) {
        suite = OSAllocatedUnfairLock(uncheckedState: defaults)
    }

    var hasCompletedSetup: Bool {
        get { suite.withLock { defaults in defaults.bool(forKey: Key.hasCompletedSetup) } }
        set { suite.withLock { defaults in defaults.set(newValue, forKey: Key.hasCompletedSetup) } }
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

    /// Stored as `pendingMigrationType` plus, for `.encrypt` only, `pendingMigrationTargetLockMode`.
    /// A target given with `.decrypt` is dropped; nil removes both keys.
    var pendingMigration: PendingMigration? {
        get {
            suite.withLock { defaults in
                let kind: MigrationKind? = defaults.enumValue(forKey: Key.pendingMigrationType)
                switch kind {
                case nil:
                    return nil
                case .encrypt:
                    let target: LockMode? = defaults.enumValue(forKey: Key.pendingMigrationTargetLockMode)
                    return PendingMigration(kind: .encrypt, targetLockMode: target)
                case .decrypt:
                    return PendingMigration(kind: .decrypt, targetLockMode: nil)
                }
            }
        }
        set {
            suite.withLock { defaults in
                defaults.set(newValue?.kind.rawValue, forKey: Key.pendingMigrationType)
                let target = newValue?.kind == .encrypt ? newValue?.targetLockMode : nil
                defaults.set(target?.rawValue, forKey: Key.pendingMigrationTargetLockMode)
            }
        }
    }

    var vaultsUpgraded: Bool {
        get {
            fatalError(
                "Not implemented: UserDefaultsPreferences.vaultsUpgraded (feature multiple-vaults-duress-password)")
        }
        set {
            _ = newValue
            fatalError(
                "Not implemented: UserDefaultsPreferences.vaultsUpgraded (feature multiple-vaults-duress-password)")
        }
    }
}

private extension UserDefaults {
    /// The string stored under `key` as a `Value`, or nil when it is missing or not a known raw value.
    func enumValue<Value: RawRepresentable>(forKey key: String) -> Value? where Value.RawValue == String {
        string(forKey: key).flatMap(Value.init(rawValue:))
    }
}
