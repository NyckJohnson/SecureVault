import Foundation

/// How the vault is protected.
enum LockMode: String, Sendable, Codable, CaseIterable {
    case none, password, passwordAndBiometrics
}

/// The global sort option of the browser.
enum SortOption: String, Sendable, Codable, CaseIterable {
    case name, type, dateModified

    /// The option's label: "Name", "Type", "Date Modified".
    var displayName: String {
        switch self {
        case .name: "Name"
        case .type: "Type"
        case .dateModified: "Date Modified"
        }
    }
}

/// The global sort direction of the browser.
enum SortDirection: String, Sendable, Codable, CaseIterable {
    case ascending, descending
}
