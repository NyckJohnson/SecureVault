//
//  FileIconProvider.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit

enum FileIconProvider {
    static func icon(for item: VaultItem) -> UIImage? {
        if item.isDirectory {
            return UIImage(systemName: "folder.fill")
        }
        
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
            case "jpg", "jpeg", "png", "heic", "gif", "webp":
                return UIImage(systemName: "photo")
            case "mp4", "mov", "m4v", "avi":
                return UIImage(systemName: "video")
            case "mp3", "m4a", "wav", "aac":
                return UIImage(systemName: "music.note")
            case "pdf":
                return UIImage(systemName: "doc.richtext")
            case "doc", "docx":
                return UIImage(systemName: "doc.text")
            case "xls", "xlsx":
                return UIImage(systemName: "tablecells")
            case "ppt", "pptx":
                return UIImage(systemName: "rectangle.stack")
            case "zip", "rar", "7z":
                return UIImage(systemName: "archivebox")
            case "txt", "md":
                return UIImage(systemName: "doc.plaintext")
            default:
                return UIImage(systemName: "doc")
        }
    }
        
    static func iconColor(for item: VaultItem) -> UIColor {
        if item.isDirectory {return .systemYellow }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
            case "jpg", "jpeg", "png", "heic", "gif", "webp": return .systemGreen
            case "mp4", "mov", "m4v", "avi": return .systemPurple
            case "mp3", "m4a", "wav", "aac": return .systemPink
            case "pdf": return .systemRed
            case "doc", "docx": return .systemBlue
            case "xls", "xlsx": return .systemGreen
            case "ppt", "pptx": return .systemOrange
            case "zip", "rar", "7z": return .systemBrown
            default: return .systemGray
        }
    }
}
