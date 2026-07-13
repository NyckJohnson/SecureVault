//
//  FileManager.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import Foundation

final class FileStoreService {
    static let shared = FileStoreService()
    
    private let root: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()
    
    private init() {}
    
    var rootURL: URL { root }
    
    func contents(of directory: URL) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        )
        var items = urls.map { FileItem(url: $0) }
        
        if let savedOrder = UserDefaults.standard.array(forKey: directory.path) as? [String] {
            items.sort {
                let i0 = savedOrder.firstIndex(of: $0.name) ?? Int.max
                let i1 = savedOrder.firstIndex(of: $1.name) ?? Int.max
                if i0 != i1 { return i0 < i1 }
                return $0.isDirectory && !$1.isDirectory ||
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } else {
            items.sort(by: {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
        }
        return items
    }
    
    func reorder(in directory: URL, from sourceIndex: Int, to destinationIndex: Int) throws {
        var contents = try self.contents(of: directory)
        let item = contents.remove(at: sourceIndex)
        contents.insert(item, at: destinationIndex)
        // store order in UserDefaults keyed by directory path
        let order = contents.map { $0.name }
        UserDefaults.standard.set(order, forKey: directory.path)
    }
    
    func createFolder(named name: String, in directory: URL) throws {
        let target = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    }
    
    func delete(_ item: FileItem) throws {
        try FileManager.default.removeItem(at: item.url)
    }
    
    func rename(_ item: FileItem, to newName: String) throws {
        let destination = item.url.deletingLastPathComponent()
        try move(item, to: destination, newName: newName)
    }
    
    func move(_ item: FileItem, to destination: URL, newName: String? = nil) throws {
        let name   = resolvedName(for: newName ?? item.name, in: destination)
        let target = destination.appendingPathComponent(name)
        try FileManager.default.moveItem(at:item.url, to: target)
    }
    
    func copy(_ item: FileItem, to destination: URL) throws {
        let target = destination.appendingPathComponent(item.name)
        try FileManager.default.copyItem(at: item.url, to: target)
    }
    
    func resolvedName(for name: String, in directory: URL) -> String {
        let ext       = (name as NSString).pathExtension
        let base      = (name as NSString).deletingPathExtension
        var candidate = name
        var counter   = 1
        
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        
        return candidate
    }
    
    func importFile(from sourceURL: URL, to directory: URL) throws {
        let name        = resolvedName(for: sourceURL.lastPathComponent, in: directory)
        let destination = directory.appendingPathComponent(name)
        let accessing   = sourceURL.startAccessingSecurityScopedResource()
        
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
    }
    
    func exportFile(_ item: FileItem, to destination: URL) throws {
        try FileManager.default.copyItem(at: item.url, to: destination)
    }
}
