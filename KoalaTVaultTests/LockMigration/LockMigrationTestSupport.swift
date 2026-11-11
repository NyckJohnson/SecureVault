import Foundation
import os

@testable import KoalaTVault

// Test doubles shared by the LockMigration tests (feature multiple-vaults-duress-password: the migrator only
// encrypts an opened vault's leftover plaintext files, through the store it is handed).

/// An ordered, thread-safe list of what the store was asked to do.
final class MigrationEventLog: Sendable {
    private let storage = OSAllocatedUnfairLock<[String]>(initialState: [])

    var events: [String] { storage.withLock { $0 } }

    func add(_ event: String) {
        storage.withLock { $0.append(event) }
    }

    func count(of event: String) -> Int {
        events.filter { $0 == event }.count
    }

    func events(withPrefix prefix: String) -> [String] {
        events.filter { $0.hasPrefix(prefix) }
    }
}

/// Holds a store call at a named point until released.
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

/// A vault of files that encrypt in memory; records every step in the log.
final class FakeLeftoverStore: VaultStoring {
    private struct State {
        var items: [VaultItem]
        var failing: [String: VaultStoreError] = [:]
        var listingFailure: VaultStoreError?
        var finishFailure: VaultStoreError?
        var clearFailure: VaultStoreError?
        var unreadableTrash = false
    }

    let root = VaultDirectory(
        name: "KoalaTVault",
        diskURL: URL(fileURLWithPath: "/fake-vault", isDirectory: true),
        rootURL: URL(fileURLWithPath: "/fake-vault", isDirectory: true))
    let isEncrypted: Bool
    private let state: OSAllocatedUnfairLock<State>
    let log: MigrationEventLog
    let gate: MigrationGate

    init(items: [VaultItem], isEncrypted: Bool = true, log: MigrationEventLog, gate: MigrationGate) {
        state = OSAllocatedUnfairLock(initialState: State(items: items))
        self.isEncrypted = isEncrypted
        self.log = log
        self.gate = gate
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

    // swiftlint:disable:next discouraged_optional_boolean
    func isEncrypted(_ name: String) -> Bool? {
        items.first { $0.name == name }?.isEncrypted
    }

    /// The named file keeps failing with this error until cleared.
    func setFailure(_ error: VaultStoreError?, for name: String) {
        state.withLock { $0.failing[name] = error }
    }

    /// `itemsToEncrypt()` keeps failing with this error until cleared.
    func setListingFailure(_ error: VaultStoreError?) {
        state.withLock { $0.listingFailure = error }
    }

    /// `finishEncryption()` keeps failing with this error until cleared.
    func setFinishFailure(_ error: VaultStoreError?) {
        state.withLock { $0.finishFailure = error }
    }

    /// `clearUnreadableTrash()` fails with this error (leaving the trash unreadable) until cleared.
    func setClearFailure(_ error: VaultStoreError?) {
        state.withLock { $0.clearFailure = error }
    }

    /// What `hasUnreadableTrash()` answers; a successful `clearUnreadableTrash()` resets it to false.
    var unreadableTrash: Bool {
        get { state.withLock { $0.unreadableTrash } }
        set { state.withLock { $0.unreadableTrash = newValue } }
    }

    func itemsToEncrypt() async throws -> [VaultItem] {
        log.add("list")
        if let error = state.withLock({ $0.listingFailure }) { throw error }
        return items.filter { !$0.isDirectory && !$0.isEncrypted }
    }

    func migrateToEncrypted(_ item: VaultItem) async throws {
        log.add("enc:\(item.name)")
        await gate.pass("migrate:\(item.name)")
        if let error = state.withLock({ $0.failing[item.name] }) { throw error }
        try state.withLock { state in
            guard let index = state.items.firstIndex(where: { $0.id == item.id }) else {
                throw VaultStoreError.notFound
            }
            let old = state.items[index]
            state.items[index] = VaultItem(
                id: old.id, name: old.name, isDirectory: old.isDirectory, dateModified: old.dateModified,
                fileSize: old.fileSize, deletedAt: old.deletedAt, diskURL: old.diskURL, rootURL: old.rootURL,
                isEncrypted: true)
        }
        log.add("enc-done:\(item.name)")
    }

    func finishEncryption() async throws {
        log.add("finishEncryption")
        await gate.pass("finishEncryption")
        if let error = state.withLock({ $0.finishFailure }) { throw error }
    }

    func hasUnreadableTrash() async -> Bool {
        log.add("hasUnreadableTrash")
        return state.withLock { $0.unreadableTrash }
    }

    func clearUnreadableTrash() async throws {
        log.add("clearUnreadableTrash")
        if let error = state.withLock({ $0.clearFailure }) { throw error }
        state.withLock { $0.unreadableTrash = false }
    }

    // The rest of the store is not used by the migrator.

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
    func remove(_ item: VaultItem) async throws {}
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

/// Records every phase a migrator publishes after it was created.
@MainActor
final class MigrationPhaseRecorder {
    private(set) var phases: [MigrationPhase] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<MigrationPhase>) {
        task = Task { [weak self] in
            for await phase in stream { self?.phases.append(phase) }
        }
    }

    /// Waits until the last recorded phase satisfies the condition.
    @discardableResult
    func wait(until condition: @escaping @MainActor (MigrationPhase) -> Bool) async -> Bool {
        await waitForCondition { [self] in phases.last.map(condition) ?? false }
    }

    /// Gives published phases time to arrive, then stops recording.
    func finish() async {
        try? await Task.sleep(for: .milliseconds(50))
        task?.cancel()
    }

    var runningCount: Int {
        phases.filter {
            if case .running = $0 { return true }
            return false
        }.count
    }
}

/// A migrator over a fake encrypted vault, with its log and gate.
@MainActor
final class MigrationHarness {
    let log = MigrationEventLog()
    let gate = MigrationGate()
    let store: FakeLeftoverStore
    let migrator: LiveLockMigrator

    /// The default vault: three files and one trashed file, in this listing order.
    static let names = ["a.jpg", "b.pdf", "c.mov", "Old.txt"]

    static func plaintextFiles() -> [VaultItem] {
        [
            FakeLeftoverStore.file("a.jpg", encrypted: false),
            FakeLeftoverStore.file("b.pdf", encrypted: false),
            FakeLeftoverStore.file("c.mov", encrypted: false),
            FakeLeftoverStore.file("Old.txt", encrypted: false, trashed: true),
        ]
    }

    /// Assumes `LiveLockMigrator.init(uiTestFailFileName: String? = nil)` (no store: `encryptLeftovers(in:)` gets it;
    /// no VaultLock or Preferences). `uiTestFailFileName` is `UITEST_FAIL_MIGRATION_FILE`, set in UI-test mode only.
    init(
        files: [VaultItem] = MigrationHarness.plaintextFiles(), storeIsEncrypted: Bool = true,
        uiTestFailFileName: String? = nil
    ) {
        store = FakeLeftoverStore(items: files, isEncrypted: storeIsEncrypted, log: log, gate: gate)
        migrator = LiveLockMigrator(uiTestFailFileName: uiTestFailFileName)
    }

    func recorder() -> MigrationPhaseRecorder {
        MigrationPhaseRecorder(migrator.phaseUpdates())
    }

    func run() async {
        await migrator.encryptLeftovers(in: store)
    }
}

/// Polls until the condition holds (or about 2.5 seconds pass).
@MainActor
func waitForCondition(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

func isFinalMigrationPhase(_ phase: MigrationPhase) -> Bool {
    switch phase {
    case .completed, .failed, .unreadableTrash, .idle: true
    case .running: false
    }
}
