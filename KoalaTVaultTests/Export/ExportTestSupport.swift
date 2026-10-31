import Foundation

@testable import KoalaTVault

/// A vault store keeping real files on disk under unique temporary folders, for export tests.
/// Encrypted items sit under UUID disk names (folders also hold a `.vault_map`); `open` hands out a
/// decrypted copy, under its display name, in a fresh folder of the store's temp area.
final class ExportTestStore: VaultStoring, @unchecked Sendable {
    let root: VaultDirectory
    /// Where `makeTempDirectory` folders live.
    let tempArea: URL

    private let lock = NSLock()
    private var children: [String: [VaultItem]] = [:]
    private var plaintexts: [String: String] = [:]
    private var failingNames: Set<String> = []

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
        if lock.withLock({ failingNames.contains(item.name) }) { throw VaultStoreError.io("boom") }
        guard item.isEncrypted, !item.isDirectory else { return item.diskURL }
        let folder = try makeTempDirectory()
        let copy = folder.appendingPathComponent(item.name)
        let text = lock.withLock { plaintexts[item.diskURL.path] } ?? ""
        try Data(text.utf8).write(to: copy)
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
    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem? { throw unsupported }
    func move(_ item: VaultItem, to directory: VaultDirectory) async throws { throw unsupported }
    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem { throw unsupported }
    func rename(_ item: VaultItem, to name: String) async throws -> VaultItem { throw unsupported }
    func moveToTrash(_ item: VaultItem) async throws { throw unsupported }
    func trashContents() async throws -> [VaultItem] { throw unsupported }
    func restore(_ trashed: VaultItem) async throws -> VaultItem { throw unsupported }
    func deletePermanently(_ trashed: VaultItem) async throws { throw unsupported }
    func emptyTrash() async {}
    func purgeExpiredTrash(now: Date) async throws -> Int { throw unsupported }
    func countFiles() async throws -> Int { throw unsupported }
    func itemsToMigrate(toEncrypted: Bool) async throws -> [VaultItem] { throw unsupported }
    func migrateToEncrypted(_ item: VaultItem) async throws { throw unsupported }
    func migrateToDecrypted(_ item: VaultItem) async throws { throw unsupported }
    func finishDecryption() async throws { throw unsupported }
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
    private var _saved: [SavedMedia] = []
    private var _accessRequests = 0

    init(accessGranted: Bool = true) { granted = accessGranted }

    var saved: [SavedMedia] { lock.withLock { _saved } }
    var accessRequests: Int { lock.withLock { _accessRequests } }

    /// Saving a file with this name throws.
    func failSaving(_ fileName: String) { lock.withLock { _ = failingFileNames.insert(fileName) } }

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
        if shouldFail { throw FakePhotoLibraryError.rejected }
    }
}

enum FakePhotoLibraryError: Error, Equatable { case rejected }
