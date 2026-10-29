import Foundation
import os

@testable import KoalaTVault

// Test doubles shared by the LockMigration tests. Every double writes to one `MigrationEventLog`, so tests can assert
// the order of calls across the store, the lock and the preferences.

/// An ordered, thread-safe list of what happened.
final class MigrationEventLog: Sendable {
    private let storage = OSAllocatedUnfairLock<[String]>(initialState: [])

    var events: [String] { storage.withLock { $0 } }

    func add(_ event: String) {
        storage.withLock { $0.append(event) }
    }

    func index(of event: String) -> Int? {
        events.firstIndex(of: event)
    }

    func lastIndex(of event: String) -> Int? {
        events.lastIndex(of: event)
    }

    func count(of event: String) -> Int {
        events.filter { $0 == event }.count
    }

    func events(withPrefix prefix: String) -> [String] {
        events.filter { $0.hasPrefix(prefix) }
    }
}

/// Holds a double's call at a named point until released; a point that is never released simulates a kill there.
final class MigrationGate: Sendable {
    private struct State {
        var armed: String?
        var reached: Set<String> = []
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func arm(at name: String) {
        state.withLock {
            $0.armed = name
            $0.released = false
        }
    }

    func disarm() {
        state.withLock { $0.armed = nil }
    }

    func hasReached(_ name: String) -> Bool {
        state.withLock { $0.reached.contains(name) }
    }

    func release() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.released = true
            state.armed = nil
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }

