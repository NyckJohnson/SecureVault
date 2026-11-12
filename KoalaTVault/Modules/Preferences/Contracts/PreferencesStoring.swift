import Foundation

// coverage-exempt-file: declarations only

/// Typed app settings, persisted in an injected UserDefaults suite.
protocol PreferencesStoring: AnyObject, Sendable {
    /// The vault's lock mode.
    var lockMode: LockMode { get set }
    /// The browser's sort option.
    var sortOption: SortOption { get set }
    /// The browser's sort direction.
    var sortDirection: SortDirection { get set }
    /// Whether 1.2 left an encrypt migration unfinished (`pendingMigrationType` == "encrypt").
    var hasPendingEncryptMigration: Bool { get }
    /// Removes both pending-migration keys.
    func clearPendingMigration()
    /// Whether the one-time upgrade to multiple vaults has run.
    var vaultsUpgraded: Bool { get set }
}
