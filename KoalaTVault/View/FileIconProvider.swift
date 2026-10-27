//
//  FileIconProvider.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit

nonisolated enum FileIconProvider {
    private static let customFolderIconName = "nej_FolderIconB"
    
    static let hasCustomFolderAsset = UIImage(named: customFolderIconName) != nil
    
    static func folderImage(pointSize: CGFloat = 24) -> UIImage? {
        guard let custom = UIImage(named: customFolderIconName) else {
            let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            return UIImage(systemName: "folder.fill")?.withConfiguration(config)
        }
        return custom
    }
    
    static func icon(for item: LegacyVaultItem) -> UIImage? {
        if item.isDirectory { return folderImage() }

        let ext = (item.name as NSString).pathExtension.lowercased()
        switch LegacyFileKind(extension: ext) {
        case .image: return UIImage(systemName: "photo")
        case .video: return UIImage(systemName: "video")
        case .audio: return UIImage(systemName: "music.note")
        case .pdf: return UIImage(systemName: "doc.richtext")
        case .word: return UIImage(systemName: "doc.text")
        case .spreadsheet: return UIImage(systemName: "tablecells")
        case .presentation: return UIImage(systemName: "rectangle.stack")
        case .archive: return UIImage(systemName: "archivebox")
        case .text: return UIImage(systemName: "doc.plaintext")
        case .other: return UIImage(systemName: "doc")
        }
    }
        
    static func iconColor(for item: LegacyVaultItem) -> UIColor {
        if item.isDirectory {
            return UIImage(named: customFolderIconName) != nil ? .clear : .systemYellow
        }

        let ext = (item.name as NSString).pathExtension.lowercased()
        switch LegacyFileKind(extension: ext) {
        case .image: return .systemGreen
        case .video: return .systemPurple
        case .audio: return .systemPink
        case .pdf: return .systemRed
        case .word: return .systemBlue
        case .spreadsheet: return .systemGreen
        case .presentation: return .systemOrange
        case .archive: return .systemBrown
        case .text, .other: return .systemGray
        }
    }
}
