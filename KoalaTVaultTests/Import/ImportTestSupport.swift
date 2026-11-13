import Foundation
import os

@testable import KoalaTVault

/// A vault store that keeps real files on disk under a unique temporary folder, for import tests.
/// Only the calls an import uses are implemented; the rest throw `.io("unsupported")`.
final class DiskBackedVaultStore: VaultStoring, @unchecked Sendable {
    struct AddCall: Equatable, Sendable {
        var name: String
        var directoryPath: String
    }

    let root: VaultDirectory
    // feature multiple-vaults-duress-password: signature updated
    var isEncrypted: Bool { encrypted }
    /// Files counted by `countFiles()` in addition to those on disk.
    let extraFileCount: Int
    /// Items listed by this store are flagged encrypted and `open` hands out a decrypted temp copy.
    let encrypted: Bool

    private let lock = NSLock()
    private var _addCalls: [AddCall] = []
    private var _failNames: Set<String> = []
    private var _tempDirectories: [URL] = []
    private var _findItemError: (any Error)?
    private var _countFilesError: (any Error)?
    private var _openOverride: URL?
    private var _createFolderReturnsFile = false

    /// The store's temp area: `makeTempDirectory` folders live inside it and `removeTemporary` deletes
    /// only paths strictly inside it, as the real store does.
    let tempArea: URL

    init(extraFileCount: Int = 0, encrypted: Bool = false) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        root = VaultDirectory(name: "KoalaTVault", diskURL: rootURL, rootURL: rootURL)
        tempArea = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportTempArea-\(UUID().uuidString)", isDirectory: true)
        self.extraFileCount = extraFileCount
        self.encrypted = encrypted
    }

    // MARK: Test controls

    var addCalls: [AddCall] { lock.withLock { _addCalls } }

    /// `addFile` throws `.io("boom")` for these names.
    func failAdding(_ name: String) { lock.withLock { _ = _failNames.insert(name) } }

    /// `findItem` throws this error from now on.
    func failFindItem(with error: any Error) { lock.withLock { _findItemError = error } }

    /// `open` hands out this URL for every item from now on.
    func overrideOpen(with url: URL) { lock.withLock { _openOverride = url } }

    /// `createFolder` creates a plain file and returns it, instead of a folder, from now on.
    func makeCreateFolderReturnFile() { lock.withLock { _createFolderReturnsFile = true } }

    /// `countFiles` throws this error from now on.
    func failCountFiles(with error: any Error) { lock.withLock { _countFilesError = error } }

    /// Every regular file left under any temp folder this store handed out.
    var leftoverTempFiles: [URL] {
        let dirs = lock.withLock { _tempDirectories }
        var found: [URL] = []
        for dir in dirs {
            let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = walker?.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { found.append(url) }
            }
        }
        return found
    }

    var tempDirectoriesCreated: Int { lock.withLock { _tempDirectories.count } }

    /// Names (relative paths) of every item on disk under the root, folders marked with a trailing "/".
    func allPaths() -> [String] {
        var result: [String] = []
        let rootPath = root.diskURL.standardizedFileURL.path
        let walker = FileManager.default.enumerator(
            at: root.diskURL, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        while let url = walker?.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            let relative = String(path.dropFirst(rootPath.count).drop { $0 == "/" })
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            result.append(isDir ? relative + "/" : relative)
        }
        return result.sorted()
    }

    func readString(_ relativePath: String) -> String? {
        let url = root.diskURL.appendingPathComponent(relativePath)
        return (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func seed(_ relativePath: String, content: String) throws {
        let url = root.diskURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.diskURL)
        for dir in lock.withLock({ _tempDirectories }) { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.removeItem(at: tempArea)
    }

    // MARK: VaultStoring (used by imports)

    func countFiles() async throws -> Int {
        if let error = lock.withLock({ _countFilesError }) { throw error }
        var count = extraFileCount
        let walker = FileManager.default.enumerator(
            at: root.diskURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
        return count
    }

    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem {
        let shouldFail = lock.withLock {
            _addCalls.append(AddCall(name: name, directoryPath: relativePath(directory.diskURL)))
            return _failNames.contains(name)
        }
        if shouldFail { throw VaultStoreError.io("boom") }
        if name.isEmpty || name.contains("/") { throw VaultStoreError.invalidName }
        let unique = uniqueName(name, in: directory.diskURL)
        let target = directory.diskURL.appendingPathComponent(unique)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            throw VaultStoreError.io(error.localizedDescription)
        }
        return item(at: target)
    }

    // feature multiple-vaults-duress-password: addFiles requirement added (large-folder import)
    /// Adds the files one by one through `addFile` (each recorded in `addCalls`), stopping at the first failure.
    func addFiles(_ files: [VaultFileToAdd], to directory: VaultDirectory) async throws -> [VaultItem] {
        var added: [VaultItem] = []
        for file in files { added.append(try await addFile(from: file.source, named: file.name, to: directory)) }
        return added
    }

    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        if name.isEmpty || name.contains("/") { throw VaultStoreError.invalidName }
        let unique = uniqueName(name, in: directory.diskURL)
        if lock.withLock({ _createFolderReturnsFile }) {
            let fileTarget = directory.diskURL.appendingPathComponent(unique)
            try? Data("file".utf8).write(to: fileTarget)
            return item(at: fileTarget)
        }
        let target = directory.diskURL.appendingPathComponent(unique, isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return item(at: target)
    }

    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem? {
        if let error = lock.withLock({ _findItemError }) { throw error }
        let target = directory.diskURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return item(at: target)
    }

    func contents(
        of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection
    ) async throws -> [VaultItem] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(at: directory.diskURL, includingPropertiesForKeys: nil)) ?? []
        return urls.map { item(at: $0) }.sorted { $0.name < $1.name }
    }

    func open(_ item: VaultItem) async throws -> URL {
        if let override = lock.withLock({ _openOverride }) { return override }
        guard encrypted, !item.isDirectory else { return item.diskURL }
        let dir = try makeTempDirectory()
        let copy = dir.appendingPathComponent(item.name)
        try? FileManager.default.copyItem(at: item.diskURL, to: copy)
        return copy
    }

    func makeTempDirectory() throws -> URL {
        let url = tempArea.appendingPathComponent("ImportTempFolder-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw VaultStoreError.io(error.localizedDescription)
        }
        lock.withLock { _tempDirectories.append(url) }
        return url
    }

    func removeTemporary(_ url: URL) {
        let areaPath = tempArea.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(areaPath + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func removeAllTemporaryFiles() {}

    // MARK: VaultStoring (unused by imports)

    func write(_ data: Data, to item: VaultItem) async throws { throw unsupported }
    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        throw unsupported
    }
    func move(_ item: VaultItem, to directory: VaultDirectory) async throws { throw unsupported }
    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem { throw unsupported }
    func rename(_ item: VaultItem, to name: String) async throws -> VaultItem { throw unsupported }
    func moveToTrash(_ item: VaultItem) async throws { throw unsupported }
    // feature multiple-vaults-duress-password: signature updated
    func remove(_ item: VaultItem) async throws { throw unsupported }
    func trashContents() async throws -> [VaultItem] { throw unsupported }
    func restore(_ trashed: VaultItem) async throws -> VaultItem { throw unsupported }
    func deletePermanently(_ trashed: VaultItem) async throws { throw unsupported }
    func emptyTrash() async {}
    func purgeExpiredTrash(now: Date) async throws -> Int { throw unsupported }
    func hasUnreadableTrash() async -> Bool { false }
    func clearUnreadableTrash() async throws { throw unsupported }
    // feature multiple-vaults-duress-password: signature updated
    func itemsToEncrypt() async throws -> [VaultItem] { throw unsupported }
    func migrateToEncrypted(_ item: VaultItem) async throws { throw unsupported }
    func finishEncryption() async throws { throw unsupported }
    func hasUnencryptedFiles() async throws -> Bool { throw unsupported }
    func keyMatchesVault() async -> Bool { true }
    func sweepOrphans() async {}

    // MARK: Helpers

    private var unsupported: VaultStoreError { .io("unsupported") }

    private func relativePath(_ url: URL) -> String {
        let rootPath = root.diskURL.standardizedFileURL.path
        return String(url.standardizedFileURL.path.dropFirst(rootPath.count).drop { $0 == "/" })
    }

    private func uniqueName(_ name: String, in directory: URL) -> String {
        func taken(_ candidate: String) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        guard taken(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !taken(candidate) { return candidate }
            counter += 1
        }
    }

    private func item(at url: URL) -> VaultItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDir = values?.isDirectory == true
        return VaultItem(
            id: relativePath(url), name: url.lastPathComponent, isDirectory: isDir,
            dateModified: values?.contentModificationDate ?? Date(), fileSize: isDir ? nil : values?.fileSize,
            deletedAt: nil, diskURL: url, rootURL: root.rootURL, isEncrypted: encrypted && !isDir)
    }
}

