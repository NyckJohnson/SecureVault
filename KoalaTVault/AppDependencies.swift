//
//  AppDependencies.swift
//  KoalaTVault
//
//  Composition root. Decides, once per launch, which storage the app uses:
//  the real Documents vault, Application Support/Vaults, Keychain and
//  UserDefaults.standard, or (Debug builds only, with the `-uiTesting` launch
//  argument) a throwaway temporary vault and vaults folder, an in-memory Keychain
//  and a dedicated UserDefaults suite. With `-unitTestHost` as well (the unit-test
//  host only, set by the test plan), the "Unlock Pro" entitlement is an inert
//  stand-in that never talks to StoreKit.
//
//  The app-wide services (the vault lock, the lock migration, the lock coordinator,
//  the entitlement) are built once; the services of a vault (thumbnails, import,
//  export, viewer, settings, browser) are built for the vault that is `current`,
//  and only that vault's are kept.
//
//  Every test-only launch path (the two launch arguments, the `UITEST_*` seeds,
//  the slow migration store, the inert entitlement) is compiled only in Debug:
//  unit and UI tests build Debug, so a Release build has none of them. The
//  in-memory Keychain is compiled in every build: it also backs the vault lock's
//  decoy key store.
//

import CryptoKit
import Foundation
import os
import UIKit

// MARK: - In-memory Keychain

/// An in-memory stand-in for the Keychain: one item per account. Used for all storage in `-uiTesting` mode, and in
/// every build as the private Keychain of the vault lock's decoy key store (never the real Keychain).
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

#if DEBUG

// MARK: - Inert pro unlock (unit-test host, Debug only)

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

// MARK: - UI-test launch settings (Debug only)

/// Launch settings that only take effect with `-uiTesting`, read from the environment.
nonisolated struct UITestSettings: Sendable, Equatable {
    /// The 1.2 lock mode `UITEST_LEGACY_LOCK` seeds.
    enum LegacyLock: String, Sendable, Equatable {
        /// `password`: lock mode Password.
        case password
        /// `biometric`: lock mode Password + Face ID, with the biometric key item.
        case biometric
    }

    /// `UITEST_SEED_FILE_NAME`: a plaintext file of this name is created in the unencrypted vault's root.
    var seedFileName: String?
    /// `UITEST_SEED_FILE_COUNT`: this many `uitest-seed-<i>.txt` files are created in the unencrypted vault's root.
    var seedFileCount: Int?
    /// `UITEST_SEED_IMAGE_COUNT`: this many valid plaintext `uitest-image-<i>.png` files are created in the
    /// unencrypted vault's root.
    var seedImageCount: Int?
    /// `UITEST_PASSWORD`: an empty encrypted vault "Test Vault" with this password; with `UITEST_LEGACY_LOCK`, the
    /// password of the seeded 1.2 vault instead.
    var password: String?
    /// `UITEST_LEGACY_LOCK`: `password` or `biometric` seeds the 1.2 layout (the seed files, a blob for `password`,
    /// the lock mode set, not upgraded), so the upgrade runs at launch. Any other value stops the launch.
    var legacyLock: LegacyLock?
    /// `UITEST_FAIL_MIGRATION_FILE`: encrypting a leftover file with this name fails.
    var failMigrationFileName: String?
    /// `UITEST_MIGRATION_FILE_DELAY`: seconds the leftover encryption waits before each file, so a test
    /// can background or lock mid-encryption.
    var migrationFileDelay: Double?

    init(environment: [String: String]) {
        seedFileName = environment["UITEST_SEED_FILE_NAME"]
        seedFileCount = environment["UITEST_SEED_FILE_COUNT"].flatMap { Int($0) }
        seedImageCount = environment["UITEST_SEED_IMAGE_COUNT"].flatMap { Int($0) }
        password = environment["UITEST_PASSWORD"]
        legacyLock = environment["UITEST_LEGACY_LOCK"].map { value in
            guard let lock = LegacyLock(rawValue: value) else {
                // Test-only path: a misspelt seed would make UI tests fail later for an unclear reason.
                fatalError("-uiTesting: UITEST_LEGACY_LOCK must be password or biometric")
            }
            return lock
        }
        failMigrationFileName = environment["UITEST_FAIL_MIGRATION_FILE"]
        migrationFileDelay = environment["UITEST_MIGRATION_FILE_DELAY"].flatMap { Double($0) }
    }
}

#endif

// MARK: - Storage

