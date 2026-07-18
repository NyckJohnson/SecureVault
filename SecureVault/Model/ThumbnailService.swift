//
//  ThumbnailService.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/17/26.
//

import UIKit
import QuickLookThumbnailing

final class ThumbnailService {
    static let shared = ThumbnailService()
    private init() {}

    private var cache = NSCache<NSString, UIImage>()

    // MARK: - Public
    func thumbnail(for item: VaultItem, size: CGSize, completion: @escaping (UIImage?) -> Void) -> QLThumbnailGenerator.Request? {
        let cacheKey = item.id.uuidString as NSString

        // return cached if available
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return nil
        }

        if item.isDirectory {
            return folderThumbnail(for: item, size: size, completion: completion)
        } else {
            return fileThumbnail(for: item, size: size, completion: completion)
        }
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    func clearCache(for item: VaultItem) {
        cache.removeObject(forKey: item.id.uuidString as NSString)
    }

    // MARK: - File Thumbnail
    private func fileThumbnail(for item: VaultItem, size: CGSize, completion: @escaping (UIImage?) -> Void) -> QLThumbnailGenerator.Request? {
        let generateThumbnail: (URL) -> QLThumbnailGenerator.Request = { [weak self] url in
            guard let self else { return QLThumbnailGenerator.Request(fileAt: url, size: size, scale: UIScreen.main.scale, representationTypes: .thumbnail) }
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: UIScreen.main.scale,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
                guard let self, let thumbnail else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                self.cache.setObject(thumbnail.uiImage, forKey: item.id.uuidString as NSString)
                DispatchQueue.main.async { completion(thumbnail.uiImage) }
            }
            return request
        }

        if item.isEncrypted {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let url = try? FileSystem.shared.open(item) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                _ = generateThumbnail(url)
            }
            return nil
        } else {
            return generateThumbnail(item.diskURL)
        }
    }

    // MARK: - Folder Thumbnail
    private func folderThumbnail(for item: VaultItem, size: CGSize, completion: @escaping (UIImage?) -> Void) -> QLThumbnailGenerator.Request? {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let dir = VaultDirectory(name: item.name, diskURL: item.diskURL)
            let contents = (try? FileSystem.shared.contents(of: dir)) ?? []
            let mediaExtensions = ["jpg","jpeg","png","heic","gif","webp","mp4","mov","m4v"]
            guard let mediaItem = contents.first(where: {
                !$0.isDirectory && mediaExtensions.contains(($0.name as NSString).pathExtension.lowercased())
            }) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            _ = self.fileThumbnail(for: mediaItem, size: size) { thumbnail in
                guard let thumbnail else {
                    completion(nil)
                    return
                }
                let composed = self.composeFolderIcon(thumbnail: thumbnail)
                self.cache.setObject(composed, forKey: item.id.uuidString as NSString)
                completion(composed)
            }
        }
        return nil
    }

    // MARK: - Folder Icon Composition
    private func composeFolderIcon(thumbnail: UIImage) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 60, weight: .regular)
        let folderImage = UIImage(systemName: "folder.fill")?
            .withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
            .withConfiguration(config)
        let size = folderImage?.size ?? CGSize(width: 80, height: 80)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            folderImage?.draw(in: CGRect(origin: .zero, size: size))

            // Frame
            let thumbWidth = size.width * 0.6
            let thumbHeight = size.height * 0.8
            let thumbRect = CGRect(
                x: (size.width - thumbWidth) / 2,
                y: (size.height - thumbHeight) / 2,
                width: thumbWidth,
                height: thumbHeight
            )
            let clipPath = UIBezierPath(roundedRect: thumbRect, cornerRadius: 3)
            clipPath.addClip()
            
            // picture in frame
            let thumbSize = thumbnail.size
            let scale = min(thumbRect.width / thumbSize.width, thumbRect.height / thumbSize.height)
            let scaledWidth = thumbSize.width * scale
            let scaledHeight = thumbSize.height * scale
            let drawRect = CGRect(
                x: thumbRect.midX - scaledWidth / 2,
                y: thumbRect.midY - scaledHeight / 2,
                width: scaledWidth,
                height: scaledHeight
            )
            thumbnail.draw(in: drawRect)
        }
    }
}