/// A scratch folder holding files to import, removed by `cleanup()`.
struct SourceFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes a file (creating folders on the way) and returns its URL.
    @discardableResult
    func file(_ relativePath: String, content: String = "content") throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: target)
        return target
    }

    /// Creates an empty folder and returns its URL.
    @discardableResult
    func folder(_ relativePath: String) throws -> URL {
        let target = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// Collects progress values from a `@Sendable` callback.
final class ProgressRecorder: @unchecked Sendable {
    private let values = OSAllocatedUnfairLock<[Double]>(initialState: [])
    var recorded: [Double] { values.withLock { $0 } }
    func record(_ value: Double) { values.withLock { $0.append(value) } }
}

/// Records security-scoped access calls; `refusing` URLs make `start` return false.
final class RecordingScopedAccess: ScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [URL] = []
    private var _stopped: [URL] = []
    private let refusing: Set<String>

    init(refusing: [URL] = []) { self.refusing = Set(refusing.map { $0.standardizedFileURL.path }) }

    var started: [URL] { lock.withLock { _started } }
    var stopped: [URL] { lock.withLock { _stopped } }

    func start(_ url: URL) -> Bool {
        lock.withLock { _started.append(url) }
        return !refusing.contains(url.standardizedFileURL.path)
    }

    func stop(_ url: URL) { lock.withLock { _stopped.append(url) } }

    func startCount(_ url: URL) -> Int {
        let path = url.standardizedFileURL.path
        return started.filter { $0.standardizedFileURL.path == path }.count
    }

    func stopCount(_ url: URL) -> Int {
        let path = url.standardizedFileURL.path
        return stopped.filter { $0.standardizedFileURL.path == path }.count
    }
}
