import Foundation
import UIKit
import os

/// Returns SF Symbol images as thumbnails and caches them by item id; records every call.
final class MockThumbnailProviding: ThumbnailProviding {
    /// A recorded call; items are identified by their `id`.
    enum Call: Equatable, Sendable {
        case thumbnail(String)
        case cancel(String)
        case clearCache
        case clearCacheForItem(String)
    }

    private struct State: Sendable {
        var cache: [String: UIImage] = [:]
        var calls: [Call] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Every call so far, in order.
    var calls: [Call] { state.withLock { $0.calls } }

    /// The ids of the items with a cached thumbnail.
    var cachedIDs: Set<String> { state.withLock { Set($0.cache.keys) } }

    func thumbnail(for item: VaultItem, size: CGSize, scale: CGFloat) async -> UIImage? {
        if let cached = state.withLock({ state -> UIImage? in
            state.calls.append(.thumbnail(item.id))
            return state.cache[item.id]
        }) {
            return cached
        }
        let image = Self.placeholder(for: item)
        if let image { state.withLock { $0.cache[item.id] = image } }
        return image
    }

    func cancel(_ item: VaultItem) {
        state.withLock { $0.calls.append(.cancel(item.id)) }
    }

    func clearCache() {
        state.withLock { state in
            state.calls.append(.clearCache)
            state.cache = [:]
        }
    }

    func clearCache(for item: VaultItem) {
        state.withLock { state in
            state.calls.append(.clearCacheForItem(item.id))
            state.cache[item.id] = nil
        }
    }

    private static func placeholder(for item: VaultItem) -> UIImage? {
        if item.isDirectory { return UIImage(systemName: "folder.fill") }
        switch item.kind {
        case .image: return UIImage(systemName: "photo")
        case .video: return UIImage(systemName: "video")
        default: return nil
        }
    }
}
