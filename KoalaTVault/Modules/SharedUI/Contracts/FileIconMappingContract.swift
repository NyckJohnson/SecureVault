import UIKit

/// The icon shown for a file or folder: an SF Symbol (or the folder asset) and a tint.
struct FileIcon: Sendable, Equatable {
    /// The SF Symbol name, or the folder asset's name when `usesFolderAsset` is true.
    let symbolName: String
    /// The `UIColor` name of the tint (e.g. "systemGreen", "clear").
    let tintName: String
    /// Whether `symbolName` names the custom folder asset rather than an SF Symbol.
    let usesFolderAsset: Bool
}

/// Maps a file kind to its icon.
enum FileIconMapping {
    /// The icon for an item of `kind`; folders use the folder asset when it is available.
    static func icon(for kind: FileKind, isDirectory: Bool, folderAssetAvailable: Bool) -> FileIcon {
        if isDirectory {
            return folderAssetAvailable
                ? FileIcon(symbolName: "nej_FolderIconB", tintName: "clear", usesFolderAsset: true)
                : FileIcon(symbolName: "folder.fill", tintName: "systemYellow", usesFolderAsset: false)
        }
        let (symbol, tint): (String, String) =
            switch kind {
            case .image: ("photo", "systemGreen")
            case .video: ("video", "systemPurple")
            case .audio: ("music.note", "systemPink")
            case .pdf: ("doc.richtext", "systemRed")
            case .word: ("doc.text", "systemBlue")
            case .spreadsheet: ("tablecells", "systemGreen")
            case .presentation: ("rectangle.stack", "systemOrange")
            case .archive: ("archivebox", "systemBrown")
            case .text: ("doc.plaintext", "systemGray")
            case .other: ("doc", "systemGray")
            }
        return FileIcon(symbolName: symbol, tintName: tint, usesFolderAsset: false)
    }
}
