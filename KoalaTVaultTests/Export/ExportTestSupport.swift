import Foundation

@testable import KoalaTVault

/// A vault store keeping real files on disk under unique temporary folders, for export tests.
/// Encrypted items sit under UUID disk names (folders also hold a `.vault_map`); `open` hands out a
/// decrypted copy, under its display name, in a fresh folder of the store's temp area.
final class ExportTestStore: VaultStoring, @unchecked Sendable {
    let root: VaultDirectory
    // feature multiple-vaults-duress-password: signature updated
    var isEncrypted: Bool { false }  // nothing in Export reads it
    /// Where `makeTempDirectory` folders live.
    let tempArea: URL

    private let lock = NSLock()
    private var children: [String: [VaultItem]] = [:]
    private var plaintexts: [String: String] = [:]
    private var failingNames: Set<String> = []
    private var vaultLocked = false
    private var afterOpenHook: (@Sendable (String) -> Void)?

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ExportTests-\(UUID().uuidString)", isDirectory: true)
        let rootURL = base.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        root = VaultDirectory(name: "KoalaTVault", diskURL: rootURL, rootURL: rootURL)
        tempArea = base.appendingPathComponent("temp", isDirectory: true)
    }

    // MARK: Test controls

    /// Adds a file to `parent` (the root by default); encrypted files get a UUID disk name.
    @discardableResult
    func seedFile(
        _ name: String, content: String = "content", encrypted: Bool = false, in parent: VaultItem? = nil
    ) throws -> VaultItem {
        let parentURL = parent?.diskURL ?? root.diskURL
        let diskName = encrypted ? UUID().uuidString : name
        let url = parentURL.appendingPathComponent(diskName)
        try Data((encrypted ? "CIPHERTEXT" : content).utf8).write(to: url)
        let item = makeItem(name: name, url: url, isDirectory: false, encrypted: encrypted)
        lock.withLock {
            plaintexts[url.path] = content
            children[parentURL.path, default: []].append(item)
        }
        return item
    }

    /// Adds a folder to `parent` (the root by default); encrypted folders get a UUID disk name and a `.vault_map`.
    @discardableResult
    func seedFolder(_ name: String, encrypted: Bool = false, in parent: VaultItem? = nil) throws -> VaultItem {
        let parentURL = parent?.diskURL ?? root.diskURL
        let url = parentURL.appendingPathComponent(encrypted ? UUID().uuidString : name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if encrypted { try Data("MAP".utf8).write(to: url.appendingPathComponent(".vault_map")) }
        let item = makeItem(name: name, url: url, isDirectory: true, encrypted: encrypted)
        lock.withLock { children[parentURL.path, default: []].append(item) }
        return item
    }

    /// `open` throws `.io("boom")` for items with this display name.
    func failOpening(_ name: String) { lock.withLock { _ = failingNames.insert(name) } }

    /// `open` throws `.locked` for encrypted items, as when the key is gone.
    func lockVault() { lock.withLock { vaultLocked = true } }

    /// Runs `hook` with the item's display name each time `open` has finished decrypting an item.
    func onOpened(_ hook: @escaping @Sendable (String) -> Void) { lock.withLock { afterOpenHook = hook } }

    /// Whatever sits beside the vault and the temp area (in their shared parent), as relative paths.
    func strayEntries() -> [String] {
        let base = root.diskURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { $0 != root.diskURL.lastPathComponent && $0 != tempArea.lastPathComponent }.sorted()
    }

    /// The names directly inside the temp area.
    func topLevelTempEntries() -> [String] { tempEntries().filter { !$0.contains("/") } }

    /// Every file and folder left under the temp area, as paths relative to it.
    func tempEntries() -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: tempArea.path) else { return [] }
        return walker.compactMap { $0 as? String }.sorted()
    }

    /// Relative path to content of every regular file under `url`, or the file itself under its name.
    func filesUnder(_ url: URL) -> [String: String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [:] }
        guard isDirectory.boolValue else { return [url.lastPathComponent: readString(url) ?? ""] }
        var result: [String: String] = [:]
        let walker = FileManager.default.enumerator(atPath: url.path)
        while let relative = walker?.nextObject() as? String {
            let file = url.appendingPathComponent(relative)
            var childIsDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: file.path, isDirectory: &childIsDirectory)
            if !childIsDirectory.boolValue { result[relative] = readString(file) ?? "" }
        }
        return result
    }

    /// Every path (files and folders) under `url`, relative to it.
    func pathsUnder(_ url: URL) -> [String] {
        (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String]) ?? []
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.diskURL.deletingLastPathComponent())
    }

    // MARK: VaultStoring (used by exports)

    func contents(
        of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection
    ) async throws -> [VaultItem] {
        lock.withLock { children[directory.diskURL.path] ?? [] }
    }

    func open(_ item: VaultItem) async throws -> URL {
        if lock.withLock({ vaultLocked }), item.isEncrypted { throw VaultStoreError.locked }
        if lock.withLock({ failingNames.contains(item.name) }) { throw VaultStoreError.io("boom") }
        guard item.isEncrypted, !item.isDirectory else { return item.diskURL }
        let folder = try makeTempDirectory()
        // A crafted display name must not steer where the store itself writes.
        let craftedName = item.name.isEmpty || item.name.hasPrefix(".") || item.name.contains("/")
        let copy = folder.appendingPathComponent(craftedName ? "decrypted-\(UUID().uuidString)" : item.name)
        let text = lock.withLock { plaintexts[item.diskURL.path] } ?? ""
        try Data(text.utf8).write(to: copy)
        lock.withLock { afterOpenHook }?(item.name)
        return copy
    }

    func makeTempDirectory() throws -> URL {
        let url = tempArea.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw VaultStoreError.io(error.localizedDescription)
        }
        return url
    }

    /// Deletes whatever it is told to, so a test notices an export removing something it must not.
    func removeTemporary(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func removeAllTemporaryFiles() {}

    // MARK: VaultStoring (unused by exports)

    func write(_ data: Data, to item: VaultItem) async throws { throw unsupported }
    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        throw unsupported
    }
    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        throw unsupported
    }
    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem {
        throw unsupported
    }
    // feature multiple-vaults-duress-password: addFiles requirement added (large-folder import)
    func addFiles(_ files: [VaultFileToAdd], to directory: VaultDirectory) async throws -> [VaultItem] {
        throw unsupported
    }
    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem? { throw unsupported }
    func move(_ item: VaultItem, to directory: VaultDirectory) async throws { throw unsupported }
    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem { throw unsupported }
    func rename(_ item: VaultItem, to name: String) async throws -> VaultItem { throw unsupported }
    func moveToTrash(_ item: VaultItem) async throws { throw unsupported }
    // feature multiple-vaults-duress-password: batch moveToTrash requirement added (large trash)
    func moveToTrash(_ items: [VaultItem]) async -> [VaultItem.ID: VaultStoreError] {
        Dictionary(items.map { ($0.id, unsupported) }, uniquingKeysWith: { first, _ in first })
    }
    // feature multiple-vaults-duress-password: signature updated
    func remove(_ item: VaultItem) async throws { throw unsupported }
    func trashContents() async throws -> [VaultItem] { throw unsupported }
    func restore(_ trashed: VaultItem) async throws -> VaultItem { throw unsupported }
    func deletePermanently(_ trashed: VaultItem) async throws { throw unsupported }
    func emptyTrash() async {}
    func purgeExpiredTrash(now: Date) async throws -> Int { throw unsupported }
    func hasUnreadableTrash() async -> Bool { false }
    func clearUnreadableTrash() async throws { throw unsupported }
    func countFiles() async throws -> Int { throw unsupported }
    // feature multiple-vaults-duress-password: signature updated
    func itemsToEncrypt() async throws -> [VaultItem] { throw unsupported }
    func migrateToEncrypted(_ item: VaultItem) async throws { throw unsupported }
    func finishEncryption() async throws { throw unsupported }
    func hasUnencryptedFiles() async throws -> Bool { throw unsupported }
    func keyMatchesVault() async -> Bool { true }
    func sweepOrphans() async {}

    // MARK: Helpers

    private var unsupported: VaultStoreError { .io("unsupported") }

    private func readString(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func makeItem(name: String, url: URL, isDirectory: Bool, encrypted: Bool) -> VaultItem {
        let rootPath = root.diskURL.standardizedFileURL.path
        let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count).drop { $0 == "/" })
        return VaultItem(
            id: relative, name: name, isDirectory: isDirectory, dateModified: Date(),
            fileSize: isDirectory ? nil : 1, deletedAt: nil, diskURL: url, rootURL: root.rootURL,
            isEncrypted: encrypted)
    }
}

