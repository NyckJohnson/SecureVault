//
//  AppDependencies.swift
//  KoalaTVault
//
//  Composition root. Decides, once per launch, which storage the app uses:
//  the real Documents vault, Keychain and UserDefaults.standard, or (with the
//  `-uiTesting` launch argument) a throwaway temporary vault, an in-memory
//  Keychain and a dedicated UserDefaults suite.
//

import Foundation
import os
import Security
import UIKit

// MARK: - Keychain access seam

/// The Keychain operations the app performs, so they can be routed to the real
/// Keychain or to an in-memory store. Each method mirrors the `SecItem*` function
/// of the same name and returns its `OSStatus`.
nonisolated protocol KeychainAccess: Sendable {
    /// Mirrors `SecItemAdd`. Returns `errSecDuplicateItem` if a matching item exists.
    func add(_ attributes: [String: Any]) -> OSStatus
    /// Mirrors `SecItemUpdate`. Returns `errSecItemNotFound` if nothing matches.
    func update(matching query: [String: Any], with attributes: [String: Any]) -> OSStatus
    /// Mirrors `SecItemCopyMatching`; `result` is the returned value (e.g. `Data`) on success.
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?)
    /// Mirrors `SecItemDelete`. Returns `errSecItemNotFound` if nothing matches.
    @discardableResult
    func delete(matching query: [String: Any]) -> OSStatus
}

