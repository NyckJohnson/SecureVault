import Foundation
import os

/// An in-memory vault with sample folders and files; records every call.
///
/// Items live only in memory (their disk URLs point under a temporary folder that isn't written),
/// except for the temporary folders `makeTempDirectory()` creates.
final class MockVaultStoring: VaultStoring {
    /// A recorded call; items are identified by their `id`.
    enum Call: Equatable, Sendable {
        case contents(directory: String, SortOption, SortDirection)
        case open(String)
        case write(String)
        case createFolder(String, parent: String)
        case createDocument(String, parent: String)
        case addFile(String, destination: String)
        /// The names of the files, in order.
        case addFiles([String], destination: String)
        case findItem(String, parent: String)
        case move(String, destination: String)
        case copy(String, destination: String)
        case rename(String, newName: String)
        case moveToTrash(String)
        case remove(String)
        case trashContents
        case restore(String)
        case deletePermanently(String)
        case emptyTrash
        case purgeExpiredTrash
        case hasUnreadableTrash
        case clearUnreadableTrash
        case countFiles
        case itemsToEncrypt
        case migrateToEncrypted(String)
        case finishEncryption
        case hasUnencryptedFiles
        case keyMatchesVault
        case sweepOrphans
        case makeTempDirectory
        case removeTemporary(URL)
        case removeAllTemporaryFiles
    }

    private struct State: Sendable {
        var items: [VaultItem]
        var trash: [VaultItem]
        /// Original folder of each trashed item, by trash item id.
        var trashOrigins: [String: URL] = [:]
        var tempDirectories: [URL] = []
        var calls: [Call] = []
        var errorToThrow: VaultStoreError?
        var keyMatches = true
        var unreadableTrash = false
    }

    let root: VaultDirectory
    let isEncrypted: Bool
    private let state: OSAllocatedUnfairLock<State>

