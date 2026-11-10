import Testing

@testable import KoalaTVault

@Suite struct FileIconMappingTests {
    private struct Row: Sendable, CustomTestStringConvertible {
        let kind: FileKind
        let symbol: String
        let tint: String
        var testDescription: String { kind.rawValue }
    }

    private static let rows: [Row] = {
        var rows: [Row] = []
        rows.append(Row(kind: .image, symbol: "photo", tint: "systemGreen"))
        rows.append(Row(kind: .video, symbol: "video", tint: "systemPurple"))
        rows.append(Row(kind: .audio, symbol: "music.note", tint: "systemPink"))
        rows.append(Row(kind: .pdf, symbol: "doc.richtext", tint: "systemRed"))
        rows.append(Row(kind: .word, symbol: "doc.text", tint: "systemBlue"))
        rows.append(Row(kind: .spreadsheet, symbol: "tablecells", tint: "systemGreen"))
        rows.append(Row(kind: .presentation, symbol: "rectangle.stack", tint: "systemOrange"))
        rows.append(Row(kind: .archive, symbol: "archivebox", tint: "systemBrown"))
        rows.append(Row(kind: .text, symbol: "doc.plaintext", tint: "systemGray"))
        rows.append(Row(kind: .other, symbol: "doc", tint: "systemGray"))
        return rows
    }()

    @Test("The table covers every file kind")
    func tableCoversAllKinds() {
        #expect(Set(Self.rows.map(\.kind)) == Set(FileKind.allCases))
    }

    @Test("A file of each kind maps to its symbol and tint", arguments: rows)
    private func fileKindMapsToSymbolAndTint(row: Row) {
        let icon = FileIconMapping.icon(for: row.kind, isDirectory: false, folderAssetAvailable: false)
        #expect(icon == FileIcon(symbolName: row.symbol, tintName: row.tint, usesFolderAsset: false))
    }

    @Test("A file's icon ignores folder asset availability", arguments: rows)
    private func fileIgnoresFolderAsset(row: Row) {
        let icon = FileIconMapping.icon(for: row.kind, isDirectory: false, folderAssetAvailable: true)
        #expect(icon == FileIcon(symbolName: row.symbol, tintName: row.tint, usesFolderAsset: false))
    }

    @Test("A folder with the asset available uses the folder asset and a clear tint")
    func folderWithAsset() {
        let icon = FileIconMapping.icon(for: .other, isDirectory: true, folderAssetAvailable: true)
        #expect(icon == FileIcon(symbolName: "nej_FolderIconB", tintName: "clear", usesFolderAsset: true))
    }

    @Test("A folder without the asset falls back to folder.fill in yellow")
    func folderWithoutAsset() {
        let icon = FileIconMapping.icon(for: .other, isDirectory: true, folderAssetAvailable: false)
        #expect(icon == FileIcon(symbolName: "folder.fill", tintName: "systemYellow", usesFolderAsset: false))
    }

    @Test("For a directory the kind does not matter", arguments: FileKind.allCases)
    func directoryIgnoresKind(kind: FileKind) {
        #expect(
            FileIconMapping.icon(for: kind, isDirectory: true, folderAssetAvailable: true)
                == FileIconMapping.icon(for: .other, isDirectory: true, folderAssetAvailable: true))
        #expect(
            FileIconMapping.icon(for: kind, isDirectory: true, folderAssetAvailable: false)
                == FileIconMapping.icon(for: .other, isDirectory: true, folderAssetAvailable: false))
    }
}