/// Where the app keeps its data: the unencrypted vault's root, the encrypted vaults' folder, the Keychain and the
/// preferences. Chosen once per launch from the launch arguments; `AppDependencies` hands each part to the services
/// that need it. Key stores and ciphers are made per vault by the vault lock, never here.
nonisolated struct AppStorage: Sendable {
    #if DEBUG
    /// The launch argument that selects the clean, isolated test state (Debug builds only).
    static let uiTestingArgument = "-uiTesting"
    /// The launch argument the test plan gives the hosted unit-test process only (UI-test launches
    /// don't pass it): the app then installs an inert entitlement instead of the StoreKit one (Debug builds only).
    static let unitTestHostArgument = "-unitTestHost"
    #endif
    /// The Keychain service of the vaults' items (the old password item is matched without it).
    static let keychainService = "com.KoalaTVault"

    /// The unencrypted vault's root (Documents normally; a fresh temporary folder in `-uiTesting` mode).
    let vaultRootURL: URL
    /// The folder holding one folder per encrypted vault (`Application Support/Vaults` normally; `Vaults` next to
    /// the temporary vault in `-uiTesting` mode).
    let vaultsFolderURL: URL
    /// Keychain access (real normally; in memory in `-uiTesting` mode).
    let keychain: any KeychainAccessing
    /// The app's settings, over `defaults` (built once here).
    let preferences: any PreferencesStoring
    /// The UserDefaults suite in `-uiTesting` mode; `nil` means `.standard`.
    /// (A name rather than the instance, because `UserDefaults` is not `Sendable`.)
    let defaultsSuiteName: String?
    #if DEBUG
    /// Non-nil only in `-uiTesting` mode (Debug builds only).
    private(set) var uiTestSettings: UITestSettings?
    #endif

    /// The storage for this process, decided from its launch arguments on first use. Only the default
    /// argument of `AppDependencies.init` reads it, so the app (and the unit-test host) builds its storage
    /// exactly once; nothing else reaches storage through it.
    static let current = AppStorage(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    /// Preferences store (`.standard` normally; a cleared dedicated suite in `-uiTesting` mode).
    var defaults: UserDefaults { Self.openDefaults(suiteName: defaultsSuiteName) }

    /// `.standard` for a nil `suiteName`, else that suite.
    private static func openDefaults(suiteName: String?) -> UserDefaults {
        guard let suiteName else { return .standard }
        guard let suite = UserDefaults(suiteName: suiteName) else {
            // Unreachable: the name was validated when this storage was made.
            fatalError("AppStorage: could not open the UserDefaults suite")
        }
        return suite
    }

    /// Builds the storage and the one preferences store over the chosen UserDefaults suite.
    init(vaultRootURL: URL, vaultsFolderURL: URL, keychain: any KeychainAccessing, defaultsSuiteName: String?) {
        self.vaultRootURL = vaultRootURL
        self.vaultsFolderURL = vaultsFolderURL
        self.keychain = keychain
        self.preferences = UserDefaultsPreferences(defaults: Self.openDefaults(suiteName: defaultsSuiteName))
        self.defaultsSuiteName = defaultsSuiteName
    }

    /// The real storage, or (Debug builds only) the isolated test storage when `arguments` contains
    /// `-uiTesting`. A Release build ignores both parameters.
    init(arguments: [String], environment: [String: String]) {
        #if DEBUG
        if arguments.contains(Self.uiTestingArgument) {
            self = Self.makeUITesting(environment: environment)
            return
        }
        #endif
        let fileManager = FileManager.default
        self.init(
            vaultRootURL: fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0],
            vaultsFolderURL: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Vaults", isDirectory: true),
            keychain: KeychainStore(service: Self.keychainService),
            defaultsSuiteName: nil
        )
    }

    #if DEBUG

    /// Builds an empty, isolated storage. Any failure here stops the app rather than
    /// falling back to the real vaults, Keychain or UserDefaults.
    private static func makeUITesting(environment: [String: String]) -> AppStorage {
        let fileManager = FileManager.default
        // Not under tmp, which holds the vault stores' temporary files.
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

        var storage = AppStorage(
            vaultRootURL: root,
            vaultsFolderURL: container.appendingPathComponent("Vaults", isDirectory: true),  // next to the vault
            keychain: InMemoryKeychain(),
            defaultsSuiteName: suiteName)
        storage.uiTestSettings = UITestSettings(environment: environment)
        return storage
    }
    #endif
}

#if DEBUG

// MARK: - Slow migration store (-uiTesting, Debug only)

