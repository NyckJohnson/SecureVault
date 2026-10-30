import UIKit
import os

/// The in-memory thumbnail cache, keyed by item id, modification date and file size, so an edited or
/// replaced file at the same path gets a fresh thumbnail.
///
/// Every clear starts a new *generation*. A generation that began before a clear passes its old
/// generation number to `store(_:for:generation:)` and is ignored, so work finishing after a clear
/// never refills the cache.
final class ThumbnailCache: Sendable {
    /// One version of an item: its id plus the modification date and size it had when thumbnailed.
    struct Key: Hashable, Sendable {
        let id: String
        let dateModified: Date
        let fileSize: Int?
    }

    private struct State: Sendable {
        var images: [Key: UIImage] = [:]
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// The current generation; changes on every `removeAll()`.
    var generation: Int { state.withLock { $0.generation } }

    /// The number of cached images.
    var count: Int { state.withLock { $0.images.count } }

    /// The cached image for the key, if any.
    func image(for key: Key) -> UIImage? {
        state.withLock { $0.images[key] }
    }

    /// Caches the image for the key, unless `generation` is older than the current one.
    func store(_ image: UIImage, for key: Key, generation: Int) {
        state.withLock { state in
            guard state.generation == generation else { return }
            state.images[key] = image
        }
    }

    /// Drops every cached version of the item id.
    func remove(id: String) {
        state.withLock { state in
            state.images = state.images.filter { $0.key.id != id }
        }
    }

    /// Drops every image and starts a new generation.
    func removeAll() {
        state.withLock { state in
            state.images = [:]
            state.generation &+= 1
        }
    }
}
