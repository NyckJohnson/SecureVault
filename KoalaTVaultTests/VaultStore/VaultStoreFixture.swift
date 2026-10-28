import Foundation

@testable import KoalaTVault

/// Runs `body` and returns the error it throws, or nil when it doesn't throw.
func caught(_ body: () async throws -> Void) async -> (any Error)? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

/// A `LiveVaultStore` over a unique temporary vault, with mock key store, cipher and preferences.
///
/// Expected initializer of the store (the code-writer matches it):
/// `LiveVaultStore(root: URL, keyStore: any MasterKeyStoring, cipher: any FileCipher,
/// preferences: any PreferencesStoring, temporaryRoot: URL)`.
struct VaultStoreFixture {
    /// Prefix the mock cipher puts before data: `mock-sealed:<context>:`.
    static let sealedPrefix = Data("mock-sealed:".utf8)

    let base: URL
    let rootURL: URL
    let tempRoot: URL
    let sourcesURL: URL
    let keys: MockMasterKeyStoring
    let cipher: MockFileCipher
    let prefs: MockPreferencesStoring
    let store: LiveVaultStore
    let root: VaultDirectory

    init(lockMode: LockMode = .none, keyLoaded: Bool = true) throws {
        let manager = FileManager.default
        let raw = manager.temporaryDirectory.appendingPathComponent(
            "VaultStoreTests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: raw, withIntermediateDirectories: true)
        let base = raw.resolvingSymlinksInPath()
        let rootURL = base.appendingPathComponent("Vault", isDirectory: true)
        let tempRoot = base.appendingPathComponent("Temp", isDirectory: true)
        let sourcesURL = base.appendingPathComponent("Sources", isDirectory: true)
        for url in [rootURL, tempRoot, sourcesURL] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let keys = MockMasterKeyStoring(password: "pw", keyLoaded: keyLoaded)
        let cipher = MockFileCipher()
        let prefs = MockPreferencesStoring(lockMode: lockMode)
        self.base = base
        self.rootURL = rootURL
        self.tempRoot = tempRoot
        self.sourcesURL = sourcesURL
        self.keys = keys
        self.cipher = cipher
        self.prefs = prefs
        self.root = VaultDirectory(name: "KoalaTVault", diskURL: rootURL, rootURL: rootURL)
        self.store = LiveVaultStore(
            root: rootURL, keyStore: keys, cipher: cipher, preferences: prefs, temporaryRoot: tempRoot)
    }

    func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootURL.path)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Disk setup

    /// Creates a real folder under the root (or under `parent`).
    @discardableResult
    func folder(_ name: String, in parent: VaultDirectory? = nil) throws -> VaultDirectory {
        let parent = parent ?? root
        let url = parent.diskURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return VaultDirectory(name: name, diskURL: url, rootURL: rootURL)
    }

    /// Writes a file straight onto the disk (no index).
    @discardableResult
    func diskFile(_ name: String, _ content: String = "x", in directory: VaultDirectory? = nil) throws -> URL {
        let url = (directory ?? root).diskURL.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// A file outside the vault to import.
    func source(_ name: String, _ content: String = "x") throws -> URL {
        let url = sourcesURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(name)
        try Data(content.utf8).write(to: file)
        return file
    }

    /// Imports a file through the store.
    @discardableResult
    func add(_ name: String, _ content: String = "x", to directory: VaultDirectory? = nil) async throws -> VaultItem {
        try await store.addFile(from: source(name, content), named: name, to: directory ?? root)
    }

    func setModified(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Listing

    func list(
        _ directory: VaultDirectory? = nil, _ option: SortOption = .name, _ direction: SortDirection = .ascending
    ) async throws -> [VaultItem] {
        try await store.contents(of: directory ?? root, sortedBy: option, direction)
    }

    func names(
        _ directory: VaultDirectory? = nil, _ option: SortOption = .name, _ direction: SortDirection = .ascending
    ) async throws -> [String] {
        try await list(directory, option, direction).map(\.name)
    }

    /// Names of every entry on disk in the folder, hidden ones included.
    func diskNames(in directory: VaultDirectory? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (directory ?? root).diskURL.path).sorted()
    }

    func content(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// Plaintext content of the item as the store opens it.
    func openedContent(_ item: VaultItem) async throws -> String {
        let url = try await store.open(item)
        return try content(url)
    }

    /// Every file under the vault root (and the temp root): path -> bytes, folders -> "<dir>".
    func snapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for top in [rootURL, tempRoot] {
            let enumerator = FileManager.default.enumerator(at: top, includingPropertiesForKeys: [.isDirectoryKey])
            while let url = enumerator?.nextObject() as? URL {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                result[url.path] = isDirectory ? Data("<dir>".utf8) : try Data(contentsOf: url)
            }
        }
        return result
    }

    /// Every regular file inside the temp root.
    func tempFiles() -> [URL] {
        tempContents().filter { url in
            !((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
    }

    /// Everything inside the temp root.
    func tempContents() -> [URL] {
        let enumerator = FileManager.default.enumerator(at: tempRoot, includingPropertiesForKeys: nil)
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL { urls.append(url) }
        return urls
    }

    // MARK: - Index files

    func indexURL(_ directory: VaultDirectory? = nil) -> URL {
        (directory ?? root).diskURL.appendingPathComponent(".vault_map")
    }

    /// Writes an index: encrypted with the mock cipher's tag for `context`, or plaintext JSON when nil.
    func writeIndex(_ entries: [String: String], in directory: VaultDirectory? = nil, context: String?) throws {
        let json = try JSONSerialization.data(
            withJSONObject: entries.mapValues { ["originalName": $0] }, options: [.sortedKeys])
        let data = context.map { Data("mock-sealed:\($0):".utf8) + json } ?? json
        try data.write(to: indexURL(directory))
    }

    /// Writes raw bytes as the index.
    func writeRawIndex(_ data: Data, in directory: VaultDirectory? = nil) throws {
        try data.write(to: indexURL(directory))
    }

    func rawIndex(in directory: VaultDirectory? = nil) -> Data? {
        try? Data(contentsOf: indexURL(directory))
    }

    /// The index's JSON payload (after the mock tag, if any), or nil when absent.
    func indexPayload(in directory: VaultDirectory? = nil) -> Data? {
        guard let data = rawIndex(in: directory) else { return nil }
        guard data.starts(with: Self.sealedPrefix) else { return data }
        let rest = data.dropFirst(Self.sealedPrefix.count)
        guard let colon = rest.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        return Data(rest[rest.index(after: colon)...])
    }

    /// The index's mapping UUID -> original name, or nil when the index is absent or unreadable.
    func indexEntries(in directory: VaultDirectory? = nil) -> [String: String]? {
        guard let payload = indexPayload(in: directory),
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: [String: Any]]
        else { return nil }
        return object.compactMapValues { $0["originalName"] as? String }
    }

    /// Whether the index file is plaintext JSON on disk.
    func indexIsPlaintextJSON(in directory: VaultDirectory? = nil) -> Bool {
        guard let data = rawIndex(in: directory) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// The context the index on disk was sealed with, or nil when plaintext or absent.
    func indexContext(in directory: VaultDirectory? = nil) -> String? {
        guard let data = rawIndex(in: directory), data.starts(with: Self.sealedPrefix) else { return nil }
        let rest = data.dropFirst(Self.sealedPrefix.count)
        guard let colon = rest.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        return String(decoding: rest[rest.startIndex..<colon], as: UTF8.self)
    }
}

extension Sequence {
    /// Maps in order, awaiting each transform before the next.
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
