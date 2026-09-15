//
//  ThumbnailService.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/17/26.
//

import UIKit
import AVFoundation
import QuickLookThumbnailing

final class ThumbnailService {
    static let shared = ThumbnailService()
    private init() {}

    private enum FolderIconLayout {
            static let symbolPointSizeRatio: CGFloat = 0.8
            static let verticalOffsetRatio: CGFloat = 0.075
            static let thumbInsetX: CGFloat = 0.05
            static let thumbInsetY: CGFloat = 0.1
            static let thumbWidthRatio: CGFloat = 0.9
            static let thumbHeightRatio: CGFloat = 0.8
            static let thumbCornerRadius: CGFloat = 3
        }
    
    private var cache = NSCache<NSString, UIImage>()
    private var cancelledIDs = Set<UUID>()
    private let decryptionSemaphore = DispatchSemaphore(value: 2)
    private let thumbnailQueue = DispatchQueue(label: "com.securevault.thumbnails", attributes: .concurrent)

    // MARK: - Public
    func thumbnail(for item: VaultItem, size: CGSize, completion: @escaping (UIImage?) -> Void) -> QLThumbnailGenerator.Request? {
        cancelledIDs.remove(item.id)
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

    func cancelThumbnail(for item: VaultItem) {
        cancelledIDs.insert(item.id)
    }
    
    func clearCache() {
        cache.removeAllObjects()
    }

    func clearCache(for item: VaultItem) {
        cache.removeObject(forKey: item.id.uuidString as NSString)
    }

    // MARK: - File Thumbnail
    private func fileThumbnail(for item: VaultItem, size: CGSize, completion: @escaping (UIImage?) -> Void) -> QLThumbnailGenerator.Request? {
        let ext = (item.name as NSString).pathExtension.lowercased()
        if item.isEncrypted, FileKind(extension: ext) == .video {
            videoThumbnail(for: item, size: size, completion: completion)
            return nil
        }
        
        let generateThumbnail: (URL, Bool) -> QLThumbnailGenerator.Request = { [weak self] url, shouldCleanup in
            guard let self else { return QLThumbnailGenerator.Request(fileAt: url, size: size, scale: UIScreen.main.scale, representationTypes: .thumbnail) }
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: UIScreen.main.scale,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
                if shouldCleanup { try? FileManager.default.removeItem(at: url) }
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
            thumbnailQueue.async { [weak self] in
                guard let self else { return }
                self.decryptionSemaphore.wait()
                defer { self.decryptionSemaphore.signal() }
                guard self.cache.object(forKey: item.id.uuidString as NSString) == nil else {
                    DispatchQueue.main.async {
                        completion(self.cache.object(forKey: item.id.uuidString as NSString))
                    }
                    return
                }
                guard let url = try? FileSystem.shared.open(item) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                _ = generateThumbnail(url, true)
            }
            return nil
        } else {
            return generateThumbnail(item.diskURL, false)
        }
    }

    private func videoThumbnail(for item: VaultItem, size: CGSize, completion: @escaping (UIImage?) -> Void) {
        thumbnailQueue.async { [weak self] in
            guard let self else { return }
            let ext = (item.name as NSString).pathExtension.lowercased()
            guard let delegate = VaultResourceLoaderDelegate(encryptedURL: item.diskURL, fileExtension: ext) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            var comps = URLComponents(url: item.diskURL, resolvingAgainstBaseURL: false)!
            comps.scheme = "vault-stream"
            let asset = AVURLAsset(url: comps.url!)
            asset.resourceLoader.setDelegate(delegate, queue: self.thumbnailQueue)

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: size.width * UIScreen.main.scale,
                                            height: size.height * UIScreen.main.scale)

            // withStrongReferenceTo keeps `delegate` alive until generation completes,
            // since AVAssetResourceLoader only holds its delegate weakly.
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 5, preferredTimescale: 600))]) { _, cgImage, _, _, _ in
                withExtendedLifetime(delegate) {
                    guard let cgImage else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    let image = UIImage(cgImage: cgImage)
                    self.cache.setObject(image, forKey: item.id.uuidString as NSString)
                    DispatchQueue.main.async { completion(image) }
                }
            }
        }
    }

    // MARK: - Folder Thumbnail
    private func folderThumbnail(for item: VaultItem, size: CGSize, completion: @escaping (UIImage?) -> Void) -> QLThumbnailGenerator.Request? {
        thumbnailQueue.async { [weak self] in
            guard let self else { return }
            let dir = VaultDirectory(name: item.name, diskURL: item.diskURL, rootURL: item.rootURL)
            let contents = (try? FileSystem.shared.contents(of: dir)) ?? []
            guard let mediaItem = contents.first(where: {
                guard !$0.isDirectory else { return false }
                let kind = FileKind(extension: ($0.name as NSString).pathExtension.lowercased())
                return kind == .image || kind == .video
            }) else {
                let folderIcon = self.renderFolderImage(targetSize: size)
                if let folderIcon {
                    self.cache.setObject(folderIcon, forKey: item.id.uuidString as NSString)
                }
                DispatchQueue.main.async { completion(folderIcon) }
                return
            }

            _ = self.fileThumbnail(for: mediaItem, size: size) { thumbnail in
                guard let thumbnail else {
                    completion(nil)
                    return
                }
                let composed = self.composeFolderIcon(thumbnail: thumbnail, targetSize: size)
                self.cache.setObject(composed, forKey: item.id.uuidString as NSString)
                completion(composed)
            }
        }
        return nil
    }

    // MARK: - Folder Icon Composition
    private func renderFolderImage(targetSize: CGSize) -> UIImage? {
        guard let baseFolderImage = FileIconProvider.folderImage(pointSize: targetSize.height * FolderIconLayout.symbolPointSizeRatio) else {
            return nil
        }
        let folderImage = FileIconProvider.hasCustomFolderAsset
            ? baseFolderImage
            : baseFolderImage.withTintColor(.systemYellow, renderingMode: .alwaysOriginal)

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { ctx in
            var folderDrawRect = AVMakeRect(aspectRatio: folderImage.size, insideRect: CGRect(origin: .zero, size: targetSize))
            folderDrawRect.origin.y += targetSize.height * FolderIconLayout.verticalOffsetRatio
            folderImage.draw(in: folderDrawRect)
        }
    }
    
    private func composeFolderIcon(thumbnail: UIImage, targetSize: CGSize) -> UIImage {
        guard let folderBackground = renderFolderImage(targetSize: targetSize) else {
            return thumbnail
        }
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { ctx in
            folderBackground.draw(at: .zero)

        // the window which thumbnail image can appear
            let thumbRect = CGRect(
                x: targetSize.width * FolderIconLayout.thumbInsetX,
                y: targetSize.height * FolderIconLayout.thumbInsetY,
                width: targetSize.width * FolderIconLayout.thumbWidthRatio,
                height: targetSize.height * FolderIconLayout.thumbHeightRatio
            )
            let clipPath = UIBezierPath(roundedRect: thumbRect, cornerRadius: FolderIconLayout.thumbCornerRadius)
            clipPath.addClip()
            let drawRect = AVMakeRect(aspectRatio: thumbnail.size, insideRect: thumbRect)
            thumbnail.draw(in: drawRect)
        }
    }
}
