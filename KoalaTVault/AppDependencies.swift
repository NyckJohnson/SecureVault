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
import UIKit

// MARK: - In-memory Keychain

/// An in-memory stand-in for the Keychain used in `-uiTesting` mode: one item per account.
/// Accessibility is ignored, so biometric reads succeed without a prompt.
nonisolated final class InMemoryKeychain: KeychainAccessing {
    private let items = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    init() {}

    func read(account: String, prompt: String?) throws -> Data? {
        items.withLock { $0[account] }
    }

    func write(_ data: Data, account: String, accessibility: KeychainAccessibility) throws {
        items.withLock { $0[account] = data }
    }

    func delete(account: String) throws {
        items.withLock { $0[account] = nil }
    }
}

// MARK: - Pro unlock slot

/// Holds the app's one `ProUnlocking`, which `AppDependencies` builds on the main actor at launch and
/// installs here, so legacy singletons (`FileSystem`, view controllers built by legacy code) can reach it
/// through `LegacyStorage.current.proUnlock` until each takes it by injection.
nonisolated final class LegacyProUnlockSlot: Sendable {
    private let value = OSAllocatedUnfairLock<(any ProUnlocking)?>(initialState: nil)

    init() {}

    /// Installs (or replaces) the entitlement legacy code reads.
    func install(_ proUnlock: any ProUnlocking) {
        value.withLock { $0 = proUnlock }
    }

    /// The installed entitlement, or nil before `AppDependencies` has installed one.
    var installed: (any ProUnlocking)? { value.withLock { $0 } }
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
    /// The Keychain service of the vault's items (the legacy password item is matched without it).
    static let keychainService = "com.KoalaTVault"

    /// The vault root (Documents normally; a fresh temporary folder in `-uiTesting` mode).
    let vaultRootURL: URL
    /// Keychain access (real normally; in memory in `-uiTesting` mode).
    let keychain: any KeychainAccessing
    /// The vault master key store, over `keychain`. Legacy singletons reach it here; new code
    /// takes it by injection from `AppDependencies`.
    let masterKeyStore: any MasterKeyStoring
    /// The file and index cipher, using `masterKeyStore`'s key.
    let fileCipher: any FileCipher
    /// The app's settings, over `defaults` (built once here). Legacy singletons reach it here;
    /// new code takes it by injection from `AppDependencies`.
    let preferences: any PreferencesStoring
    /// The UserDefaults suite in `-uiTesting` mode; `nil` means `.standard`.
    /// (A name rather than the instance, because `UserDefaults` is not `Sendable`.)
    let defaultsSuiteName: String?
    /// Non-nil only in `-uiTesting` mode.
    let uiTestSettings: UITestSettings?
    /// Where `AppDependencies` installs the app's one `ProUnlocking` for legacy code.
    let proUnlockSlot = LegacyProUnlockSlot()

    /// The storage for this process, decided from its launch arguments on first use.
    static let current = LegacyStorage(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    /// Preferences store (`.standard` normally; a cleared dedicated suite in `-uiTesting` mode).
    var defaults: UserDefaults { Self.openDefaults(suiteName: defaultsSuiteName) }

    /// The app's "Unlock Pro" entitlement, built and installed by `AppDependencies` at launch.
    /// Legacy singletons reach it here; new code takes it by injection from `AppDependencies`.
    var proUnlock: any ProUnlocking {
        guard let proUnlock = proUnlockSlot.installed else {
            // Unreachable: AppDelegate builds AppDependencies (which installs it) before any scene or import.
            fatalError("LegacyStorage.proUnlock read before AppDependencies installed it")
        }
        return proUnlock
    }

    /// `.standard` for a nil `suiteName`, else that suite.
    private static func openDefaults(suiteName: String?) -> UserDefaults {
        guard let suiteName else { return .standard }
        guard let suite = UserDefaults(suiteName: suiteName) else {
            // Unreachable: the name was validated when this storage was made.
            fatalError("-uiTesting: could not open the UserDefaults suite")
        }
        return suite
    }

    /// Builds the storage, the one master key store and file cipher over `keychain`, and the
    /// one preferences store over the chosen UserDefaults suite.
    init(vaultRootURL: URL, keychain: any KeychainAccessing, defaultsSuiteName: String?, uiTestSettings: UITestSettings?) {
        let masterKeyStore = LiveMasterKeyStore(keychain: keychain)
        self.vaultRootURL = vaultRootURL
        self.keychain = keychain
        self.masterKeyStore = masterKeyStore
        self.fileCipher = LiveFileCipher(keyStore: masterKeyStore)
        self.preferences = UserDefaultsPreferences(defaults: Self.openDefaults(suiteName: defaultsSuiteName))
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
                keychain: KeychainStore(service: Self.keychainService),
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
    /// The vault master key store (built once, in `storage`).
    var masterKeyStore: any MasterKeyStoring { storage.masterKeyStore }
    /// The file and index cipher (built once, in `storage`).
    var fileCipher: any FileCipher { storage.fileCipher }
    /// The app's settings (built once, in `storage`).
    var preferences: any PreferencesStoring { storage.preferences }
    /// The "Unlock Pro" entitlement, built once at launch over the same UserDefaults as the preferences
    /// (so its `entitlement.isUnlocked` cache stays where earlier versions kept it). Building it starts the
    /// transaction-update listener and the launch refresh.
    let proUnlock: any ProUnlocking
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "AppDependencies")

    init(storage: LegacyStorage = .current) {
        self.storage = storage
        let proUnlock = StoreKitProUnlock(defaults: storage.defaults)
        self.proUnlock = proUnlock
        storage.proUnlockSlot.install(proUnlock)
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
                preferences.hasCompletedSetup = true
            } catch {
                // Test-only path: a half-seeded launch would make UI tests fail later for an unclear reason.
                let message = "-uiTesting: creating the seeded password failed: \(error.localizedDescription)"
                logger.error("\(message, privacy: .public)")
                fatalError(message)
            }
        }

        if let pending = settings.pendingMigration {
            preferences.pendingMigration = MigrationKind(rawValue: pending).map {
                PendingMigration(kind: $0, targetLockMode: AuthService.shared.lockMode)
            }
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