/// A `VaultStoring` that forwards everything to `base`, except that encrypting a leftover file first waits
/// `delay`, as the earlier app's `UITEST_MIGRATION_FILE_DELAY` hook did, so a UI test can background or lock
/// mid-encryption. Built only in `-uiTesting` mode, for encrypted vaults, never in a module.
nonisolated struct SlowMigrationVaultStore: VaultStoring {
    let base: any VaultStoring
    let delay: Duration

    var root: VaultDirectory { base.root }
    var isEncrypted: Bool { base.isEncrypted }

    /// Waits before a file's encryption. A cancelled wait just goes on sooner: the migrator itself checks for
    /// cancellation between files.
    private func waitBeforeMigrating() async {
        do {
            try await Task.sleep(for: delay)
        } catch {
            // Cancellation only; the migrator stops at its next check.
        }
    }

    func migrateToEncrypted(_ item: VaultItem) async throws {
        await waitBeforeMigrating()
        try await base.migrateToEncrypted(item)
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
    func remove(_ item: VaultItem) async throws { try await base.remove(item) }
    func trashContents() async throws -> [VaultItem] { try await base.trashContents() }
    func restore(_ trashed: VaultItem) async throws -> VaultItem { try await base.restore(trashed) }
    func deletePermanently(_ trashed: VaultItem) async throws { try await base.deletePermanently(trashed) }
    func emptyTrash() async { await base.emptyTrash() }
    func purgeExpiredTrash(now: Date) async throws -> Int { try await base.purgeExpiredTrash(now: now) }
    func hasUnreadableTrash() async -> Bool { await base.hasUnreadableTrash() }
    func clearUnreadableTrash() async throws { try await base.clearUnreadableTrash() }
    func countFiles() async throws -> Int { try await base.countFiles() }
    func itemsToEncrypt() async throws -> [VaultItem] { try await base.itemsToEncrypt() }
    func finishEncryption() async throws { try await base.finishEncryption() }
    func hasUnencryptedFiles() async throws -> Bool { try await base.hasUnencryptedFiles() }
    func keyMatchesVault() async -> Bool { await base.keyMatchesVault() }
    func sweepOrphans() async { await base.sweepOrphans() }
    func makeTempDirectory() throws -> URL { try base.makeTempDirectory() }
    func removeTemporary(_ url: URL) { base.removeTemporary(url) }
    func removeAllTemporaryFiles() { base.removeAllTemporaryFiles() }
}

#endif

// MARK: - Temporary files of earlier launches

/// Each launch gives the vault store its own temporary root, `<tmp>/StoreTemporaryFiles/<UUID>`, so the
/// temporary files earlier launches left behind (after a crash, say) are exactly the other entries of
/// `<tmp>/StoreTemporaryFiles`. At launch they are listed on the main thread, which is quick, and deleted on
/// a background task, so the first frame never waits for a large leftover; this launch's root is never
/// listed, so nothing created after launch is touched. The lock's wipe on entering the background
/// (`removeAllTemporaryFiles`) works on this launch's root as before.
nonisolated enum LaunchTemporaryFiles {
    /// The folder holding every launch's temporary root.
    static var container: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StoreTemporaryFiles", isDirectory: true)
    }

    /// Where builds before this one kept the store's temporary files (`<tmp>/VaultStore`, the store's own
    /// folder directly under tmp). It can still hold decrypted copies of vault files after an update, so every
    /// launch deletes it along with the earlier launches' roots. A fixed path the shell knows; nothing creates
    /// it any more.
    static var preUpdateFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VaultStore", isDirectory: true)
    }

    /// A fresh temporary root for this launch, inside `container` (the app's `StoreTemporaryFiles` folder
    /// unless a test passes its own). Not created here: the store creates its folders under it when it first
    /// needs one.
    static func makeLaunchRoot(in container: URL = LaunchTemporaryFiles.container) -> URL {
        container.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// The entries of `container` (the app's `StoreTemporaryFiles` folder unless a test passes its own) other
    /// than `launchRoot`: the earlier launches' roots. A missing or unreadable container means there is nothing
    /// to remove.
    static func leftovers(keeping launchRoot: URL, in container: URL = LaunchTemporaryFiles.container) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil, options: [])) ?? []
        return entries.filter { $0.lastPathComponent != launchRoot.lastPathComponent }
    }

    /// Deletes `entries`. Best effort, like `removeAllTemporaryFiles`: an entry that is missing (such as
    /// `preUpdateFolder` once it is gone) is skipped, and one that can't be deleted now is deleted at the next
    /// launch (the system also clears the temp folder eventually).
    static func remove(_ entries: [URL]) {
        for entry in entries {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

// MARK: - The unencrypted vault's key store

/// The key store of the unencrypted vault's store, which never encrypts or decrypts anything: it holds no key and
/// has no Keychain item, so every key operation fails with `VaultCryptoError.noKeyLoaded` and nothing is written.
nonisolated private struct NoKeyStore: MasterKeyStoring {
    var isKeyLoaded: Bool { false }
    func hasMasterKeyBlob() throws -> Bool { false }
    func createMasterKey(password: String) throws { throw VaultCryptoError.noKeyLoaded }
    func unlock(password: String) throws { throw VaultCryptoError.noKeyLoaded }
    func rewrap(newPassword: String) throws { throw VaultCryptoError.noKeyLoaded }
    func deleteMasterKeyBlob() throws {}
    func storeBiometricKey() throws { throw VaultCryptoError.noKeyLoaded }
    func unlockWithBiometricKey(prompt: String) throws { throw VaultCryptoError.noKeyLoaded }
    func deleteBiometricKey() throws {}
    func wipeKey() {}
    func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T { throw VaultCryptoError.noKeyLoaded }
}

// MARK: - Vault ciphers

/// The file cipher of each encrypted vault store the vault lock made, by the store's root folder. `OpenVault` carries
/// only the store, but the vault's thumbnails and video loader need its cipher, so the store factory records it here
/// and the composition root looks it up when the vault becomes `current`; it then drops every other vault's entry.
nonisolated private final class VaultCiphers: Sendable {
    private let ciphers = OSAllocatedUnfairLock<[URL: any FileCipher]>(initialState: [:])

    func record(_ cipher: any FileCipher, forRoot root: URL) {
        ciphers.withLock { $0[root.standardizedFileURL] = cipher }
    }

    /// The cipher recorded for `root`; every other entry is dropped.
    func keepOnly(root: URL) -> (any FileCipher)? {
        let key = root.standardizedFileURL
        return ciphers.withLock { entries in
            let cipher = entries[key]
            entries = cipher.map { [key: $0] } ?? [:]
            return cipher
        }
    }
}

// MARK: - Vault-deleted relay

/// The vault lock as Settings sees it: everything is forwarded, and a successful `deleteCurrentVault` then calls
/// `onDeleted` (the coordinator's `lock()`), so the lock screen shows after a vault is deleted. Settings has no
/// callback of its own for this, so the composition root gives it this relay instead of the lock.
@MainActor
private final class VaultDeletionRelay: VaultLocking {
    private let base: any VaultLocking
    private let onDeleted: () -> Void

    init(base: any VaultLocking, onDeleted: @escaping () -> Void) {
        self.base = base
        self.onDeleted = onDeleted
    }

    func deleteCurrentVault(password: String) async throws {
        try await base.deleteCurrentVault(password: password)
        onDeleted()
    }

    var current: OpenVault { base.current }
    var unencryptedVault: OpenVault { base.unencryptedVault }
    func currentUpdates() -> AsyncStream<OpenVault> { base.currentUpdates() }
    var biometricKind: BiometricKind { base.biometricKind }
    var biometricsAvailable: Bool { base.biometricsAvailable }
    var hasBiometricVault: Bool { base.hasBiometricVault }
    var currentUsesBiometrics: Bool { base.currentUsesBiometrics }
    func upgradeIfNeeded() async throws { try await base.upgradeIfNeeded() }
    func canCreateVault() async -> Bool { await base.canCreateVault() }
    func createVault(name: String, password: String) async throws {
        try await base.createVault(name: name, password: password)
    }
    func open(password: String) async throws { try await base.open(password: password) }
    func openWithBiometrics() async throws { try await base.openWithBiometrics() }
    func close() { base.close() }
    func appWillResignActive() -> Bool { base.appWillResignActive() }
    func appDidEnterBackground() { base.appDidEnterBackground() }
    func changePassword(current: String, new: String) async throws {
        try await base.changePassword(current: current, new: new)
    }
    func setUsesBiometrics(_ enabled: Bool) async throws { try await base.setUsesBiometrics(enabled) }
    func openTransferTarget(password: String) async throws -> OpenVault {
        try await base.openTransferTarget(password: password)
    }
    func closeTransferTarget(_ vault: OpenVault) { base.closeTransferTarget(vault) }
}

// MARK: - Lock screen tracking

/// The lock screens the coordinator asks for, made by `base`, with the shell told when the lock screen is up and
/// when it is done: a vault change while it is up leaves it (and what is over it) in place, and the Migration screen
/// waits until it has gone.
@MainActor
final class LockScreenTracker: VaultsScreenFactory {
    private let base: any VaultsScreenFactory
    /// Names the lock screen on screen; `nil` when none is.
    private var activeScreen: UUID?
    private var pendingAction: (() -> Void)?

    init(base: any VaultsScreenFactory) {
        self.base = base
    }

    /// Whether a lock screen is up (made and not yet done).
    var isLockScreenUp: Bool { activeScreen != nil }

    func makeLockScreen(
        onDone: @escaping () -> Void,
        onNeedsPro: @escaping (UIViewController) -> Void
    ) -> UIViewController {
        let token = UUID()
        activeScreen = token
        return base.makeLockScreen(
            onDone: { [weak self] in
                onDone()   // the coordinator dismisses the screen first
                self?.lockScreenDone(token)
            },
            onNeedsPro: onNeedsPro)
    }

    /// Runs `action` now if no lock screen is up, else once it is done (replacing an earlier waiting action).
    func whenLockScreenGone(_ action: @escaping () -> Void) {
        if activeScreen == nil {
            action()
        } else {
            pendingAction = action
        }
    }

    /// Drops the action waiting for the lock screen, if any.
    func cancelPendingAction() {
        pendingAction = nil
    }

    private func lockScreenDone(_ token: UUID) {
        guard activeScreen == token else { return }
        activeScreen = nil
        let action = pendingAction
        pendingAction = nil
        action?()
    }
}

// MARK: - Browser reload relay

/// Forwards a reload request to the browser factory, which is built after the settings factory that asks for
/// it (Recently Deleted's restore): the browser factory needs the settings factory, so the settings factory's
/// `onRestore` reaches it through this relay. Held weakly, so the relay keeps nothing alive.
@MainActor
private final class BrowserReloadRelay {
    weak var browserFactory: (any BrowserFactory)?

    func reloadAll() {
        browserFactory?.reloadAll()
    }
}

// MARK: - Vault services

/// The services of one open vault, built when it becomes `current` and dropped when another vault does.
@MainActor
struct VaultServices {
    /// The vault these services are for.
    let vault: OpenVault
    /// Thumbnails over the vault's store and cipher.
    let thumbnails: any ThumbnailProviding
    /// The import presenter. It lives as long as the vault is current because it holds the last picker until
    /// the next one replaces it, which keeps cancelling the document picker from crashing on iOS 18.
    let importPresenter: ImportPresenter
    /// The export presenter; kept for the same reason as `importPresenter`.
    let exportPresenter: ExportPresenter
    /// Makes the file viewer and the rich-text editor.
    let viewerFactory: any ViewerFactory
    /// Makes the vault's Settings, the paywall and the Migration screen.
    let settingsFactory: any SettingsFactory
    /// Makes the vault's root browser and reloads its browsers.
    let browserFactory: any BrowserFactory
}

// MARK: - Composition root

/// Builds the app's dependencies once at launch, and each vault's services when it becomes `current`.
@MainActor
final class AppDependencies {
    #if DEBUG
    /// The name of the encrypted vault `UITEST_PASSWORD` seeds (Debug builds only).
    static let uiTestVaultName = "Test Vault"
    #endif

    let storage: AppStorage
    /// The app's settings (built once, in `storage`).
    var preferences: any PreferencesStoring { storage.preferences }
    /// The "Unlock Pro" entitlement, built once at launch over the same UserDefaults as the preferences
    /// (so its `entitlement.isUnlocked` cache stays where earlier versions kept it). Building it starts the
    /// transaction-update listener and the launch refresh. In the unit-test host (`-unitTestHost`, Debug builds
    /// only) it is an inert, always-locked stand-in with no StoreKit calls.
    let proUnlock: any ProUnlocking
    /// This launch's own temporary root; each vault store gets its own folder under it (see `LaunchTemporaryFiles`).
    private let temporaryRoot: URL
    /// The vaults: the unencrypted vault over `storage.vaultRootURL` and the encrypted vaults in
    /// `storage.vaultsFolderURL`, each with a `LiveMasterKeyStore` for its blob account, a `LiveFileCipher` and a
    /// `LiveVaultStore` with its own temporary folder.
    let vaultLock: any VaultLocking
    /// The leftover encryption of an opened vault. In `-uiTesting` mode (Debug builds only)
    /// `UITEST_FAIL_MIGRATION_FILE` names the file it fails.
    let lockMigrator: any LockMigrating
    /// Moves and copies files between vaults.
    private let transfer: any VaultTransferring
    /// The cipher of each encrypted vault store the lock made (see `VaultCiphers`).
    private let vaultCiphers: VaultCiphers
    /// The unencrypted vault's cipher, over a key store that holds no key.
    private let unencryptedCipher: any FileCipher
    /// The lock screens, as the coordinator makes them, with the shell told when one is up.
    let lockScreens: LockScreenTracker
    /// The lock screen, the privacy cover and closing the vault on background and on Lock. The paywall it asks for
    /// (Create New Vault without Pro) comes from the current vault's settings factory.
    private(set) lazy var lockCoordinator: any AppLockCoordinating = AppLockCoordinator(
        lock: vaultLock, screens: lockScreens, presenter: LockPresenter(),
        onNeedsPro: { [weak self] screen in self?.presentPaywall(from: screen) })
    /// The vault lock Settings gets: deleting the vault there also locks (`lockCoordinator.lock()`).
    private lazy var settingsLock: any VaultLocking = VaultDeletionRelay(
        base: vaultLock, onDeleted: { [weak self] in self?.lockCoordinator.lock() })
    /// The services of the vault that is `current`; replaced by `openServices(for:)`.
    private(set) var currentServices: VaultServices?
    private let logger = Logger(subsystem: "com.KoalaTVault", category: "AppDependencies")

    /// Builds every app-wide service and the services of the vault open at launch (the unencrypted vault).
    /// `arguments` only matters in Debug builds (`-unitTestHost`); Release ignores it.
    init(storage: AppStorage = .current, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.storage = storage
        let proUnlock = Self.makeProUnlock(storage: storage, arguments: arguments)
        self.proUnlock = proUnlock

        let temporaryRoot = LaunchTemporaryFiles.makeLaunchRoot()
        self.temporaryRoot = temporaryRoot
        let unencryptedCipher = LiveFileCipher(keyStore: NoKeyStore())
        self.unencryptedCipher = unencryptedCipher
        let unencryptedStore = LiveVaultStore(
            root: storage.vaultRootURL, name: "KoalaTVault", isEncrypted: false, keyStore: NoKeyStore(),
            cipher: unencryptedCipher, temporaryRoot: Self.storeTemporaryRoot(in: temporaryRoot))
        let vaultCiphers = VaultCiphers()
        self.vaultCiphers = vaultCiphers
        let vaultLock = Self.makeVaultLock(
            storage: storage, unencryptedStore: unencryptedStore, proUnlock: proUnlock,
            temporaryRoot: temporaryRoot, vaultCiphers: vaultCiphers)
        self.vaultLock = vaultLock
        lockMigrator = LiveLockMigrator(uiTestFailFileName: Self.failMigrationFileName(storage: storage))
        transfer = LiveVaultTransfer(pro: proUnlock)
        lockScreens = LockScreenTracker(base: LiveVaultsScreenFactory(lock: vaultLock))
        openServices(for: vaultLock.current)
    }

    /// The StoreKit entitlement; in the unit-test host (`-unitTestHost`, Debug builds only) the inert one.
    private static func makeProUnlock(storage: AppStorage, arguments: [String]) -> any ProUnlocking {
        #if DEBUG
        if arguments.contains(AppStorage.unitTestHostArgument) {
            return InertProUnlock()
        }
        #endif
        return StoreKitProUnlock(defaults: storage.defaults)
    }

    /// A fresh temporary folder for one vault store under this launch's temporary root.
    nonisolated private static func storeTemporaryRoot(in temporaryRoot: URL) -> URL {
        temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// The vault lock over `storage`: the unencrypted vault's `unencryptedStore`, the vaults in
    /// `storage.vaultsFolderURL`, and per vault a `LiveMasterKeyStore` for its blob account, a `LiveFileCipher` over
    /// it (recorded in `vaultCiphers`) and a `LiveVaultStore` with its own folder under `temporaryRoot`; the decoy key
    /// store is a `LiveMasterKeyStore` over a private `InMemoryKeychain`, never the real one. In
    /// `-uiTesting` mode (Debug builds only) `UITEST_MIGRATION_FILE_DELAY` wraps encrypted stores in
    /// `SlowMigrationVaultStore`.
    private static func makeVaultLock(
        storage: AppStorage, unencryptedStore: any VaultStoring, proUnlock: any ProUnlocking, temporaryRoot: URL,
        vaultCiphers: VaultCiphers
    ) -> LiveVaultLock {
        let keychain = storage.keychain
        let migrationDelay = migrationFileDelay(storage: storage)
        return LiveVaultLock(
            documents: storage.vaultRootURL,
            vaultsFolder: storage.vaultsFolderURL,
            unencryptedStore: unencryptedStore,
            keychain: keychain,
            preferences: storage.preferences,
            pro: proUnlock,
            biometricInfo: BiometricInfo(probe: LiveBiometricProbe()),
            makeKeyStore: { LiveMasterKeyStore(keychain: keychain, blobAccount: $0) },
            makeDecoyKeyStore: { LiveMasterKeyStore(keychain: InMemoryKeychain(), blobAccount: "decoy") },
            makeCipher: { LiveFileCipher(keyStore: $0) },
            makeStore: { root, name, isEncrypted, keyStore, cipher in
                let store = LiveVaultStore(
                    root: root, name: name, isEncrypted: isEncrypted, keyStore: keyStore, cipher: cipher,
                    temporaryRoot: storeTemporaryRoot(in: temporaryRoot))
                vaultCiphers.record(cipher, forRoot: root)
                #if DEBUG
                if isEncrypted, let migrationDelay {
                    return SlowMigrationVaultStore(base: store, delay: migrationDelay)
                }
                #endif
                return store
            }
        )
    }

    /// `UITEST_MIGRATION_FILE_DELAY` as a duration, if positive; always `nil` outside `-uiTesting` mode and in a
    /// Release build.
    private static func migrationFileDelay(storage: AppStorage) -> Duration? {
        #if DEBUG
        if let seconds = storage.uiTestSettings?.migrationFileDelay, seconds > 0 {
            return .seconds(seconds)
        }
        #endif
        return nil
    }

    /// `UITEST_FAIL_MIGRATION_FILE`: the file the leftover encryption fails. `uiTestSettings` is non-nil only in
    /// `-uiTesting` mode, so this is a UI-test hook only; always `nil` in a Release build.
    private static func failMigrationFileName(storage: AppStorage) -> String? {
        #if DEBUG
        return storage.uiTestSettings?.failMigrationFileName
        #else
        return nil
        #endif
    }

    // MARK: Vault services

    /// Makes `vault` the vault whose services the app keeps: clears the previous vault's thumbnail cache, builds
    /// `vault`'s services and drops every other vault's. Returns the new services.
    @discardableResult
    func openServices(for vault: OpenVault) -> VaultServices {
        currentServices?.thumbnails.clearCache()
        let services = makeServices(for: vault)
        currentServices = services
        return services
    }

    private func makeServices(for vault: OpenVault) -> VaultServices {
        let store = vault.store
        let cipher = cipher(for: vault)
        let videoAssets = EncryptedVideoLoader(cipher: cipher)
        let thumbnails = LiveThumbnailProvider(
            store: store, cipher: cipher, videoAssets: videoAssets,
            renderer: LiveThumbnailRenderer(), preferences: preferences)
        let importPresenter = ImportPresenter(
            importer: LiveVaultImporter(store: store, proUnlock: proUnlock),
            cameraRoll: PhotoLibraryAccess(),
            store: store,
            photoAccess: LiveImportPhotoAccess())
        let exporter = LiveVaultExporter(
            store: store,
            photoSaver: PhotoLibrarySaver(store: store, library: SystemPhotoLibraryAdder()))
        let exportPresenter = ExportPresenter(exporter: exporter)
        let viewerFactory = LiveViewerFactory(store: store, videoAssets: videoAssets, exportPresenter: exportPresenter)
        let reloadRelay = BrowserReloadRelay()
        let settingsFactory = LiveSettingsFactory(
            lock: settingsLock, migrator: lockMigrator, store: store, pro: proUnlock,
            onRestore: { reloadRelay.reloadAll() })
        let browserFactory = LiveBrowserFactory(
            store: store, preferences: preferences, thumbnails: thumbnails, exporter: exporter,
            exportPresenter: exportPresenter, importPresenter: importPresenter, viewerFactory: viewerFactory,
            settingsFactory: settingsFactory,
            vaultServices: BrowserVaultServices(
                lock: vaultLock, transfer: transfer,
                onLock: { [weak self] in self?.lockCoordinator.lock() }))
        reloadRelay.browserFactory = browserFactory
        return VaultServices(
            vault: vault, thumbnails: thumbnails, importPresenter: importPresenter, exportPresenter: exportPresenter,
            viewerFactory: viewerFactory, settingsFactory: settingsFactory, browserFactory: browserFactory)
    }

    /// The cipher of `vault`'s store; every other encrypted vault's recorded cipher is dropped.
    private func cipher(for vault: OpenVault) -> any FileCipher {
        let recorded = vaultCiphers.keepOnly(root: vault.store.root.rootURL)
        guard vault.isEncrypted else { return unencryptedCipher }
        if let recorded { return recorded }
        // Unreachable: the lock makes every encrypted store through `makeStore`, which records its cipher. The
        // keyless cipher only means encrypted thumbnails and videos fail to load, never a crash or a wrong key.
        logger.fault("No cipher was recorded for the open encrypted vault")
        return unencryptedCipher
    }

    /// Presents the paywall over `screen` (the lock screen's Create New Vault without Pro).
    private func presentPaywall(from screen: UIViewController) {
        guard let settingsFactory = currentServices?.settingsFactory else { return }
        screen.present(settingsFactory.makePaywall(onUnlock: {}), animated: true)
    }

    // MARK: Launch

    /// Removes the vault stores' temporary files that earlier launches left behind, and the folder where
    /// builds before this one kept them (`LaunchTemporaryFiles.preUpdateFolder`): lists them now, on the main
    /// thread, and deletes them on a background task, so the caller (the scene's first frame) doesn't wait.
    /// Files this launch creates are never touched.
    func removeTemporaryFilesOfEarlierLaunches() {
        let leftovers = LaunchTemporaryFiles.leftovers(keeping: temporaryRoot) + [LaunchTemporaryFiles.preUpdateFolder]
        Task.detached(priority: .utility) {
            LaunchTemporaryFiles.remove(leftovers)
        }
    }

    /// Applies the synchronous `-uiTesting` seeds to the empty test storage: the seed files in the unencrypted
    /// vault's root and, with `UITEST_LEGACY_LOCK`, the rest of the 1.2 layout (a blob for `UITEST_PASSWORD` under
    /// the old blob account, the lock mode, not upgraded), so the upgrade runs at launch. The encrypted "Test Vault"
    /// is seeded later, at connect (`seedTestVaultIfRequested`). Does nothing without `-uiTesting`, and nothing at
    /// all in a Release build.
    func prepareForLaunch() {
        #if DEBUG
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
        if let count = settings.seedImageCount {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            for index in 0..<max(count, 0) {
                seedFile(at: root.appendingPathComponent("uitest-image-\(index).png"), content: image)
            }
        }
        if let legacyLock = settings.legacyLock {
            seedLegacyLock(legacyLock, password: settings.password)
        }
        #endif
    }

    #if DEBUG
    /// `UITEST_LEGACY_LOCK`: the 1.2 lock as that version left it, with no key loaded: a blob for `password` (if
    /// given) under the old blob account, the biometric key item for `.biometric`, and the lock mode.
    private func seedLegacyLock(_ legacyLock: UITestSettings.LegacyLock, password: String?) {
        if let password {
            let keyStore = LiveMasterKeyStore(keychain: storage.keychain)
            do {
                try keyStore.createMasterKey(password: password)
                if legacyLock == .biometric {
                    try keyStore.storeBiometricKey()
                }
            } catch {
                // Test-only path: a half-seeded launch would make UI tests fail later for an unclear reason.
                failSeeding("-uiTesting: seeding the 1.2 lock failed: \(error.localizedDescription)")
            }
            keyStore.wipeKey()
        }
        preferences.lockMode = legacyLock == .biometric ? .passwordAndBiometrics : .password
    }

    /// `UITEST_PASSWORD` without `UITEST_LEGACY_LOCK`: creates the empty encrypted vault "Test Vault" with that
    /// password, then closes it, so the app still opens on the lock screen with the unencrypted vault current.
    /// Run at connect after the upgrade and before the lock screen shows, so a UI test never finds the lock screen
    /// before the vault exists. Does nothing without `-uiTesting`.
    func seedTestVaultIfRequested() async {
        guard let settings = storage.uiTestSettings, settings.legacyLock == nil, let password = settings.password else {
            return
        }
        do {
            try await vaultLock.createVault(name: Self.uiTestVaultName, password: password)
        } catch {
            failSeeding("-uiTesting: creating the seeded vault failed: \(error.localizedDescription)")
        }
        vaultLock.close()
    }

    private func seedFile(at url: URL, content: Data) {
        if !FileManager.default.createFile(atPath: url.path, contents: content) {
            // Test-only path (only called from `-uiTesting` seeding): fail hard rather than start half-seeded.
            failSeeding("-uiTesting: could not seed \(url.lastPathComponent)")
        }
    }

    private func failSeeding(_ message: String) -> Never {
        logger.error("\(message, privacy: .public)")
        fatalError(message)
    }
    #endif
}