    /// A vault holding the sample content (`withSampleContent`) or empty; `name` is the root's display name
    /// and `isEncrypted` the store's fixed mode (the unencrypted vault "KoalaTVault" unless stated).
    init(withSampleContent: Bool = true, name: String = "KoalaTVault", isEncrypted: Bool = false) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockVault", isDirectory: true)
        root = VaultDirectory(name: name, diskURL: rootURL, rootURL: rootURL)
        self.isEncrypted = isEncrypted
        let (items, trash) = withSampleContent ? Self.sampleContent(rootURL: rootURL) : ([], [])
        state = OSAllocatedUnfairLock(initialState: State(items: items, trash: trash))
    }

    /// Every call so far, in order.
    var calls: [Call] { state.withLock { $0.calls } }

    /// Every item outside the trash.
    var allItems: [VaultItem] { state.withLock { $0.items } }

    /// When set, every throwing call throws this error.
    var errorToThrow: VaultStoreError? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    /// What `keyMatchesVault()` returns.
    var keyMatches: Bool {
        get { state.withLock { $0.keyMatches } }
        set { state.withLock { $0.keyMatches = newValue } }
    }

    /// What `hasUnreadableTrash()` returns; `clearUnreadableTrash()` resets it to false.
    var unreadableTrash: Bool {
        get { state.withLock { $0.unreadableTrash } }
        set { state.withLock { $0.unreadableTrash = newValue } }
    }

    func contents(
        of directory: VaultDirectory,
        sortedBy option: SortOption,
        _ direction: SortDirection
    ) async throws -> [VaultItem] {
        try record(.contents(directory: relativeID(directory.diskURL), option, direction)) { state in
            Self.sorted(state.items.filter { Self.isChild($0.diskURL, of: directory.diskURL) }, option, direction)
        }
    }

    func open(_ item: VaultItem) async throws -> URL {
        try record(.open(item.id)) { state in
            guard state.items.contains(where: { $0.id == item.id }) else { throw VaultStoreError.notFound }
            return item.diskURL
        }
    }

    func write(_ data: Data, to item: VaultItem) async throws {
        try record(.write(item.id)) { state in
            guard let index = state.items.firstIndex(where: { $0.id == item.id }) else {
                throw VaultStoreError.notFound
            }
            state.items[index] = Self.modified(state.items[index]) { fields in
                fields.fileSize = data.count
                fields.dateModified = Date()
            }
        }
    }

    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try record(.createFolder(name, parent: relativeID(directory.diskURL))) { state in
            try Self.validate(name)
            let unique = Self.uniqueName(name, in: directory.diskURL, among: state.items)
            let item = self.makeItem(named: unique, in: directory.diskURL, isDirectory: true, fileSize: nil)
            state.items.append(item)
            return item
        }
    }

    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem {
        try record(.createDocument(name, parent: relativeID(directory.diskURL))) { state in
            try Self.validate(name)
            let fileName = name.lowercased().hasSuffix(".rtf") ? name : name + ".rtf"
            let unique = Self.uniqueName(fileName, in: directory.diskURL, among: state.items)
            let item = self.makeItem(named: unique, in: directory.diskURL, isDirectory: false, fileSize: 0)
            state.items.append(item)
            return item
        }
    }

    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return try record(.addFile(name, destination: relativeID(directory.diskURL))) { state in
            try Self.validate(name)
            let unique = Self.uniqueName(name, in: directory.diskURL, among: state.items)
            let item = self.makeItem(named: unique, in: directory.diskURL, isDirectory: false, fileSize: size)
            state.items.append(item)
            return item
        }
    }

    func addFiles(_ files: [VaultFileToAdd], to directory: VaultDirectory) async throws -> [VaultItem] {
        let sizes = files.map { (try? $0.source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return try record(.addFiles(files.map(\.name), destination: relativeID(directory.diskURL))) { state in
            var added: [VaultItem] = []
            for (file, size) in zip(files, sizes) {
                try Self.validate(file.name)
                let unique = Self.uniqueName(file.name, in: directory.diskURL, among: state.items)
                let item = self.makeItem(named: unique, in: directory.diskURL, isDirectory: false, fileSize: size)
                state.items.append(item)
                added.append(item)
            }
            return added
        }
    }

    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem? {
        try record(.findItem(name, parent: relativeID(directory.diskURL))) { state in
            state.items.first { $0.name == name && Self.isChild($0.diskURL, of: directory.diskURL) }
        }
    }

    func move(_ item: VaultItem, to directory: VaultDirectory) async throws {
        try record(.move(item.id, destination: relativeID(directory.diskURL))) { state in
            guard state.items.contains(where: { $0.id == item.id }) else { throw VaultStoreError.notFound }
            if Self.isChild(item.diskURL, of: directory.diskURL) { return }
            if item.isDirectory && Self.isSameOrDescendant(directory.diskURL, of: item.diskURL) {
                throw VaultStoreError.moveIntoItself
            }
            let unique = Self.uniqueName(item.name, in: directory.diskURL, among: state.items)
            let newURL = directory.diskURL.appendingPathComponent(unique, isDirectory: item.isDirectory)
            state.items = state.items.map { current in
                guard Self.isSameOrDescendant(current.diskURL, of: item.diskURL) else { return current }
                let suffix = String(current.diskURL.path.dropFirst(item.diskURL.path.count))
                let moved = URL(fileURLWithPath: newURL.path + suffix, isDirectory: current.isDirectory)
                return Self.modified(current) { fields in
                    if current.id == item.id { fields.name = unique }
                    fields.diskURL = moved
                }
            }
        }
    }

    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem {
        try record(.copy(item.id, destination: relativeID(directory.diskURL))) { state in
            guard state.items.contains(where: { $0.id == item.id }) else { throw VaultStoreError.notFound }
            let unique = Self.uniqueName(item.name, in: directory.diskURL, among: state.items)
            let newURL = directory.diskURL.appendingPathComponent(unique, isDirectory: item.isDirectory)
            let copy = Self.modified(item) { fields in
                fields.name = unique
                fields.diskURL = newURL
            }
            state.items.append(copy)
            return copy
        }
    }

    func rename(_ item: VaultItem, to name: String) async throws -> VaultItem {
        try record(.rename(item.id, newName: name)) { state in
            try Self.validate(name)
            guard let index = state.items.firstIndex(where: { $0.id == item.id }) else {
                throw VaultStoreError.notFound
            }
            let parent = item.diskURL.deletingLastPathComponent()
            let unique = Self.uniqueName(name, in: parent, among: state.items.filter { $0.id != item.id })
            let renamed = Self.modified(item) { fields in
                fields.name = unique
                fields.diskURL = parent.appendingPathComponent(unique, isDirectory: item.isDirectory)
            }
            state.items[index] = renamed
            return renamed
        }
    }

    func moveToTrash(_ item: VaultItem) async throws {
        try record(.moveToTrash(item.id)) { state in
            guard state.items.contains(where: { $0.id == item.id }) else { throw VaultStoreError.notFound }
            let trashURL = self.root.rootURL.appendingPathComponent(
                ".trash/\(UUID().uuidString)", isDirectory: item.isDirectory)
            let trashed = Self.modified(item) { fields in
                fields.diskURL = trashURL
                fields.deletedAt = Date()
            }
            state.items.removeAll { Self.isSameOrDescendant($0.diskURL, of: item.diskURL) }
            state.trash.append(trashed)
            state.trashOrigins[trashed.id] = item.diskURL.deletingLastPathComponent()
        }
    }

    func remove(_ item: VaultItem) async throws {
        try record(.remove(item.id)) { state in
            if state.trash.contains(where: { $0.id == item.id }) { throw VaultStoreError.notFound }
            guard state.items.contains(where: { $0.id == item.id }) else { throw VaultStoreError.notFound }
            state.items.removeAll { Self.isSameOrDescendant($0.diskURL, of: item.diskURL) }
        }
    }

    func trashContents() async throws -> [VaultItem] {
        try record(.trashContents) { $0.trash }
    }

    func restore(_ trashed: VaultItem) async throws -> VaultItem {
        try record(.restore(trashed.id)) { state in
            guard let index = state.trash.firstIndex(where: { $0.id == trashed.id }) else {
                throw VaultStoreError.notFound
            }
            let parent = state.trashOrigins[trashed.id] ?? self.root.diskURL
            let unique = Self.uniqueName(trashed.name, in: parent, among: state.items)
            let restored = Self.modified(trashed) { fields in
                fields.name = unique
                fields.diskURL = parent.appendingPathComponent(unique, isDirectory: trashed.isDirectory)
                fields.deletedAt = nil
            }
            state.trash.remove(at: index)
            state.trashOrigins[trashed.id] = nil
            state.items.append(restored)
            return restored
        }
    }

    func deletePermanently(_ trashed: VaultItem) async throws {
        try record(.deletePermanently(trashed.id)) { state in
            guard let index = state.trash.firstIndex(where: { $0.id == trashed.id }) else {
                throw VaultStoreError.notFound
            }
            state.trash.remove(at: index)
            state.trashOrigins[trashed.id] = nil
        }
    }

    func emptyTrash() async {
        state.withLock { state in
            state.calls.append(.emptyTrash)
            state.trash = []
            state.trashOrigins = [:]
        }
    }

    func purgeExpiredTrash(now: Date) async throws -> Int {
        try record(.purgeExpiredTrash) { state in
            let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
            let before = state.trash.count
            state.trash.removeAll { ($0.deletedAt ?? now) < cutoff }
            return before - state.trash.count
        }
    }

    func hasUnreadableTrash() async -> Bool {
        state.withLock { state in
            state.calls.append(.hasUnreadableTrash)
            return state.unreadableTrash
        }
    }

    func clearUnreadableTrash() async throws {
        try record(.clearUnreadableTrash) { state in state.unreadableTrash = false }
    }

    func countFiles() async throws -> Int {
        try record(.countFiles) { state in state.items.filter { !$0.isDirectory }.count }
    }

    func itemsToEncrypt() async throws -> [VaultItem] {
        try record(.itemsToEncrypt) { state in
            (state.items + state.trash).filter { !$0.isDirectory && !$0.isEncrypted }
        }
    }

    func migrateToEncrypted(_ item: VaultItem) async throws {
        try record(.migrateToEncrypted(item.id)) { state in try self.setEncrypted(true, item, in: &state) }
    }

    func finishEncryption() async throws {
        try record(.finishEncryption) { _ in }
    }

    func hasUnencryptedFiles() async throws -> Bool {
        try record(.hasUnencryptedFiles) { state in
            (state.items + state.trash).contains { !$0.isDirectory && !$0.isEncrypted }
        }
    }

    func keyMatchesVault() async -> Bool {
        state.withLock { state in
            state.calls.append(.keyMatchesVault)
            return state.keyMatches
        }
    }

    func sweepOrphans() async {
        state.withLock { $0.calls.append(.sweepOrphans) }
    }

    func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockVaultTemp-\(UUID().uuidString)", isDirectory: true)
        try record(.makeTempDirectory) { state in state.tempDirectories.append(url) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw VaultStoreError.io(error.localizedDescription)
        }
        return url
    }

    func removeTemporary(_ url: URL) {
        state.withLock { state in
            state.calls.append(.removeTemporary(url))
            state.tempDirectories.removeAll { $0 == url }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func removeAllTemporaryFiles() {
        let urls = state.withLock { state in
            state.calls.append(.removeAllTemporaryFiles)
            defer { state.tempDirectories = [] }
            return state.tempDirectories
        }
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Helpers

    private func record<R: Sendable>(_ call: Call, _ body: @Sendable (inout State) throws -> R) throws -> R {
        try state.withLock { state in
            state.calls.append(call)
            if let error = state.errorToThrow { throw error }
            return try body(&state)
        }
    }

    private func relativeID(_ url: URL) -> String {
        Self.relativeID(url, rootURL: root.rootURL)
    }

    /// The editable fields of a `VaultItem`; its `id` follows from `diskURL` and `rootURL`.
    private struct Fields {
        var name: String
        var isDirectory: Bool
        var dateModified: Date
        var fileSize: Int?
        var deletedAt: Date?
        var diskURL: URL
        var rootURL: URL
        var isEncrypted: Bool
    }

    private func makeItem(named name: String, in parent: URL, isDirectory: Bool, fileSize: Int?) -> VaultItem {
        Self.item(
            Fields(
                name: name, isDirectory: isDirectory, dateModified: Date(), fileSize: fileSize, deletedAt: nil,
                diskURL: parent.appendingPathComponent(name, isDirectory: isDirectory), rootURL: root.rootURL,
                isEncrypted: false))
    }

    private func setEncrypted(_ encrypted: Bool, _ item: VaultItem, in state: inout State) throws {
        if let index = state.items.firstIndex(where: { $0.id == item.id }) {
            state.items[index] = Self.modified(state.items[index]) { $0.isEncrypted = encrypted }
        } else if let index = state.trash.firstIndex(where: { $0.id == item.id }) {
            state.trash[index] = Self.modified(state.trash[index]) { $0.isEncrypted = encrypted }
        } else {
            throw VaultStoreError.notFound
        }
    }

    private static func item(_ fields: Fields) -> VaultItem {
        VaultItem(
            id: relativeID(fields.diskURL, rootURL: fields.rootURL), name: fields.name,
            isDirectory: fields.isDirectory, dateModified: fields.dateModified, fileSize: fields.fileSize,
            deletedAt: fields.deletedAt, diskURL: fields.diskURL, rootURL: fields.rootURL,
            isEncrypted: fields.isEncrypted)
    }

    /// A copy of `item` with `change` applied.
    private static func modified(_ item: VaultItem, _ change: (inout Fields) -> Void) -> VaultItem {
        var fields = Fields(
            name: item.name, isDirectory: item.isDirectory, dateModified: item.dateModified,
            fileSize: item.fileSize, deletedAt: item.deletedAt, diskURL: item.diskURL, rootURL: item.rootURL,
            isEncrypted: item.isEncrypted)
        change(&fields)
        return Self.item(fields)
    }

    private static func relativeID(_ url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count).drop { $0 == "/" })
    }

    private static func isChild(_ url: URL, of directory: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
    }

    private static func isSameOrDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        return path == ancestorPath || path.hasPrefix(ancestorPath + "/")
    }

    private static func validate(_ name: String) throws {
        if name.isEmpty || name.contains("/") { throw VaultStoreError.invalidName }
    }

    /// `name`, or `name` with " 1", " 2", … before the extension when the folder already holds it.
    private static func uniqueName(_ name: String, in directory: URL, among items: [VaultItem]) -> String {
        let taken = Set(items.filter { isChild($0.diskURL, of: directory) }.map(\.name))
        guard taken.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !taken.contains(candidate) { return candidate }
            counter += 1
        }
    }

    private static func sorted(_ items: [VaultItem], _ option: SortOption, _ direction: SortDirection) -> [VaultItem] {
        func ascending(_ lhs: VaultItem, _ rhs: VaultItem) -> Bool {
            switch option {
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .type:
                let lhsExt = (lhs.name as NSString).pathExtension.lowercased()
                let rhsExt = (rhs.name as NSString).pathExtension.lowercased()
                if lhsExt != rhsExt { return lhsExt < rhsExt }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .dateModified:
                return lhs.dateModified < rhs.dateModified
            }
        }
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return direction == .ascending ? ascending(lhs, rhs) : ascending(rhs, lhs)
        }
    }

    private static func sampleContent(rootURL: URL) -> (items: [VaultItem], trash: [VaultItem]) {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        let photos = rootURL.appendingPathComponent("Photos", isDirectory: true)
        func sample(_ name: String, in parent: URL, folder: Bool = false, size: Int? = nil, age: Double) -> VaultItem {
            item(
                Fields(
                    name: name, isDirectory: folder, dateModified: now.addingTimeInterval(-age * day), fileSize: size,
                    deletedAt: nil, diskURL: parent.appendingPathComponent(name, isDirectory: folder), rootURL: rootURL,
                    isEncrypted: false))
        }
        var items: [VaultItem] = []
        items.append(sample("Photos", in: rootURL, folder: true, age: 2))
        items.append(sample("Documents", in: rootURL, folder: true, age: 9))
        items.append(sample("Beach.jpg", in: rootURL, size: 2_481_152, age: 1))
        items.append(sample("Holiday.mov", in: rootURL, size: 48_234_496, age: 4))
        items.append(sample("Notes.rtf", in: rootURL, size: 1_024, age: 0.5))
        items.append(sample("Tax Return 2025.pdf", in: rootURL, size: 356_812, age: 30))
        items.append(sample("Sunset.heic", in: photos, size: 1_874_330, age: 3))
        items.append(sample("Birthday.mp4", in: photos, size: 22_118_400, age: 6))
        let trashed = item(
            Fields(
                name: "Old Receipt.pdf", isDirectory: false, dateModified: now.addingTimeInterval(-12 * day),
                fileSize: 88_412, deletedAt: now.addingTimeInterval(-3 * day),
                diskURL: rootURL.appendingPathComponent(".trash/\(UUID().uuidString)", isDirectory: false),
                rootURL: rootURL, isEncrypted: false))
        return (items, [trashed])
    }
}
