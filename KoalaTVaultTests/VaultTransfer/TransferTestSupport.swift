import Foundation
import os

@testable import KoalaTVault

/// A shared, ordered log of the calls the two test stores of one transfer receive.
final class TransferEventLog: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    var events: [String] { lines.withLock { $0 } }

    func append(_ line: String) { lines.withLock { $0.append(line) } }

    /// Index of the first event equal to `event`, if any.
    func index(of event: String) -> Int? { events.firstIndex(of: event) }
}

/// Thread-safe list of the `progress(done, total)` callbacks received.
final class TransferProgressRecorder: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [[Int]]())

    var calls: [[Int]] { values.withLock { $0 } }

    var callback: @Sendable (Int, Int) -> Void {
        { [self] done, total in values.withLock { $0.append([done, total]) } }
    }
}

/// A vault store that wraps `MockVaultStoring`, logs the calls a transfer cares about into a shared log, and
/// can be told to fail chosen calls or to run a hook after each `addFile`.
final class TransferTestStore: VaultStoring {
    let inner: MockVaultStoring
    private let label: String
    private let log: TransferEventLog
    private let failures = OSAllocatedUnfairLock(initialState: Failures())
    private let addFileHook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    private struct Failures: Sendable {
        var open: Set<String> = []
        var addFile: Set<String> = []
        var remove: Set<String> = []
    }

    init(label: String, log: TransferEventLog, name: String, withSampleContent: Bool, isEncrypted: Bool = false) {
        self.label = label
        self.log = log
        inner = MockVaultStoring(withSampleContent: withSampleContent, name: name, isEncrypted: isEncrypted)
    }

    /// Ids of items whose `open` throws.
    func failOpen(_ ids: Set<String>) { failures.withLock { $0.open = ids } }
    /// Names whose `addFile` throws.
    func failAddFile(_ names: Set<String>) { failures.withLock { $0.addFile = names } }
    /// Ids of items whose `remove` throws.
    func failRemove(_ ids: Set<String>) { failures.withLock { $0.remove = ids } }
    /// Runs `hook` after every successful `addFile`.
    func afterAddFile(_ hook: @escaping @Sendable () -> Void) { addFileHook.withLock { $0 = hook } }

    /// The item with this id, if the store holds it.
    func item(_ id: String) -> VaultItem? { inner.allItems.first { $0.id == id } }

    /// Ids of every item in the store.
    var itemIDs: Set<String> { Set(inner.allItems.map(\.id)) }

    /// Adds `count` plain files to the root.
    func fill(_ count: Int) async throws {
        for index in 0..<count {
            _ = try await inner.addFile(
                from: URL(fileURLWithPath: "/dev/null"), named: "filler \(index).txt", to: inner.root)
        }
    }

    // MARK: - Logged calls

    var root: VaultDirectory { inner.root }
    var isEncrypted: Bool { inner.isEncrypted }

    func open(_ item: VaultItem) async throws -> URL {
        log.append("\(label).open:\(item.id)")
        if failures.withLock({ $0.open.contains(item.id) }) { throw VaultStoreError.io("open failed") }
        return try await inner.open(item)
    }

    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem {
        log.append("\(label).addFile:\(name)")
        if failures.withLock({ $0.addFile.contains(name) }) { throw VaultStoreError.io("addFile failed") }
        let added = try await inner.addFile(from: source, named: name, to: directory)
        addFileHook.withLock { $0 }?()
        return added
    }

    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        log.append("\(label).createFolder:\(name)")
        return try await inner.createFolder(named: name, in: directory)
    }

    func remove(_ item: VaultItem) async throws {
        log.append("\(label).remove:\(item.id)")
        if failures.withLock({ $0.remove.contains(item.id) }) { throw VaultStoreError.io("remove failed") }
        try await inner.remove(item)
    }

    func moveToTrash(_ item: VaultItem) async throws {
        log.append("\(label).moveToTrash:\(item.id)")
        try await inner.moveToTrash(item)
    }

    func removeTemporary(_ url: URL) {
        log.append("\(label).removeTemporary:\(url.path)")
        inner.removeTemporary(url)
    }

    // MARK: - Plain forwarding

    func contents(of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection)
        async throws -> [VaultItem]
    {
        try await inner.contents(of: directory, sortedBy: option, direction)
    }
    func write(_ data: Data, to item: VaultItem) async throws { try await inner.write(data, to: item) }
    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await inner.createDocument(named: name, in: directory)
    }
    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem? {
        try await inner.findItem(named: name, in: directory)
    }
    func move(_ item: VaultItem, to directory: VaultDirectory) async throws {
        try await inner.move(item, to: directory)
    }
    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem {
        try await inner.copy(item, to: directory)
    }
    func rename(_ item: VaultItem, to name: String) async throws -> VaultItem {
        try await inner.rename(item, to: name)
    }
    func trashContents() async throws -> [VaultItem] { try await inner.trashContents() }
    func restore(_ trashed: VaultItem) async throws -> VaultItem { try await inner.restore(trashed) }
    func deletePermanently(_ trashed: VaultItem) async throws { try await inner.deletePermanently(trashed) }
    func emptyTrash() async { await inner.emptyTrash() }
    func purgeExpiredTrash(now: Date) async throws -> Int { try await inner.purgeExpiredTrash(now: now) }
    func hasUnreadableTrash() async -> Bool { await inner.hasUnreadableTrash() }
    func clearUnreadableTrash() async throws { try await inner.clearUnreadableTrash() }
    func countFiles() async throws -> Int { try await inner.countFiles() }
    func itemsToEncrypt() async throws -> [VaultItem] { try await inner.itemsToEncrypt() }
    func migrateToEncrypted(_ item: VaultItem) async throws { try await inner.migrateToEncrypted(item) }
    func finishEncryption() async throws { try await inner.finishEncryption() }
    func hasUnencryptedFiles() async throws -> Bool { try await inner.hasUnencryptedFiles() }
    func keyMatchesVault() async -> Bool { await inner.keyMatchesVault() }
    func sweepOrphans() async { await inner.sweepOrphans() }
    func makeTempDirectory() throws -> URL { try inner.makeTempDirectory() }
    func removeAllTemporaryFiles() { inner.removeAllTemporaryFiles() }
}

/// A source (with the sample content) and an empty target, sharing one event log.
struct TransferFixture {
    let log = TransferEventLog()
    let source: TransferTestStore
    let target: TransferTestStore

    init(sourceEncrypted: Bool = false, targetEncrypted: Bool = false, targetName: String = "Target") {
        source = TransferTestStore(
            label: "src", log: log, name: "Source", withSampleContent: true, isEncrypted: sourceEncrypted)
        target = TransferTestStore(
            label: "tgt", log: log, name: targetName, withSampleContent: false, isEncrypted: targetEncrypted)
    }
}

/// The live transfer, built with a Pro entitlement that is unlocked or not.
@MainActor
func makeTransfer(pro: Bool) -> LiveVaultTransfer {
    LiveVaultTransfer(pro: MockProUnlocking(isUnlocked: pro))
}
