//
//  PreferencesService.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/20/26.
//

import Foundation

nonisolated enum LegacyLockMode: String {
    case none
    case password
    case passwordAndBiometrics
}

nonisolated final class PreferencesService: Sendable {
    static let shared = PreferencesService()
    private init() {}

    private var defaults: UserDefaults { LegacyStorage.current.defaults }

    private let hasCompletedSetupKey = "hasCompletedSetup"
    private let lockModeKey          = "lockMode"

    var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: hasCompletedSetupKey) }
        set { defaults.set(newValue, forKey: hasCompletedSetupKey) }
    }

    var lockMode: LegacyLockMode {
        get { LegacyLockMode(rawValue: defaults.string(forKey: lockModeKey) ?? "none") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: lockModeKey) }
    }
    
    private let sortOptionKey    = "sortOption"
    private let sortDirectionKey = "sortDirection"

    private let pendingMigrationTypeKey           = "pendingMigrationType"
    private let pendingMigrationTargetLockModeKey = "pendingMigrationTargetLockMode"

    var pendingMigrationType: LegacyMigrationViewController.MigrationType? {
        get { LegacyMigrationViewController.MigrationType(rawValue: defaults.string(forKey: pendingMigrationTypeKey) ?? "") }
        set { defaults.set(newValue?.rawValue, forKey: pendingMigrationTypeKey) }
    }

    /// Only meaningful when pendingMigrationType == .encrypt — the LegacyLockMode the user
    /// originally selected, needed to finalize correctly if migration is resumed later.
    var pendingMigrationTargetLockMode: LegacyLockMode? {
        get { defaults.string(forKey: pendingMigrationTargetLockModeKey).flatMap(LegacyLockMode.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: pendingMigrationTargetLockModeKey) }
    }

    var sortOption: LegacySortOption {
        get { LegacySortOption(rawValue: defaults.string(forKey: sortOptionKey) ?? "name") ?? .name }
        set { defaults.set(newValue.rawValue, forKey: sortOptionKey) }
    }

    var sortDirection: LegacySortDirection {
        get { LegacySortDirection(rawValue: defaults.string(forKey: sortDirectionKey) ?? "ascending") ?? .ascending }
        set { defaults.set(newValue.rawValue, forKey: sortDirectionKey) }
    }
}

nonisolated enum LegacySortOption: String, CaseIterable {
    case name
    case type
    case dateModified

    var displayName: String {
        switch self {
        case .name:         return "Name"
        case .type:         return "Type"
        case .dateModified: return "Date Modified"
        }
    }
}

nonisolated enum LegacySortDirection: String {
    case ascending
    case descending
}
