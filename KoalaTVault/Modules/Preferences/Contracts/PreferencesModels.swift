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

/// Whether a lock migration encrypts or decrypts the vault.
enum MigrationKind: String, Sendable, Codable {
    case encrypt, decrypt
}

/// A lock migration that has started and not yet finished (persisted so a kill can resume it).
struct PendingMigration: Sendable, Codable, Equatable, Hashable {
    /// Encrypt or decrypt.
    var kind: MigrationKind
    /// The lock mode an encrypt migration ends in; nil for decrypt.
    var targetLockMode: LockMode?
}