    func pass(_ name: String) async {
        let shouldWait = state.withLock { state -> Bool in
            guard state.armed == name else { return false }
            state.reached.insert(name)
            return true
        }
        guard shouldWait else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.released { return true }
                state.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// Whether the master key is in memory; shared by the fake lock and the fake store.
final class MigrationKeyState: Sendable {
    private let loaded = OSAllocatedUnfairLock(initialState: true)

    var isLoaded: Bool {
        get { loaded.withLock { $0 } }
        set { loaded.withLock { $0 = newValue } }
    }
}

// MARK: - Store

/// A vault of files that migrate in memory.
final class FakeMigrationStore: VaultStoring {
    private struct State {
        var items: [VaultItem]
        var listings = 0
        var injections: [Int: [VaultItem]] = [:]
        var failing: [String: VaultStoreError] = [:]
        var finishesInFlightFile = false
    }

    let root = VaultDirectory(
        name: "KoalaTVault",
        diskURL: URL(fileURLWithPath: "/fake-vault", isDirectory: true),
        rootURL: URL(fileURLWithPath: "/fake-vault", isDirectory: true))
    private let state: OSAllocatedUnfairLock<State>
    private let log: MigrationEventLog
    private let gate: MigrationGate
    private let key: MigrationKeyState

    init(items: [VaultItem], log: MigrationEventLog, gate: MigrationGate, key: MigrationKeyState) {
        state = OSAllocatedUnfairLock(initialState: State(items: items))
        self.log = log
        self.gate = gate
        self.key = key
    }

    /// A file of the fake vault; trashed files live under `.trash/`.
    static func file(_ name: String, encrypted: Bool, trashed: Bool = false) -> VaultItem {
        let rootURL = URL(fileURLWithPath: "/fake-vault", isDirectory: true)
        let path = trashed ? ".trash/\(name)" : name
        return VaultItem(
            id: path, name: name, isDirectory: false, dateModified: Date(timeIntervalSince1970: 0), fileSize: 10,
            deletedAt: trashed ? Date(timeIntervalSince1970: 100) : nil,
            diskURL: rootURL.appendingPathComponent(path), rootURL: rootURL, isEncrypted: encrypted)
    }

    var items: [VaultItem] { state.withLock { $0.items } }

    func isEncrypted(_ name: String) -> Bool? {
        items.first { $0.name == name }?.isEncrypted
    }

    /// The named file keeps failing with this error until cleared.
    func setFailure(_ error: VaultStoreError?, for name: String) {
        state.withLock { $0.failing[name] = error }
    }

    /// Makes the file appear from the given (1-based) `itemsToMigrate` call on.
    func inject(_ item: VaultItem, atListing listing: Int) {
        state.withLock { $0.injections[listing, default: []].append(item) }
    }

    /// When true, a file in progress when the key disappears still finishes.
    func setFinishesInFlightFile(_ value: Bool) {
        state.withLock { $0.finishesInFlightFile = value }
    }

    func itemsToMigrate(toEncrypted: Bool) async throws -> [VaultItem] {
        log.add(toEncrypted ? "list:enc" : "list:dec")
        let listing = state.withLock { state -> Int in
            state.listings += 1
            if let added = state.injections[state.listings] { state.items.append(contentsOf: added) }
            return state.listings
        }
        await gate.pass("list:\(listing)")
        return items.filter { !$0.isDirectory && $0.isEncrypted != toEncrypted }
    }

    func migrateToEncrypted(_ item: VaultItem) async throws {
        try await migrate(item, toEncrypted: true)
    }

    func migrateToDecrypted(_ item: VaultItem) async throws {
        try await migrate(item, toEncrypted: false)
    }

    private func migrate(_ item: VaultItem, toEncrypted: Bool) async throws {
        let tag = toEncrypted ? "enc" : "dec"
        log.add("\(tag):\(item.name)")
        await gate.pass("migrate:\(item.name)")
        let finishes = state.withLock { $0.finishesInFlightFile }
        if !key.isLoaded && !finishes { throw VaultStoreError.locked }
        if let error = state.withLock({ $0.failing[item.name] }) { throw error }
        try state.withLock { state in
            guard let index = state.items.firstIndex(where: { $0.id == item.id }) else {
                throw VaultStoreError.notFound
            }
            let old = state.items[index]
            state.items[index] = VaultItem(
                id: old.id, name: old.name, isDirectory: old.isDirectory, dateModified: old.dateModified,
                fileSize: old.fileSize, deletedAt: old.deletedAt, diskURL: old.diskURL, rootURL: old.rootURL,
                isEncrypted: toEncrypted)
        }
        log.add("\(tag)-done:\(item.name)")
    }

    func finishDecryption() async throws {
        log.add("finishDecryption")
        await gate.pass("finishDecryption")
        guard key.isLoaded else { throw VaultStoreError.locked }
        let remaining = items.filter(\.isEncrypted).count
        if remaining > 0 { throw VaultStoreError.stillEncrypted(count: remaining) }
    }

    func finishEncryption() async throws {
        log.add("finishEncryption")
        await gate.pass("finishEncryption")
        guard key.isLoaded else { throw VaultStoreError.locked }
    }

    // The rest of the store is not used by a migration.

    func contents(
        of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection
    ) async throws -> [VaultItem] {
        []
    }
    func open(_ item: VaultItem) async throws -> URL { item.diskURL }
    func write(_ data: Data, to item: VaultItem) async throws {}
    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        throw VaultStoreError.notFound
    }
    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        throw VaultStoreError.notFound
    }
    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem {
        throw VaultStoreError.notFound
    }
    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem? { nil }
    func move(_ item: VaultItem, to directory: VaultDirectory) async throws {}
    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem {
        throw VaultStoreError.notFound
    }
    func rename(_ item: VaultItem, to name: String) async throws -> VaultItem { throw VaultStoreError.notFound }
    func moveToTrash(_ item: VaultItem) async throws {}
    func trashContents() async throws -> [VaultItem] { [] }
    func restore(_ trashed: VaultItem) async throws -> VaultItem { throw VaultStoreError.notFound }
    func deletePermanently(_ trashed: VaultItem) async throws {}
    func emptyTrash() async {}
    func purgeExpiredTrash(now: Date) async throws -> Int { 0 }
    func countFiles() async throws -> Int { items.count }
    func hasUnencryptedFiles() async throws -> Bool { items.contains { !$0.isEncrypted } }
    func keyMatchesVault() async -> Bool { true }
    func sweepOrphans() async {}
    func makeTempDirectory() throws -> URL { throw VaultStoreError.notFound }
    func removeTemporary(_ url: URL) {}
    func removeAllTemporaryFiles() {}
}

// MARK: - Preferences

/// In-memory preferences that log changes to the pending record and the lock mode.
final class FakeMigrationPreferences: PreferencesStoring {
    private struct State {
        var lockMode: LockMode
        var pending: PendingMigration?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let log: MigrationEventLog

    init(lockMode: LockMode, pending: PendingMigration?, log: MigrationEventLog) {
        state = OSAllocatedUnfairLock(initialState: State(lockMode: lockMode, pending: pending))
        self.log = log
    }

    var hasCompletedSetup = false
    var sortOption = SortOption.name
    var sortDirection = SortDirection.ascending

    var lockMode: LockMode {
        get { state.withLock { $0.lockMode } }
        set {
            state.withLock { $0.lockMode = newValue }
            log.add("lockMode=\(newValue.rawValue)")
        }
    }

