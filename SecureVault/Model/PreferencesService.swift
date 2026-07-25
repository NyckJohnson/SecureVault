//
//  PreferencesService.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/20/26.
//

import Foundation

enum LockMode: String {
    case none
    case password
    case passwordAndBiometrics
}

final class PreferencesService {
    static let shared = PreferencesService()
    private init() {}

    private let defaults = UserDefaults.standard

    private let hasCompletedSetupKey = "hasCompletedSetup"
    private let lockModeKey          = "lockMode"

    var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: hasCompletedSetupKey) }
        set { defaults.set(newValue, forKey: hasCompletedSetupKey) }
    }

    var lockMode: LockMode {
        get { LockMode(rawValue: defaults.string(forKey: lockModeKey) ?? "none") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: lockModeKey) }
    }
    
    private let sortOptionKey    = "sortOption"
    private let sortDirectionKey = "sortDirection"

    var sortOption: SortOption {
        get { SortOption(rawValue: defaults.string(forKey: sortOptionKey) ?? "name") ?? .name }
        set { defaults.set(newValue.rawValue, forKey: sortOptionKey) }
    }

    var sortDirection: SortDirection {
        get { SortDirection(rawValue: defaults.string(forKey: sortDirectionKey) ?? "ascending") ?? .ascending }
        set { defaults.set(newValue.rawValue, forKey: sortDirectionKey) }
    }
}

enum SortOption: String, CaseIterable {
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

enum SortDirection: String {
    case ascending
    case descending
}
