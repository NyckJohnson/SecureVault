import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultStoreModelsTests {
    // MARK: - FileKind(extension:)

    private static let images: [(String, FileKind)] = ["jpg", "jpeg", "png", "heic", "gif", "webp"].map { ($0, .image) }
    private static let videos: [(String, FileKind)] = ["mp4", "mov", "m4v"].map { ($0, .video) }
    private static let audios: [(String, FileKind)] = ["mp3", "m4a", "wav", "aac"].map { ($0, .audio) }
    private static let documents: [(String, FileKind)] = [("pdf", .pdf), ("doc", .word), ("docx", .word)]
    private static let sheets: [(String, FileKind)] = ["xls", "xlsx"].map { ($0, .spreadsheet) }
    private static let slides: [(String, FileKind)] = ["ppt", "pptx"].map { ($0, .presentation) }
    private static let archives: [(String, FileKind)] = ["zip", "rar", "7z"].map { ($0, .archive) }
    private static let texts: [(String, FileKind)] = ["txt", "rtf", "md"].map { ($0, .text) }

    static let extensionTable: [(String, FileKind)] =
        images + videos + audios + documents + sheets + slides + archives + texts

    @Test("Each listed extension maps to its kind", arguments: extensionTable)
    func extensionMapsToKind(row: (String, FileKind)) {
        #expect(FileKind(extension: row.0) == row.1)
    }

    @Test("Upper-case extensions map to the same kind", arguments: extensionTable)
    func upperCaseExtensionMapsToKind(row: (String, FileKind)) {
        #expect(FileKind(extension: row.0.uppercased()) == row.1)
    }

    @Test("Mixed-case extensions map to the same kind", arguments: extensionTable)
    func mixedCaseExtensionMapsToKind(row: (String, FileKind)) {
        let mixed = row.0.enumerated().map {
            $0.offset.isMultiple(of: 2) ? $0.element.uppercased() : String($0.element)
        }
        .joined()
        #expect(FileKind(extension: mixed) == row.1)
    }

    @Test("An empty extension is other")
    func emptyExtensionIsOther() {
        #expect(FileKind(extension: "") == .other)
    }

    @Test("An unknown extension is other", arguments: ["xyz", "gz", "jpgx", "p df", "swift"])
    func unknownExtensionIsOther(ext: String) {
        #expect(FileKind(extension: ext) == .other)
    }

    // MARK: - VaultItem.kind

    private static let rootURL = URL(fileURLWithPath: "/tmp/vault", isDirectory: true)

    private static func item(
        name: String, diskName: String? = nil, isDirectory: Bool = false, isEncrypted: Bool = false
    ) -> VaultItem {
        let disk = diskName ?? name
        return VaultItem(
            id: disk, name: name, isDirectory: isDirectory, dateModified: Date(timeIntervalSince1970: 0),
            fileSize: isDirectory ? nil : 1, deletedAt: nil,
            diskURL: rootURL.appendingPathComponent(disk, isDirectory: isDirectory), rootURL: rootURL,
            isEncrypted: isEncrypted)
    }

    @Test("A plaintext item's kind comes from its name's extension")
    func plaintextItemKindFromName() {
        #expect(Self.item(name: "photo.JPG").kind == .image)
        #expect(Self.item(name: "movie.mov").kind == .video)
    }

    @Test("An encrypted item's kind comes from its original name, not its UUID disk name")
    func encryptedItemKindFromDisplayName() {
        let item = Self.item(
            name: "Report.pdf", diskName: "5B0E3F2A-1111-2222-3333-444455556666", isEncrypted: true)
        #expect(item.kind == .pdf)
    }

    @Test("An item whose name has no extension is other")
    func itemWithoutExtensionIsOther() {
        #expect(Self.item(name: "README").kind == .other)
    }

    @Test("An item whose disk name has an extension but whose name has none is other")
    func diskNameExtensionIgnored() {
        #expect(Self.item(name: "notes", diskName: "x.pdf").kind == .other)
    }

    @Test("Renaming an item changes its kind")
    func renamedItemChangesKind() {
        var item = Self.item(name: "a.txt")
        #expect(item.kind == .text)
        item.name = "a.zip"
        #expect(item.kind == .archive)
    }

    // MARK: - VaultItem.asDirectory

    @Test("A folder item converts to a directory with its name, disk URL and root URL")
    func folderAsDirectory() {
        let folder = Self.item(name: "Photos", isDirectory: true)
        let directory = folder.asDirectory
        #expect(directory == VaultDirectory(name: "Photos", diskURL: folder.diskURL, rootURL: folder.rootURL))
    }

    @Test("A file item has no directory")
    func fileAsDirectoryIsNil() {
        #expect(Self.item(name: "a.txt").asDirectory == nil)
        #expect(Self.item(name: "b", diskName: "UUID", isEncrypted: true).asDirectory == nil)
    }
}