    var pendingMigration: PendingMigration? {
        get { state.withLock { $0.pending } }
        set {
            state.withLock { $0.pending = newValue }
            if let newValue {
                log.add("pending=\(newValue.kind.rawValue):\(newValue.targetLockMode?.rawValue ?? "-")")
            } else {
                log.add("pending=nil")
            }
        }
    }
}

// MARK: - Lock

/// A lock whose key can be wiped and restored; the lock mode lives in the preferences.
@MainActor
final class FakeMigrationLock: VaultLocking {
    private let preferences: FakeMigrationPreferences
    private let log: MigrationEventLog
    private let gate: MigrationGate
    private let key: MigrationKeyState
    private(set) var state: LockState

    var lockMode: LockMode { preferences.lockMode }
    var biometricKind = BiometricKind.faceID
    var biometricsAvailable = true

    init(
        preferences: FakeMigrationPreferences, log: MigrationEventLog, gate: MigrationGate, key: MigrationKeyState,
        unlocked: Bool
    ) {
        self.preferences = preferences
        self.log = log
        self.gate = gate
        self.key = key
        if preferences.lockMode == .none {
            state = .open
        } else {
            state = unlocked ? .unlocked : .locked
        }
        key.isLoaded = state != .locked
    }

    /// The app went to the background: the key disappears.
    func wipeKey() {
        key.isLoaded = false
        state = .locked
    }

    /// The user unlocked again.
    func restoreKey() {
        key.isLoaded = true
        state = .unlocked
    }

    func removeKeysAfterDecryption() async throws {
        log.add("removeKeys")
        await gate.pass("removeKeys:before")
        preferences.lockMode = .none
        key.isLoaded = true
        state = .open
        await gate.pass("removeKeys:after")
    }

    func switchMode(to mode: LockMode) async throws {
        preferences.lockMode = mode
    }

    func stateUpdates() -> AsyncStream<LockState> { AsyncStream { $0.finish() } }
    func setUp(mode: LockMode, password: String?) async throws {}
    func unlock(password: String) async throws { restoreKey() }
    func unlockWithBiometrics() async throws { restoreKey() }
    func appWillResignActive() -> Bool { false }
    func appDidEnterBackground() { wipeKey() }
    func appWillEnterForeground() {}
    func changePassword(current: String, new: String) async throws {}
    func prepareToAddLock(mode: LockMode, password: String) async throws {}
}

// MARK: - Harness

/// Assumes this initializer on `@MainActor final class LiveLockMigrator: LockMigrating` in LiveLockMigrator.swift:
/// `init(store: any VaultStoring, lock: any VaultLocking, preferences: any PreferencesStoring,
///       uiTestFailFileName: String? = nil)`
/// `uiTestFailFileName` is the value of `UITEST_FAIL_MIGRATION_FILE`, injected by the composition root in UI-test
/// mode only: the file with that display name fails every time it is migrated.
/// Files are processed in the order `itemsToMigrate` lists them; `pending` reads the preferences' pending record.
@MainActor
final class MigrationHarness {
    let log = MigrationEventLog()
    let gate = MigrationGate()
    let key = MigrationKeyState()
    let preferences: FakeMigrationPreferences
    let store: FakeMigrationStore
    let lock: FakeMigrationLock
    private(set) var migrator: LiveLockMigrator

    /// The default vault: three files and one trashed file, in this listing order.
    static let names = ["a.jpg", "b.pdf", "c.mov", "Old.txt"]

    static func sampleFiles(encrypted: Bool) -> [VaultItem] {
        [
            FakeMigrationStore.file("a.jpg", encrypted: encrypted),
            FakeMigrationStore.file("b.pdf", encrypted: encrypted),
            FakeMigrationStore.file("c.mov", encrypted: encrypted),
            FakeMigrationStore.file("Old.txt", encrypted: encrypted, trashed: true)
        ]
    }

    init(
        files: [VaultItem],
        lockMode: LockMode = .password,
        pending: PendingMigration? = nil,
        unlocked: Bool = true,
        uiTestFailFileName: String? = nil
    ) {
        preferences = FakeMigrationPreferences(lockMode: lockMode, pending: pending, log: log)
        store = FakeMigrationStore(items: files, log: log, gate: gate, key: key)
        lock = FakeMigrationLock(preferences: preferences, log: log, gate: gate, key: key, unlocked: unlocked)
        migrator = LiveLockMigrator(
            store: store, lock: lock, preferences: preferences, uiTestFailFileName: uiTestFailFileName)
    }

    /// A fresh migrator over the same persisted state, as after a relaunch.
    @discardableResult
    func relaunch(uiTestFailFileName: String? = nil) -> LiveLockMigrator {
        gate.disarm()
        migrator = LiveLockMigrator(
            store: store, lock: lock, preferences: preferences, uiTestFailFileName: uiTestFailFileName)
        return migrator
    }
}

/// Polls until the condition holds (or about 2.5 seconds pass).
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
