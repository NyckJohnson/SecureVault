import Foundation

/// A folder of the vault.
struct VaultDirectory: Sendable, Codable, Equatable, Hashable {
    /// Display name; the root is "KoalaTVault".
    let name: String
    /// The folder on disk.
    let diskURL: URL
    /// The vault root this folder belongs to.
    let rootURL: URL
}

/// The kind of a file, from its name's extension.
enum FileKind: String, Sendable, Codable, CaseIterable {
    case image, video, audio, pdf, word, spreadsheet, presentation, archive, text, other

    /// The kind for a file extension (without the dot); matching ignores case.
    init(extension: String) {
        switch `extension`.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": self = .image
        case "mp4", "mov", "m4v": self = .video
        case "mp3", "m4a", "wav", "aac": self = .audio
        case "pdf": self = .pdf
        case "doc", "docx": self = .word
        case "xls", "xlsx": self = .spreadsheet
        case "ppt", "pptx": self = .presentation
        case "zip", "rar", "7z": self = .archive
        case "txt", "rtf", "md": self = .text
        default: self = .other
        }
    }
}

/// A file or folder in the vault or in its trash.
struct VaultItem: Identifiable, Sendable, Codable, Equatable, Hashable {
    /// Disk path relative to the vault root (trash items: `.trash/<uuid>`); stable across listings.
    let id: String
    /// Display name (the original name for encrypted files).
    var name: String
    /// Whether the item is a folder (also for folders in the trash).
    let isDirectory: Bool
    /// From the disk file.
    let dateModified: Date
    /// Nil for folders.
    let fileSize: Int?
    /// Trash items only.
    let deletedAt: Date?
    /// The item on disk.
    let diskURL: URL
    /// The vault root this item belongs to.
    let rootURL: URL
    /// Whether the disk name is listed in the folder's index.
    let isEncrypted: Bool

    /// The kind, computed from the name's extension.
    var kind: FileKind { FileKind(extension: (name as NSString).pathExtension) }

    /// This item as a folder, or nil for a file.
    var asDirectory: VaultDirectory? {
        isDirectory ? VaultDirectory(name: name, diskURL: diskURL, rootURL: rootURL) : nil
    }
}
