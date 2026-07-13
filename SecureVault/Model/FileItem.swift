//
//  FileItem.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import Foundation

struct FileItem: Identifiable, Hashable {
    let id: UUID
    var name: String
    var url: URL
    var isDirectory: Bool
    var dateModified: Date
    var fileSize: Int? //nil for dirctories
    
    init(url: URL) {
        self.id    = UUID()
        self.url   = url
        self.name  = url.lastPathComponent

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])

        self.isDirectory  = values?.isDirectory ?? false
        self.dateModified = values?.contentModificationDateKey
        self.fileSize     = values?.fileSize
    }
}