/// A photo library double recording what it was asked to save.
final class FakePhotoLibrary: PhotoLibraryAdding, @unchecked Sendable {
    struct SavedMedia: Equatable, Sendable {
        var fileName: String
        var isVideo: Bool
        /// The file's text when it was saved; nil if the file did not exist.
        var content: String?
    }

    private let lock = NSLock()
    private var granted: Bool
    private var failingFileNames: Set<String> = []
    private var cancellingFileNames: Set<String> = []
    private var cancelTaskFileNames: Set<String> = []
    private var _saved: [SavedMedia] = []
    private var _accessRequests = 0

    init(accessGranted: Bool = true) { granted = accessGranted }

    var saved: [SavedMedia] { lock.withLock { _saved } }
    var accessRequests: Int { lock.withLock { _accessRequests } }

    /// Saving a file with this name throws.
    func failSaving(_ fileName: String) { lock.withLock { _ = failingFileNames.insert(fileName) } }

    /// Saving a file with this name throws `CancellationError`, as the system library may.
    func throwCancellationWhenSaving(_ fileName: String) { lock.withLock { _ = cancellingFileNames.insert(fileName) } }

    /// Saving a file with this name cancels the task that is saving it, then succeeds.
    func cancelTaskWhenSaving(_ fileName: String) { lock.withLock { _ = cancelTaskFileNames.insert(fileName) } }

    func requestAddOnlyAccess() async -> Bool {
        lock.withLock {
            _accessRequests += 1
            return granted
        }
    }

    func saveMedia(at url: URL, isVideo: Bool) async throws {
        let content = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
        let name = url.lastPathComponent
        let shouldFail = lock.withLock {
            _saved.append(SavedMedia(fileName: name, isVideo: isVideo, content: content))
            return failingFileNames.contains(name)
        }
        if lock.withLock({ cancellingFileNames.contains(name) }) { throw CancellationError() }
        if lock.withLock({ cancelTaskFileNames.contains(name) }) { cancelCurrentTask() }
        if shouldFail { throw FakePhotoLibraryError.rejected }
    }
}

enum FakePhotoLibraryError: Error, Equatable { case rejected }

/// Cancels the task the caller is running in.
func cancelCurrentTask() {
    withUnsafeCurrentTask { $0?.cancel() }
}
