//
//  FileItem.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import Foundation

nonisolated struct FileItem: Identifiable, Sendable, Hashable {
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
        self.dateModified = values?.contentModificationDate ?? Date()
        self.fileSize     = values?.fileSize
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }
}
