import Foundation
import Testing

@testable import KoalaTVault

@MainActor
final class FileBrowserRecorder {
    var routes: [FileBrowserViewModel.Route] = []
    var shared: [[URL]] = []
    var pickerRequests: [[String]] = []
    /// One entry per vault picker request: true for Move to Vault, false for Copy to Vault.
    var vaultPickerRequests: [Bool] = []
    /// Every progress report; nil when the transfer ends.
    var progress: [FileBrowserViewModel.TransferProgress?] = []
    var needsProCount = 0
}

struct FileBrowserRig {
    let viewModel: FileBrowserViewModel
    let store: MockVaultStoring
    let preferences: MockPreferencesStoring
    let exporter: MockVaultExporting
    let alerts: MockAlertPresenting
    let recorder: FileBrowserRecorder
    let lock: MockVaultLocking
    let transfer: MockVaultTransferring
}

/// Shared rig-building helpers for the FileBrowserViewModel suites.
@MainActor
protocol FileBrowserTestSupport {}

extension FileBrowserTestSupport {
    func makeRig(
        inFolder folderName: String? = nil,
        encryptedStore: Bool = false,
        vaultName: String = "KoalaTVault",
        withSampleContent: Bool = true,
        transfer transferOverride: (any VaultTransferring)? = nil
    ) throws -> FileBrowserRig {
        let store = MockVaultStoring(
            withSampleContent: withSampleContent, name: vaultName, isEncrypted: encryptedStore)
        let directory: VaultDirectory
        if let folderName {
            let folder = try #require(store.allItems.first { $0.name == folderName && $0.isDirectory })
            directory = try #require(folder.asDirectory)
        } else {
            directory = store.root
        }
        let preferences = MockPreferencesStoring()
        let exporter = MockVaultExporting()
        let alerts = MockAlertPresenting()
        let recorder = FileBrowserRecorder()
        let lock = MockVaultLocking()
        let transfer = MockVaultTransferring()
        let viewModel = FileBrowserViewModel(
            directory: directory, store: store, preferences: preferences, exporter: exporter, alerts: alerts,
            lock: lock, transfer: transferOverride ?? transfer)
        viewModel.onRoute = { recorder.routes.append($0) }
        viewModel.onShare = { recorder.shared.append($0.urls) }
        viewModel.onPresentPicker = { recorder.pickerRequests.append($0.map(\.id)) }
        viewModel.onPresentVaultPicker = { recorder.vaultPickerRequests.append($0) }
        viewModel.onTransferProgress = { recorder.progress.append($0) }
        viewModel.onNeedsPro = { recorder.needsProCount += 1 }
        return FileBrowserRig(
            viewModel: viewModel, store: store, preferences: preferences, exporter: exporter, alerts: alerts,
            recorder: recorder, lock: lock, transfer: transfer)
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

/// A transfer that reports 2 of N, then waits until the test releases it.
final class HeldTransfer: VaultTransferring, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var callCount = 0

    var calls: Int { lock.withLock { callCount } }
    var isWaiting: Bool { lock.withLock { continuation != nil } }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }

    func transfer(
        _ items: [VaultItem], from source: any VaultStoring, to target: any VaultStoring,
        removingOriginals: Bool, progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TransferResult {
        lock.withLock { callCount += 1 }
        progress(2, items.count)
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
        return TransferResult(done: items.count, failed: 0)
    }
}

/// A store that forwards to a `MockVaultStoring` and can hold calls until the test releases them.
final class GatedVaultStore: VaultStoring, @unchecked Sendable {
    enum HeldCall { case firstContents, firstBatchMoveToTrash }

    let inner: MockVaultStoring
    private let lock = NSLock()
    private let held: HeldCall?
    /// When true, `move` and `copy` throw `CancellationError` (and are counted in `moveCopyCalls`).
    private let cancellingMoveAndCopy: Bool
    private var moveCopyCount = 0
    private var contentsCalls = 0
    private var batchTrashCalls = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ inner: MockVaultStoring, holding held: HeldCall? = nil, cancellingMoveAndCopy: Bool = false) {
        self.inner = inner
        self.held = held
        self.cancellingMoveAndCopy = cancellingMoveAndCopy
    }

    var moveCopyCalls: Int { lock.withLock { moveCopyCount } }

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

    func moveToTrash(_ item: VaultItem) async throws { try await inner.moveToTrash(item) }

    // feature multiple-vaults-duress-password: batch moveToTrash requirement added (large trash)
    func moveToTrash(_ items: [VaultItem]) async -> [VaultItem.ID: VaultStoreError] {
        let number = lock.withLock { () -> Int in
            batchTrashCalls += 1
            return batchTrashCalls
        }
        if held == .firstBatchMoveToTrash, number == 1 { await hold() }
        return await inner.moveToTrash(items)
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
    // feature multiple-vaults-duress-password: addFiles requirement added (large-folder import)
    func addFiles(_ files: [VaultFileToAdd], to directory: VaultDirectory) async throws -> [VaultItem] {
        try await inner.addFiles(files, to: directory)
    }
    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem? {
        try await inner.findItem(named: name, in: directory)
    }
    func move(_ item: VaultItem, to directory: VaultDirectory) async throws {
        lock.withLock { moveCopyCount += 1 }
        if cancellingMoveAndCopy { throw CancellationError() }
        try await inner.move(item, to: directory)
    }
    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem {
        lock.withLock { moveCopyCount += 1 }
        if cancellingMoveAndCopy { throw CancellationError() }
        return try await inner.copy(item, to: directory)
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
