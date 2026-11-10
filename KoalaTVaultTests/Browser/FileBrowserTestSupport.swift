import Foundation
import Testing

@testable import KoalaTVault

@MainActor
final class FileBrowserRecorder {
    var routes: [FileBrowserViewModel.Route] = []
    var shared: [[URL]] = []
    var pickerRequests: [[String]] = []
}

struct FileBrowserRig {
    let viewModel: FileBrowserViewModel
    let store: MockVaultStoring
    let preferences: MockPreferencesStoring
    let exporter: MockVaultExporting
    let alerts: MockAlertPresenting
    let recorder: FileBrowserRecorder
}

/// Shared rig-building helpers for the FileBrowserViewModel suites.
@MainActor
protocol FileBrowserTestSupport {}

extension FileBrowserTestSupport {
    func makeRig(
        inFolder folderName: String? = nil,
        lockMode: LockMode = .none,
        pendingMigration: PendingMigration? = nil,
        withSampleContent: Bool = true
    ) throws -> FileBrowserRig {
        let store = MockVaultStoring(withSampleContent: withSampleContent)
        let directory: VaultDirectory
        if let folderName {
            let folder = try #require(store.allItems.first { $0.name == folderName && $0.isDirectory })
            directory = try #require(folder.asDirectory)
        } else {
            directory = store.root
        }
        let preferences = MockPreferencesStoring(lockMode: lockMode, pendingMigration: pendingMigration)
        let exporter = MockVaultExporting()
        let alerts = MockAlertPresenting()
        let recorder = FileBrowserRecorder()
        let viewModel = FileBrowserViewModel(
            directory: directory, store: store, preferences: preferences, exporter: exporter, alerts: alerts)
        viewModel.onRoute = { recorder.routes.append($0) }
        viewModel.onShare = { recorder.shared.append($0.urls) }
        viewModel.onPresentPicker = { recorder.pickerRequests.append($0.map(\.id)) }
        return FileBrowserRig(
            viewModel: viewModel, store: store, preferences: preferences, exporter: exporter, alerts: alerts,
            recorder: recorder)
    }

    func item(_ name: String, in store: MockVaultStoring) throws -> VaultItem {
        try #require(store.allItems.first { $0.name == name })
    }

    /// An item the store doesn't hold, so store calls on it throw `notFound`.
    func ghost(_ name: String, store: MockVaultStoring, encrypted: Bool = false) -> VaultItem {
        VaultItem(
            id: "ghost/\(name)", name: name, isDirectory: false, dateModified: Date(), fileSize: 1,
            deletedAt: nil, diskURL: store.root.diskURL.appendingPathComponent("ghost/\(name)"),
            rootURL: store.root.rootURL, isEncrypted: encrypted)
    }

    func errorMessages(_ alerts: MockAlertPresenting) -> [String] {
        alerts.alerts.compactMap { alert in
            if case .error(let message) = alert { return message }
            return nil
        }
    }
}

/// A store that forwards to a `MockVaultStoring` and can hold calls until the test releases them.
final class GatedVaultStore: VaultStoring, @unchecked Sendable {
    enum HeldCall { case firstContents, firstMoveToTrash }

    let inner: MockVaultStoring
    private let lock = NSLock()
    private let held: HeldCall?
    private let cancelAfterHold: Bool
    private var contentsCalls = 0
    private var trashCalls = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ inner: MockVaultStoring, holding held: HeldCall? = nil, cancelAfterHold: Bool = false) {
        self.inner = inner
        self.held = held
        self.cancelAfterHold = cancelAfterHold
    }

    var waitingCount: Int { lock.withLock { waiting.count } }

    func releaseAll() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiting = [] }
            return waiting
        }
        pending.forEach { $0.resume() }
    }

    private func hold() async {
        await withCheckedContinuation { continuation in
            lock.withLock { waiting.append(continuation) }
        }
    }

    var root: VaultDirectory { inner.root }
    // feature multiple-vaults-duress-password: signature updated
    var isEncrypted: Bool { inner.isEncrypted }

    func contents(
        of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection
    ) async throws -> [VaultItem] {
        let number = lock.withLock { () -> Int in
            contentsCalls += 1
            return contentsCalls
        }
        let result = try await inner.contents(of: directory, sortedBy: option, direction)
        if held == .firstContents, number == 1 { await hold() }
        return result
    }

    func moveToTrash(_ item: VaultItem) async throws {
        let number = lock.withLock { () -> Int in
            trashCalls += 1
            return trashCalls
        }
        if held == .firstMoveToTrash, number == 1 {
            await hold()
            if cancelAfterHold { throw CancellationError() }
        }
        try await inner.moveToTrash(item)
    }

    func open(_ item: VaultItem) async throws -> URL { try await inner.open(item) }
    func write(_ data: Data, to item: VaultItem) async throws { try await inner.write(data, to: item) }
    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await inner.createFolder(named: name, in: directory)
    }
    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try await inner.createDocument(named: name, in: directory)
    }
    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem {
        try await inner.addFile(from: source, named: name, to: directory)
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
