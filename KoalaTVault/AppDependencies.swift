//
//  AppDependencies.swift
//  KoalaTVault
//
//  Composition root. Decides, once per launch, which storage the app uses:
//  the real Documents vault, Keychain and UserDefaults.standard, or (with the
//  `-uiTesting` launch argument) a throwaway temporary vault, an in-memory
//  Keychain and a dedicated UserDefaults suite. With `-unitTestHost` as well
//  (the unit-test host only, set by the test plan), the "Unlock Pro" entitlement
//  is an inert stand-in that never talks to StoreKit.
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
/// installs here, so legacy singletons (view controllers built by legacy code) can reach it
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

// MARK: - Inert pro unlock (unit-test host)

/// The entitlement installed in the hosted unit-test process (`-unitTestHost`): always locked, makes no
/// StoreKit calls and starts no `Transaction.updates` listener, so the host app can't finish or observe
/// transactions that `StoreKitProUnlockTests` drive in the same process. Tests that need an entitlement
/// inject their own.
@MainActor
private final class InertProUnlock: ProUnlocking {
    var isUnlocked: Bool { false }
    nonisolated var isUnlockedNow: Bool { false }

    func displayPrice() async -> String? { nil }

    /// Never buys: there is no product in the unit-test host.
    func purchase(confirmIn scene: UIScene?) async throws -> PurchaseOutcome {
        throw ProUnlockError.productUnavailable
    }

    func restore() async throws -> Bool { false }

    func refresh() async {}

    /// The value never changes, so the stream ends at once.
    func unlockedUpdates() -> AsyncStream<Bool> {
        AsyncStream { $0.finish() }
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
    /// The launch argument the test plan gives the hosted unit-test process only (UI-test launches
    /// don't pass it): the app then installs an inert entitlement instead of the StoreKit one.
    static let unitTestHostArgument = "-unitTestHost"
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
        // Not under tmp, which holds the vault store's temporary files.
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

// MARK: - Slow migration store (-uiTesting)

/// A `VaultStoring` that forwards everything to `base`, except that migrating a file (either direction)
/// first waits `delay`, as the legacy app's `UITEST_MIGRATION_FILE_DELAY` hook did, so a UI test can
/// background or lock mid-migration. Built only in `-uiTesting` mode, never in a module.
nonisolated struct SlowMigrationVaultStore: VaultStoring {
    let base: any VaultStoring
    let delay: Duration

    var root: VaultDirectory { base.root }

    /// Waits before a file's migration. A cancelled wait just migrates sooner.
    private func waitBeforeMigrating() async {
        do {
            try await Task.sleep(for: delay)
        } catch {
            // Cancellation only; nothing in the app cancels a migration.
        }
    }

    func migrateToEncrypted(_ item: VaultItem) async throws {
        await waitBeforeMigrating()
        try await base.migrateToEncrypted(item)
    }

    func migrateToDecrypted(_ item: VaultItem) async throws {
        await waitBeforeMigrating()
        try await base.migrateToDecrypted(item)
    }

    func contents(of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection) async throws -> [VaultItem] {
        try await base.contents(of: directory, sortedBy: option, direction)
    }
    func open(_ item: VaultItem) async throws -> URL { try await base.open(item) }
    func write(_ data: Data, to item: VaultItem) async throws { try await base.write(data, to: item) }
    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await base.createFolder(named: name, in: directory)
    }
    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await base.createDocument(named: name, in: directory)
    }
    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem {
        try await base.addFile(from: source, named: name, to: directory)
    }
    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem? {
        try await base.findItem(named: name, in: directory)
    }
    func move(_ item: VaultItem, to directory: VaultDirectory) async throws { try await base.move(item, to: directory) }
    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem {
        try await base.copy(item, to: directory)
    }
    func rename(_ item: VaultItem, to name: String) async throws -> VaultItem { try await base.rename(item, to: name) }
    func moveToTrash(_ item: VaultItem) async throws { try await base.moveToTrash(item) }
    func trashContents() async throws -> [VaultItem] { try await base.trashContents() }
    func restore(_ trashed: VaultItem) async throws -> VaultItem { try await base.restore(trashed) }
    func deletePermanently(_ trashed: VaultItem) async throws { try await base.deletePermanently(trashed) }
    func emptyTrash() async { await base.emptyTrash() }
    func purgeExpiredTrash(now: Date) async throws -> Int { try await base.purgeExpiredTrash(now: now) }
    func countFiles() async throws -> Int { try await base.countFiles() }
    func itemsToMigrate(toEncrypted: Bool) async throws -> [VaultItem] {
        try await base.itemsToMigrate(toEncrypted: toEncrypted)
    }
    func finishDecryption() async throws { try await base.finishDecryption() }
    func finishEncryption() async throws { try await base.finishEncryption() }
    func hasUnencryptedFiles() async throws -> Bool { try await base.hasUnencryptedFiles() }
    func keyMatchesVault() async -> Bool { await base.keyMatchesVault() }
    func sweepOrphans() async { await base.sweepOrphans() }
    func makeTempDirectory() throws -> URL { try base.makeTempDirectory() }
    func removeTemporary(_ url: URL) { base.removeTemporary(url) }
    func removeAllTemporaryFiles() { base.removeAllTemporaryFiles() }
}

