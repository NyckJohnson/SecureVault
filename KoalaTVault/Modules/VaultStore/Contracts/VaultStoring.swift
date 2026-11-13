import Foundation

/// Errors thrown by the vault store.
enum VaultStoreError: Error, Equatable, Sendable {
    /// A folder's index exists but can't be read; it is never overwritten.
    case indexUnreadable(folder: String)
    /// The vault is encrypted and no key is loaded.
    case locked
    /// An empty name or a name containing "/".
    case invalidName
    /// The item doesn't exist.
    case notFound
    /// A folder can't be moved into itself or a descendant.
    case moveIntoItself
    /// A file-system failure.
    case io(String)  // swiftlint:disable:this identifier_name
}

/// User-facing text for each error, shown in alerts through `localizedDescription`.
extension VaultStoreError: LocalizedError {
    /// The error's user-facing description; `.io` is its message.
    var errorDescription: String? {
        switch self {
        case .indexUnreadable:
            "Couldn't read the vault's file index. It may still be locked, or a file may have become corrupted."
        case .locked: VaultCryptoError.noKeyLoaded.localizedDescription
        case .invalidName: "Names can't contain / or start with ."
        case .notFound: "This item no longer exists."
        case .moveIntoItself: "A folder can't be moved into itself"
        case .io(let message): message
        }
    }
}

/// One file for `VaultStoring.addFiles(_:to:)`: the file at `source`, added under `name`.
///
/// The files of one call go into one folder, in order, as one serialized store step; the folder's index is
/// read once and (in encrypted mode) written once, after the last file. Each file is added exactly as
/// `addFile` would add it, its name resolved against the folder and the earlier files of the same call.
struct VaultFileToAdd: Sendable, Equatable {
    /// The file to copy (plaintext mode) or encrypt (encrypted mode).
    let source: URL
    /// The name to give it in the vault (" 1" added on a clash).
    let name: String
}

/// The vault on disk: indexes, browsing, file operations, trash, migration steps and temp files.
protocol VaultStoring: Sendable {
    /// The vault's root folder.
    var root: VaultDirectory { get }
    /// Whether the vault is encrypted; fixed for the store's life.
    var isEncrypted: Bool { get }
    /// The folder's items, folders first, sorted by `option` and `direction`.
    func contents(
        of directory: VaultDirectory,
        sortedBy option: SortOption,
        _ direction: SortDirection
    ) async throws -> [VaultItem]
    /// A URL with the item's plaintext (its disk URL, or a decrypted temp copy).
    func open(_ item: VaultItem) async throws -> URL
    /// Replaces the item's content.
    func write(_ data: Data, to item: VaultItem) async throws
    /// Creates a folder.
    func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem
    /// Creates an empty `.rtf` document.
    func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem
    /// Adds a copy of the file at `source`.
    func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem
    /// Adds many files to one folder in one step, writing the folder's index once (large imports).
    /// Returns the added items in order. A failing file stops the call: the files before it are kept and
    /// indexed, the error is thrown and later files are not attempted. An empty list returns `[]`.
    /// - Throws: `.locked` before anything is written; `.invalidName`, `.io` for the failing file.
    func addFiles(_ files: [VaultFileToAdd], to directory: VaultDirectory) async throws -> [VaultItem]
    /// The item with that display name, or nil.
    func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem?
    /// Moves the item into `directory`.
    func move(_ item: VaultItem, to directory: VaultDirectory) async throws
    /// Copies the item into `directory`.
    func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem
    /// Renames the item.
    func rename(_ item: VaultItem, to name: String) async throws -> VaultItem
    /// Moves the item to the trash.
    func moveToTrash(_ item: VaultItem) async throws
    /// Deletes the item (a folder with its whole tree) for good, never into the trash.
    func remove(_ item: VaultItem) async throws
    /// Every item in the trash.
    func trashContents() async throws -> [VaultItem]
    /// Moves a trashed item back to its original folder.
    func restore(_ trashed: VaultItem) async throws -> VaultItem
    /// Deletes a trashed item for good.
    func deletePermanently(_ trashed: VaultItem) async throws
    /// Deletes everything in the trash, best-effort.
    func emptyTrash() async
    /// Deletes trash items older than 30 days before `now`; returns how many.
    func purgeExpiredTrash(now: Date) async throws -> Int
    /// Whether the trash holds items that can never be decrypted (sealed with a key the vault no longer has):
    /// only in encrypted mode with the key loaded and matching the vault, when the data was read in full and
    /// fails authentication. Either the trash index (the whole trash) or individual top-level trash items.
    /// Anything uncertain (no key, read error, key mismatch, plaintext mode) is not unreadable.
    /// - Returns: false on any error (never throws).
    func hasUnreadableTrash() async -> Bool
    /// Re-checks and removes only the unreadable trash: everything in the trash when its index is unreadable,
    /// otherwise the unreadable items and their entries. Each removal is logged (no names).
    /// Nothing unreadable → no change.
    /// - Throws: `.locked` without the key (nothing removed); `.io` after the rest are removed if a removal fails.
    func clearUnreadableTrash() async throws
    /// The number of files in the vault (subfolders included, trash excluded).
    func countFiles() async throws -> Int
    /// Every plaintext file under the root and in the trash; empty in plaintext mode.
    func itemsToEncrypt() async throws -> [VaultItem]
    /// Encrypts one plaintext file.
    func migrateToEncrypted(_ item: VaultItem) async throws
    /// Re-encrypts every index older builds left as plaintext, as the encrypt migration's last step.
    /// Already-encrypted and unreadable indexes are left as they are; plaintext mode changes nothing.
    /// - Throws: `.locked` in encrypted mode without the key, before anything is written.
    func finishEncryption() async throws
    /// Whether any plaintext file is in the vault or the trash.
    func hasUnencryptedFiles() async throws -> Bool
    /// Whether the loaded key decrypts the vault's root index.
    func keyMatchesVault() async -> Bool
    /// Deletes encrypted files no index lists.
    func sweepOrphans() async
    /// Creates a unique temporary folder.
    func makeTempDirectory() throws -> URL
    /// Removes one temporary file or folder.
    func removeTemporary(_ url: URL)
    /// Removes every temporary file the store created.
    func removeAllTemporaryFiles()
}
