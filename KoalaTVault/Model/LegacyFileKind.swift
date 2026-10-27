//
//  LegacyFileKind.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 8/4/26.
//

import Foundation

nonisolated enum LegacyFileKind {
    case image, video, audio, pdf, word, spreadsheet, presentation, archive,
        text, other

    init(extension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": self = .image
        case "mp4", "mov", "m4v": self = .video  // , "avi" not currently supported
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