// MARK: - Legacy screen services

/// What the legacy browser screens need from the composition root, handed from screen to screen.
@MainActor
struct LegacyBrowserServices {
    /// The app's one vault store.
    let vaultStore: any VaultStoring
    /// The app's settings (sort order).
    let preferences: any PreferencesStoring
    /// Thumbnails for the browser's cells.
    let thumbnails: any ThumbnailProviding
    /// Streaming playback of encrypted videos in the viewer.
    let videoAssets: any VideoAssetProviding
    /// The import sheet and pickers.
    let importPresenter: ImportPresenter
    /// The app's one export presenter (the export sheet and document picker).
    let exportPresenter: ExportPresenter
    /// The app's one vault lock (lock state, lock mode, settings).
    let vaultLock: any VaultLocking
    /// The app's one lock migration (Settings adds and removes the lock through it).
    let lockMigrator: any LockMigrating
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
    /// transaction-update listener and the launch refresh. In the unit-test host (`-unitTestHost`) it is an
    /// inert, always-locked stand-in with no StoreKit calls.
    let proUnlock: any ProUnlocking
    /// The app's one vault store over `storage.vaultRootURL` (Documents normally; the temporary vault in
    /// `-uiTesting` mode, where `UITEST_MIGRATION_FILE_DELAY` wraps it in `SlowMigrationVaultStore`).
    let vaultStore: any VaultStoring
    /// The app's one video loader: streams encrypted videos to AVPlayer, over the file cipher.
    let videoAssets: any VideoAssetProviding
    /// The app's one thumbnail provider, over `vaultStore`, the file cipher, `videoAssets` and the preferences.
    let thumbnails: any ThumbnailProviding
    /// The app's one import presenter. It lives as long as the app because it holds the last picker until
    /// the next one replaces it, which keeps cancelling the document picker from crashing on iOS 18.
    let importPresenter: ImportPresenter
    /// The app's one export presenter. It lives as long as the app because it holds the last picker until
    /// the next one replaces it, which keeps cancelling the document picker from crashing on iOS 18.
    let exportPresenter: ExportPresenter
    /// The app's one vault lock: the key lifecycle and the lock state, over the master key store, the
    /// preferences and `vaultStore`.
    let vaultLock: any VaultLocking
    /// The legacy lock screen and privacy cover presenter, over `vaultLock`, until LockScreens replaces it.
    let authService: AuthService
    /// The app's one lock migration, over `vaultStore`, `vaultLock` and the preferences. In `-uiTesting` mode
    /// `UITEST_FAIL_MIGRATION_FILE` names the file it fails.
    let lockMigrator: any LockMigrating
    /// What the legacy browser screens are built with.
    var browserServices: LegacyBrowserServices {
        LegacyBrowserServices(
            vaultStore: vaultStore, preferences: preferences, thumbnails: thumbnails, videoAssets: videoAssets,
            importPresenter: importPresenter, exportPresenter: exportPresenter, vaultLock: vaultLock,
            lockMigrator: lockMigrator)
    }
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "AppDependencies")

    init(storage: LegacyStorage = .current, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.storage = storage
        let proUnlock: any ProUnlocking
        if arguments.contains(LegacyStorage.unitTestHostArgument) {
            proUnlock = InertProUnlock()
        } else {
            proUnlock = StoreKitProUnlock(defaults: storage.defaults)
        }
        self.proUnlock = proUnlock
        storage.proUnlockSlot.install(proUnlock)

        let liveStore = LiveVaultStore(
            root: storage.vaultRootURL,
            keyStore: storage.masterKeyStore,
            cipher: storage.fileCipher,
            preferences: storage.preferences,
            temporaryRoot: FileManager.default.temporaryDirectory
        )
        let vaultStore: any VaultStoring
        if let seconds = storage.uiTestSettings?.migrationFileDelay, seconds > 0 {
            vaultStore = SlowMigrationVaultStore(base: liveStore, delay: .seconds(seconds))
        } else {
            vaultStore = liveStore
        }
        self.vaultStore = vaultStore
        let videoAssets = EncryptedVideoLoader(cipher: storage.fileCipher)
        self.videoAssets = videoAssets
        thumbnails = LiveThumbnailProvider(
            store: vaultStore, cipher: storage.fileCipher, videoAssets: videoAssets,
            renderer: LiveThumbnailRenderer(), preferences: storage.preferences)
        importPresenter = ImportPresenter(
            importer: LiveVaultImporter(store: vaultStore, proUnlock: proUnlock),
            cameraRoll: PhotoLibraryAccess(),
            store: vaultStore,
            photoAccess: LiveImportPhotoAccess())
        exportPresenter = ExportPresenter(
            exporter: LiveVaultExporter(
                store: vaultStore,
                photoSaver: PhotoLibrarySaver(store: vaultStore, library: SystemPhotoLibraryAdder())))

        // The seeded lock must be in place before the vault lock reads the lock mode.
        if let password = storage.uiTestSettings?.password {
            Self.seedPassword(password, storage: storage)
        }
        let vaultRoot = storage.vaultRootURL
        let vaultLock = LiveVaultLock(
            masterKeys: storage.masterKeyStore,
            keychain: storage.keychain,
            preferences: storage.preferences,
            store: vaultStore,
            biometricInfo: BiometricInfo(probe: LiveBiometricProbe()),
            vaultHoldsEncryptedData: {
                VaultEncryptedDataCheck.holdsEncryptedData(at: vaultRoot, fileManager: .default)
            }
        )
        self.vaultLock = vaultLock
        authService = AuthService(
            vaultLock: vaultLock, preferences: storage.preferences, keyStore: storage.masterKeyStore)
        // `uiTestSettings` is non-nil only in `-uiTesting` mode, so the failing file is a UI-test hook only.
        lockMigrator = LiveLockMigrator(
            store: vaultStore, lock: vaultLock, preferences: storage.preferences,
            uiTestFailFileName: storage.uiTestSettings?.failMigrationFileName)
    }

    /// `UITEST_PASSWORD`: the empty test vault starts set up with `password` and lock mode password, as after
    /// a relaunch (the key is not loaded). Runs before the vault lock is built, so it starts `.locked`.
    private static func seedPassword(_ password: String, storage: LegacyStorage) {
        do {
            try storage.masterKeyStore.createMasterKey(password: password)
        } catch {
            // Test-only path: a half-seeded launch would make UI tests fail later for an unclear reason.
            let message = "-uiTesting: creating the seeded password failed: \(error.localizedDescription)"
            Logger(subsystem: "com.KoalaTVault", category: "AppDependencies").error("\(message, privacy: .public)")
            fatalError(message)
        }
        storage.masterKeyStore.wipeKey()
        storage.preferences.lockMode = .password
        storage.preferences.hasCompletedSetup = true
    }

    /// Applies the `-uiTesting` seeds (files, pending migration, plaintext index) to the empty test storage;
    /// the password seed is applied while building (see `seedPassword`).
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

        if let pending = settings.pendingMigration {
            preferences.pendingMigration = MigrationKind(rawValue: pending).map {
                PendingMigration(kind: $0, targetLockMode: vaultLock.lockMode)
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
