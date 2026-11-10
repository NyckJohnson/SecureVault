import AVFoundation
import UIKit

// coverage-exempt-file: declarations only

/// Thumbnails for the browser grid, cached in memory.
protocol ThumbnailProviding: Sendable {
    /// The item's thumbnail, or nil when none can be made.
    func thumbnail(for item: VaultItem, size: CGSize, scale: CGFloat) async -> UIImage?
    /// Cancels the item's pending request.
    func cancel(_ item: VaultItem)
    /// Empties the cache.
    func clearCache()
    /// Removes the item's cached thumbnail.
    func clearCache(for item: VaultItem)
}

/// Playable assets for video items.
protocol VideoAssetProviding: Sendable {
    /// An asset that plays the item: streamed through a resource loader when encrypted, the file URL otherwise.
    func asset(for item: VaultItem) throws -> AVURLAsset
}
