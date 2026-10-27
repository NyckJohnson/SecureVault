import Foundation

// coverage-exempt-file: declarations only

/// Typed app settings, persisted in an injected UserDefaults suite.
protocol PreferencesStoring: AnyObject, Sendable {
    /// Whether the setup wizard has been completed.
    var hasCompletedSetup: Bool { get set }
    /// The vault's lock mode.
    var lockMode: LockMode { get set }
    /// The browser's sort option.
    var sortOption: SortOption { get set }
    /// The browser's sort direction.
    var sortDirection: SortDirection { get set }
    /// The lock migration in progress, if any.
    var pendingMigration: PendingMigration? { get set }
}
