import Foundation
import os

@testable import KoalaTVault

/// A controllable stand-in for `Task.sleep`: every sleep suspends until `advance()` (or cancellation).
final class ViewerManualSleeper: Sendable {
    private struct State {
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var cancelled: Set<UUID> = []
        var durations: [Duration] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The durations of every sleep that began and was not cancelled before it started, in order.
    var requestedDurations: [Duration] { state.withLock { $0.durations } }

    /// How many sleeps are suspended right now.
    var pendingCount: Int { state.withLock { $0.waiters.count } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyCancelled = state.withLock { state -> Bool in
                    if state.cancelled.contains(id) { return true }
                    state.waiters[id] = continuation
                    state.durations.append(duration)
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
                state.cancelled.insert(id)
                return state.waiters.removeValue(forKey: id)
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Lets every suspended sleep finish normally.
    func advance() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            let all = Array(state.waiters.values)
            state.waiters = [:]
            return all
        }
        for waiter in waiters { waiter.resume() }
    }
}

enum ViewerTestSupport {
    /// Yields (and, rarely, sleeps a millisecond) until `condition` holds or the attempts run out.
    @MainActor
    static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<3000 {
            if condition() { return }
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Gives pending main-actor work a chance to run, for asserting that something did NOT happen.
    @MainActor
    static func settle() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    static func makeItem(
        _ name: String, isDirectory: Bool = false, isEncrypted: Bool = false
    ) -> VaultItem {
        let root = URL(fileURLWithPath: "/tmp/ViewerTestsRoot", isDirectory: true)
        return VaultItem(
            id: name, name: name, isDirectory: isDirectory, dateModified: Date(), fileSize: isDirectory ? nil : 1,
            deletedAt: nil, diskURL: root.appendingPathComponent(name, isDirectory: isDirectory), rootURL: root,
            isEncrypted: isEncrypted)
    }
}

/// A `VaultStoring` that forwards everything to a `MockVaultStoring`, except that the first `write`
/// suspends until `releaseFirstWrite()` and every write's data is recorded, in the order it reaches the mock.
final class ViewerGatedStore: VaultStoring {
    private struct State {
        var writeCalls = 0
        var gatedCall = 1
        var firstWriteWaiter: CheckedContinuation<Void, Never>?
        var firstWriteReleased = false
        var storedWrites: [Data] = []
    }

    let inner: MockVaultStoring
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(inner: MockVaultStoring) {
        self.inner = inner
    }

    var root: VaultDirectory { inner.root }

    // feature multiple-vaults-duress-password: signature updated
    var isEncrypted: Bool { inner.isEncrypted }

    /// How many writes have been requested, including the one waiting at the gate.
    var writeCallCount: Int { state.withLock { $0.writeCalls } }

    /// The data of each write that reached the mock, in order.
    var storedWrites: [Data] { state.withLock { $0.storedWrites } }

    func releaseFirstWrite() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.firstWriteReleased = true
            defer { state.firstWriteWaiter = nil }
            return state.firstWriteWaiter
        }
        waiter?.resume()
    }

    /// Holds the next write that has not been requested yet at the gate, like the first one.
    func holdNextWrite() {
        state.withLock { state in
            state.gatedCall = state.writeCalls + 1
            state.firstWriteReleased = false
            state.firstWriteWaiter = nil
        }
    }

    func write(_ data: Data, to item: VaultItem) async throws {
        let isFirst = state.withLock { state -> Bool in
            state.writeCalls += 1
            return state.writeCalls == state.gatedCall
        }
        if isFirst {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyReleased = state.withLock { state -> Bool in
                    if state.firstWriteReleased { return true }
                    state.firstWriteWaiter = continuation
                    return false
                }
                if alreadyReleased { continuation.resume() }
            }
        }
        try await inner.write(data, to: item)
        state.withLock { $0.storedWrites.append(data) }
    }

    func contents(
        of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection
    ) async throws -> [VaultItem] {
        try await inner.contents(of: directory, sortedBy: option, direction)
    }

    func open(_ item: VaultItem) async throws -> URL { try await inner.open(item) }

    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await inner.createFolder(named: name, in: directory)
    }

    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await inner.createDocument(named: name, in: directory)
    }

    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem {
        try await inner.addFile(from: source, named: name, to: directory)
    }

    // feature multiple-vaults-duress-password: addFiles requirement added (large-folder import)
    func addFiles(_ files: [VaultFileToAdd], to directory: VaultDirectory) async throws -> [VaultItem] {
        try await inner.addFiles(files, to: directory)
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

    func moveToTrash(_ item: VaultItem) async throws { try await inner.moveToTrash(item) }
    // feature multiple-vaults-duress-password: batch moveToTrash requirement added (large trash)
    func moveToTrash(_ items: [VaultItem]) async -> [VaultItem.ID: VaultStoreError] { await inner.moveToTrash(items) }

    // feature multiple-vaults-duress-password: signature updated
    func remove(_ item: VaultItem) async throws { try await inner.remove(item) }

    func trashContents() async throws -> [VaultItem] { try await inner.trashContents() }

    func restore(_ trashed: VaultItem) async throws -> VaultItem { try await inner.restore(trashed) }

    func deletePermanently(_ trashed: VaultItem) async throws { try await inner.deletePermanently(trashed) }

    func emptyTrash() async { await inner.emptyTrash() }

    func purgeExpiredTrash(now: Date) async throws -> Int { try await inner.purgeExpiredTrash(now: now) }

    func hasUnreadableTrash() async -> Bool { await inner.hasUnreadableTrash() }

    func clearUnreadableTrash() async throws { try await inner.clearUnreadableTrash() }

    func countFiles() async throws -> Int { try await inner.countFiles() }

    // feature multiple-vaults-duress-password: signature updated
    func itemsToEncrypt() async throws -> [VaultItem] { try await inner.itemsToEncrypt() }

    func migrateToEncrypted(_ item: VaultItem) async throws { try await inner.migrateToEncrypted(item) }

    func finishEncryption() async throws { try await inner.finishEncryption() }

    func hasUnencryptedFiles() async throws -> Bool { try await inner.hasUnencryptedFiles() }

    func keyMatchesVault() async -> Bool { await inner.keyMatchesVault() }

    func sweepOrphans() async { await inner.sweepOrphans() }

    func makeTempDirectory() throws -> URL { try inner.makeTempDirectory() }

    func removeTemporary(_ url: URL) { inner.removeTemporary(url) }

    func removeAllTemporaryFiles() { inner.removeAllTemporaryFiles() }
}
