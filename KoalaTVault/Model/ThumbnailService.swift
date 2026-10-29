//
//  ThumbnailService.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/17/26.
//

import UIKit
import AVFoundation
import QuickLookThumbnailing
import os

/// Generates and caches thumbnails for vault items.
///
/// All expensive work (decryption, QuickLook generation, video frame extraction,
/// folder scanning, icon drawing) runs on `thumbnailQueue`. Only the cache lookup
/// in `thumbnail(for:size:completion:)` and delivery of the result touch the main actor.
nonisolated final class ThumbnailService: Sendable {
    typealias Completion = @MainActor @Sendable (UIImage?) -> Void

    private let vaultStore: any VaultStoring
    private let preferences: any PreferencesStoring

    /// - Parameters:
    ///   - vaultStore: the app's vault store (decrypts files and lists folders for thumbnails).
    ///   - preferences: the app's settings (a folder's thumbnail shows its first image or video in sort order).
    init(vaultStore: any VaultStoring, preferences: any PreferencesStoring) {
        self.vaultStore = vaultStore
        self.preferences = preferences
    }

    private enum FolderIconLayout {
        static let symbolPointSizeRatio: CGFloat = 0.8
        static let verticalOffsetRatio: CGFloat = 0.075
        static let thumbInsetX: CGFloat = 0.05
        static let thumbInsetY: CGFloat = 0.1
        static let thumbWidthRatio: CGFloat = 0.9
        static let thumbHeightRatio: CGFloat = 0.8
        static let thumbCornerRadius: CGFloat = 3
    }

    /// `NSCache` is documented as thread-safe but not yet marked `Sendable` in the SDK.
    nonisolated(unsafe) private let cache = NSCache<NSString, UIImage>()
    private let cancelledIDs = OSAllocatedUnfairLock(initialState: Set<VaultItem.ID>())
    private let decryptionSemaphore = DispatchSemaphore(value: 2)
    private let thumbnailQueue = DispatchQueue(label: "com.KoalaTVault.thumbnails", attributes: .concurrent)

    // MARK: - Public

    /// Returns a cached thumbnail immediately, or generates one in the background.
    /// `completion` is always called on the main actor.
    @MainActor
    func thumbnail(for item: VaultItem, size: CGSize, completion: @escaping Completion) -> QLThumbnailGenerator.Request? {
        cancelledIDs.withLock { _ = $0.remove(item.id) }

        if let cached = cachedImage(for: item) {
            completion(cached)
            return nil
        }

        // UIScreen must only be read on the main thread; capture once and pass down.
        let scale = UIScreen.main.scale

        if item.isDirectory {
            folderThumbnail(for: item, size: size, scale: scale, completion: completion)
            return nil
        }
        return fileThumbnail(for: item, size: size, scale: scale, completion: completion)
    }

    /// Skips decryption for an item whose thumbnail is no longer needed
    /// (e.g. its cell scrolled off screen). The completion will not be called.
    func cancelThumbnail(for item: VaultItem) {
        cancelledIDs.withLock { _ = $0.insert(item.id) }
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    func clearCache(for item: VaultItem) {
        cache.removeObject(forKey: cacheKey(for: item))
    }

    // MARK: - Cache Helpers
    /// Item ids are stable paths, so the key also holds the modification date and size: a file replaced
    /// at the same path (or a folder whose contents changed) never shows the old thumbnail.
    private func cacheKey(for item: VaultItem) -> NSString {
        "\(item.id)|\(item.dateModified.timeIntervalSinceReferenceDate)|\(item.fileSize ?? -1)" as NSString
    }

    private func cachedImage(for item: VaultItem) -> UIImage? {
        cache.object(forKey: cacheKey(for: item))
    }

    private func store(_ image: UIImage, for item: VaultItem) {
        cache.setObject(image, forKey: cacheKey(for: item))
    }

    /// Returns `true` (and clears the flag) if the item was cancelled.
    private func consumeCancellation(for id: VaultItem.ID) -> Bool {
        cancelledIDs.withLock { $0.remove(id) != nil }
    }

    // MARK: - File Thumbnail
    private func fileThumbnail(
        for item: VaultItem,
        size: CGSize,
        scale: CGFloat,
        completion: @escaping Completion
    ) -> QLThumbnailGenerator.Request? {
        if item.isEncrypted, item.kind == .video {
            videoThumbnail(for: item, size: size, scale: scale, completion: completion)
            return nil
        }

        guard item.isEncrypted else {
            return generateThumbnail(
                for: item, at: item.diskURL, size: size, scale: scale,
                deleteWhenDone: false, completion: completion
            )
        }

        thumbnailQueue.async { [self] in
            // At most two decryptions at a time; released when the decrypt below has finished.
            decryptionSemaphore.wait()

            if consumeCancellation(for: item.id) {
                decryptionSemaphore.signal()
                return
            }

            if let cached = cachedImage(for: item) {
                decryptionSemaphore.signal()
                DispatchQueue.main.async { completion(cached) }
                return
            }
            Task.detached { [self] in
                defer { decryptionSemaphore.signal() }
                guard let url = try? await vaultStore.open(item) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                _ = generateThumbnail(
                    for: item, at: url, size: size, scale: scale,
                    deleteWhenDone: true, completion: completion
                )
            }
        }
        return nil
    }

    private func generateThumbnail(
        for item: VaultItem,
        at url: URL,
        size: CGSize,
        scale: CGFloat,
        deleteWhenDone: Bool,
        completion: @escaping Completion
    ) -> QLThumbnailGenerator.Request {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [self] thumbnail, _ in
            if deleteWhenDone { vaultStore.removeTemporary(url.deletingLastPathComponent()) }
            let image = thumbnail?.uiImage
            if let image { store(image, for: item) }
            DispatchQueue.main.async { completion(image) }
        }
        return request
    }

    // MARK: - Video Thumbnail
    private func videoThumbnail(
        for item: VaultItem,
        size: CGSize,
        scale: CGFloat,
        completion: @escaping Completion
    ) {
        thumbnailQueue.async { [self] in
            if consumeCancellation(for: item.id) { return }

            let ext = (item.name as NSString).pathExtension.lowercased()
            guard let delegate = VaultResourceLoaderDelegate(encryptedURL: item.diskURL, fileExtension: ext),
                  var components = URLComponents(url: item.diskURL, resolvingAgainstBaseURL: false) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            components.scheme = "vault-stream"
            guard let streamURL = components.url else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let asset = AVURLAsset(url: streamURL)
            asset.resourceLoader.setDelegate(delegate, queue: thumbnailQueue)

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: size.width * scale, height: size.height * scale)

            Task { [self] in
                let frameSeconds: Double
                if let dur = try? await asset.load(.duration) {
                    let secs = CMTimeGetSeconds(dur)
                    frameSeconds = (secs.isFinite && secs > 0) ? min(5.0, secs / 2.0) : 0.0
                } else {
                    frameSeconds = 0.0
                }
                let time = NSValue(time: CMTime(seconds: frameSeconds, preferredTimescale: 600))
                generator.generateCGImagesAsynchronously(forTimes: [time]) { [self] _, cgImage, _, _, _ in
                    // AVAssetResourceLoader holds its delegate weakly; keep it alive until done.
                    withExtendedLifetime(delegate) {
                        guard let cgImage else {
                            DispatchQueue.main.async { completion(nil) }
                            return
                        }
                        let image = UIImage(cgImage: cgImage)
                        store(image, for: item)
                        DispatchQueue.main.async { completion(image) }
                    }
                }
            }
        }
    }

    // MARK: - Folder Thumbnail
    private func folderThumbnail(
        for item: VaultItem,
        size: CGSize,
        scale: CGFloat,
        completion: @escaping Completion
    ) {
        let option = preferences.sortOption
        let direction = preferences.sortDirection
        Task.detached { [self] in
            let contents: [VaultItem]
            if let directory = item.asDirectory {
                contents = (try? await vaultStore.contents(of: directory, sortedBy: option, direction)) ?? []
            } else {
                contents = []
            }
            thumbnailQueue.async { [self] in
                composeFolderThumbnail(for: item, contents: contents, size: size, scale: scale, completion: completion)
            }
        }
    }

    /// The folder icon with the first image or video of `contents` inside, or the plain icon.
    private func composeFolderThumbnail(
        for item: VaultItem,
        contents: [VaultItem],
        size: CGSize,
        scale: CGFloat,
        completion: @escaping Completion
    ) {
        guard let mediaItem = contents.first(where: Self.isMedia) else {
            let folderIcon = renderFolderImage(targetSize: size, scale: scale)
            if let folderIcon { store(folderIcon, for: item) }
            DispatchQueue.main.async { completion(folderIcon) }
            return
        }

        _ = fileThumbnail(for: mediaItem, size: size, scale: scale) { [self] thumbnail in
            guard let thumbnail else {
                completion(nil)
                return
            }
            // Compose off the main thread, then deliver back on main.
            thumbnailQueue.async { [self] in
                let composed = composeFolderIcon(thumbnail: thumbnail, targetSize: size, scale: scale)
                store(composed, for: item)
                DispatchQueue.main.async { completion(composed) }
            }
        }
    }

    private static func isMedia(_ item: VaultItem) -> Bool {
        guard !item.isDirectory else { return false }
        return item.kind == .image || item.kind == .video
    }

    // MARK: - Folder Icon Composition
    private func renderFolderImage(targetSize: CGSize, scale: CGFloat) -> UIImage? {
        let pointSize = targetSize.height * FolderIconLayout.symbolPointSizeRatio
        guard let folderImage = Self.folderImage(pointSize: pointSize) else {
            return nil
        }

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: rendererFormat(scale: scale))
        return renderer.image { _ in
            var folderDrawRect = AVMakeRect(
                aspectRatio: folderImage.size,
                insideRect: CGRect(origin: .zero, size: targetSize)
            )
            folderDrawRect.origin.y += targetSize.height * FolderIconLayout.verticalOffsetRatio
            folderImage.draw(in: folderDrawRect)
        }
    }

    /// The folder image from SharedUI's `FileIconMapping`: the folder asset when the bundle has it,
    /// otherwise the yellow `folder.fill` symbol at `pointSize`.
    private static func folderImage(pointSize: CGFloat) -> UIImage? {
        let assetIcon = FileIconMapping.icon(for: .other, isDirectory: true, folderAssetAvailable: true)
        if assetIcon.usesFolderAsset, let asset = UIImage(named: assetIcon.symbolName) {
            return asset
        }
        let symbolIcon = FileIconMapping.icon(for: .other, isDirectory: true, folderAssetAvailable: false)
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return UIImage(systemName: symbolIcon.symbolName)?
            .withConfiguration(config)
            .withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
    }

    private func composeFolderIcon(thumbnail: UIImage, targetSize: CGSize, scale: CGFloat) -> UIImage {
        guard let folderBackground = renderFolderImage(targetSize: targetSize, scale: scale) else {
            return thumbnail
        }
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: rendererFormat(scale: scale))
        return renderer.image { _ in
            folderBackground.draw(at: .zero)

            // The window in which the thumbnail image appears.
            let thumbRect = CGRect(
                x: targetSize.width * FolderIconLayout.thumbInsetX,
                y: targetSize.height * FolderIconLayout.thumbInsetY,
                width: targetSize.width * FolderIconLayout.thumbWidthRatio,
                height: targetSize.height * FolderIconLayout.thumbHeightRatio
            )
            let clipPath = UIBezierPath(roundedRect: thumbRect, cornerRadius: FolderIconLayout.thumbCornerRadius)
            clipPath.addClip()
            thumbnail.draw(in: AVMakeRect(aspectRatio: thumbnail.size, insideRect: thumbRect))
        }
    }

    private func rendererFormat(scale: CGFloat) -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return format
    }
}