/// The real Keychain.
nonisolated struct SystemKeychain: KeychainAccess {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(matching query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    @discardableResult
    func delete(matching query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// An in-memory stand-in for the Keychain used in `-uiTesting` mode. Items are
/// generic passwords identified by service and account; a query matches every item
/// whose service and account equal the query's (an attribute the query omits matches
/// anything), like the real Keychain. Access-control and authentication-context
/// attributes are ignored, so biometric reads succeed without a prompt.
nonisolated final class InMemoryKeychain: KeychainAccess {
    private struct Item: Sendable {
        var service: String?
        var account: String?
        var data: Data
    }

    private let items = OSAllocatedUnfairLock<[Item]>(initialState: [])

    init() {}

    func add(_ attributes: [String: Any]) -> OSStatus {
        guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        let service = attributes[kSecAttrService as String] as? String
        let account = attributes[kSecAttrAccount as String] as? String
        return items.withLock { items in
            if items.contains(where: { $0.service == service && $0.account == account }) {
                return errSecDuplicateItem
            }
            items.append(Item(service: service, account: account, data: data))
            return errSecSuccess
        }
    }

    func update(matching query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        let newData = attributes[kSecValueData as String] as? Data
        let key = Self.key(of: query)
        return items.withLock { items in
            var found = false
            for index in items.indices where Self.matches(items[index], key) {
                found = true
                if let newData { items[index].data = newData }
            }
            return found ? errSecSuccess : errSecItemNotFound
        }
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        let key = Self.key(of: query)
        let match = items.withLock { items in items.first(where: { Self.matches($0, key) }) }
        guard let match else { return (errSecItemNotFound, nil) }
        let wantsData = (query[kSecReturnData as String] as? Bool) ?? false
        return (errSecSuccess, wantsData ? match.data as NSData : nil)
    }

    @discardableResult
    func delete(matching query: [String: Any]) -> OSStatus {
        let key = Self.key(of: query)
        return items.withLock { items in
            let before = items.count
            items.removeAll { Self.matches($0, key) }
            return items.count < before ? errSecSuccess : errSecItemNotFound
        }
    }

    /// The service and account a query names; `nil` matches any value.
    private static func key(of query: [String: Any]) -> (service: String?, account: String?) {
        (query[kSecAttrService as String] as? String, query[kSecAttrAccount as String] as? String)
    }

    private static func matches(_ item: Item, _ key: (service: String?, account: String?)) -> Bool {
        if let service = key.service, item.service != service { return false }
        if let account = key.account, item.account != account { return false }
        return true
    }
}

// MARK: - Storage

/// Launch settings that only take effect with `-uiTesting`, read from the environment.
nonisolated struct UITestSettings: Sendable, Equatable {
    /// `UITEST_SEED_FILE_NAME`: a plaintext file of this name is created in the vault root.
    var seedFileName: String?
    /// `UITEST_SEED_FILE_COUNT`: this many `uitest-seed-<i>.txt` files are created in the vault root.
    var seedFileCount: Int?
    /// `UITEST_PASSWORD`: the vault starts set up with this password and lock mode password.
    var password: String?
    /// `UITEST_FAIL_MIGRATION_FILE`: migrating a file with this name fails.
    var failMigrationFileName: String?
    /// `UITEST_MIGRATION_FILE_DELAY`: seconds the migration waits before each file, so a test
    /// can background or lock mid-migration.
    var migrationFileDelay: Double?
    /// `UITEST_PENDING_MIGRATION`: `encrypt` or `decrypt`; the launch finds that migration
    /// pending (an interrupted one), with the seeded lock mode as its target.
    var pendingMigration: String?
    /// `UITEST_PLAINTEXT_INDEX=1`: an empty plaintext `.vault_map` in the vault root, as older
    /// builds wrote when the key was wiped mid-migration (baseline fix 23).
    var plaintextIndex: Bool

    init(environment: [String: String]) {
        seedFileName = environment["UITEST_SEED_FILE_NAME"]
        seedFileCount = environment["UITEST_SEED_FILE_COUNT"].flatMap { Int($0) }
        password = environment["UITEST_PASSWORD"]
        failMigrationFileName = environment["UITEST_FAIL_MIGRATION_FILE"]
        migrationFileDelay = environment["UITEST_MIGRATION_FILE_DELAY"].flatMap { Double($0) }
        pendingMigration = environment["UITEST_PENDING_MIGRATION"]
        plaintextIndex = environment["UITEST_PLAINTEXT_INDEX"] == "1"
    }
}

/// Where the legacy services keep their data. Chosen once per launch from the
/// launch arguments; legacy code reads it through `LegacyStorage.current` until each
/// module takes its storage by injection.
nonisolated struct LegacyStorage: Sendable {
    /// The launch argument that selects the clean, isolated test state.
    static let uiTestingArgument = "-uiTesting"

    /// The vault root (Documents normally; a fresh temporary folder in `-uiTesting` mode).
    let vaultRootURL: URL
    /// Keychain access (real normally; in memory in `-uiTesting` mode).
    let keychain: any KeychainAccess
    /// The UserDefaults suite in `-uiTesting` mode; `nil` means `.standard`.
    /// (A name rather than the instance, because `UserDefaults` is not `Sendable`.)
    let defaultsSuiteName: String?
    /// Non-nil only in `-uiTesting` mode.
    let uiTestSettings: UITestSettings?

    /// The storage for this process, decided from its launch arguments on first use.
    static let current = LegacyStorage(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    /// Preferences store (`.standard` normally; a cleared dedicated suite in `-uiTesting` mode).
    var defaults: UserDefaults {
        guard let defaultsSuiteName else { return .standard }
        guard let suite = UserDefaults(suiteName: defaultsSuiteName) else {
            // Unreachable: the name was validated when this storage was made.
            fatalError("-uiTesting: could not open the UserDefaults suite")
        }
        return suite
    }

    init(vaultRootURL: URL, keychain: any KeychainAccess, defaultsSuiteName: String?, uiTestSettings: UITestSettings?) {
        self.vaultRootURL = vaultRootURL
        self.keychain = keychain
        self.defaultsSuiteName = defaultsSuiteName
        self.uiTestSettings = uiTestSettings
    }

    /// The real storage, or the isolated test storage when `arguments` contains `-uiTesting`.
    init(arguments: [String], environment: [String: String]) {
        if arguments.contains(Self.uiTestingArgument) {
            self = Self.makeUITesting(environment: environment)
        } else {
            self.init(
                vaultRootURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
                keychain: SystemKeychain(),
                defaultsSuiteName: nil,
                uiTestSettings: nil
            )
        }
    }

    /// Builds an empty, isolated storage. Any failure here stops the app rather than
    /// falling back to the real vault, Keychain or UserDefaults.
    private static func makeUITesting(environment: [String: String]) -> LegacyStorage {
        let fileManager = FileManager.default
        // Not under tmp: FileSystem.cleanupTempFiles() empties the temporary directory.
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let container = caches.appendingPathComponent("UITestingVault", isDirectory: true)
        let root = container.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            if fileManager.fileExists(atPath: container.path) {
                try fileManager.removeItem(at: container)   // leftovers of earlier runs
            }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            fatalError("-uiTesting: could not create the temporary vault: \(error)")
        }

        let suiteName = (Bundle.main.bundleIdentifier ?? "KoalaTVault") + ".uiTesting"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            // Unreachable: the suite name is never the app's own domain or NSGlobalDomain.
            fatalError("-uiTesting: could not create the UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)

        return LegacyStorage(
            vaultRootURL: root,
            keychain: InMemoryKeychain(),
            defaultsSuiteName: suiteName,
            uiTestSettings: UITestSettings(environment: environment)
        )
    }
}

// MARK: - Composition root

/// Builds the app's dependencies once at launch.
@MainActor
final class AppDependencies {
    let storage: LegacyStorage
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "AppDependencies")

    init(storage: LegacyStorage = .current) {
        self.storage = storage
    }

    /// Applies the `-uiTesting` seeds (files, password) to the empty test storage.
    /// Does nothing without `-uiTesting`.
    func prepareForLaunch() {
        guard let settings = storage.uiTestSettings else { return }
        UIView.setAnimationsEnabled(false)

        let root = storage.vaultRootURL
        let content = Data("uitest content".utf8)
        if let fileName = settings.seedFileName {
            seedFile(at: root.appendingPathComponent(fileName), content: content)
        }
        if let count = settings.seedFileCount {
            for index in 0..<max(count, 0) {
                seedFile(at: root.appendingPathComponent("uitest-seed-\(index).txt"), content: content)
            }
        }

        if let password = settings.password {
            do {
                try AuthService.shared.createPassword(password)
                AuthService.shared.lockMode = .password
                AuthService.shared.hasAuthenticated = true
                PreferencesService.shared.hasCompletedSetup = true
            } catch {
                // Test-only path: a half-seeded launch would make UI tests fail later for an unclear reason.
                let message = "-uiTesting: creating the seeded password failed: \(error.localizedDescription)"
                logger.error("\(message, privacy: .public)")
                fatalError(message)
            }
        }

        if let pending = settings.pendingMigration {
            PreferencesService.shared.pendingMigrationType = MigrationViewController.MigrationType(rawValue: pending)
            PreferencesService.shared.pendingMigrationTargetLockMode = AuthService.shared.lockMode
        }
        if settings.plaintextIndex {
            seedFile(at: root.appendingPathComponent(".vault_map"), content: Data("{}".utf8))
        }
    }

    private func seedFile(at url: URL, content: Data) {
        if !FileManager.default.createFile(atPath: url.path, contents: content) {
            // Test-only path (only called from `-uiTesting` seeding): fail hard rather than start half-seeded.
            let message = "-uiTesting: could not seed \(url.lastPathComponent)"
            logger.error("\(message, privacy: .public)")
            fatalError(message)
        }
    }
}
