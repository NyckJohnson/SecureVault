import UIKit
import os

/// The in-memory thumbnail cache, keyed by item id.
///
/// Every clear starts a new *generation*. A generation that began before a clear passes its old
/// generation number to `store(_:for:generation:)` and is ignored, so work finishing after a clear
/// never refills the cache.
final class ThumbnailCache: Sendable {
    private struct State: Sendable {
        var images: [String: UIImage] = [:]
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// The current generation; changes on every `removeAll()`.
    var generation: Int { state.withLock { $0.generation } }

    /// The number of cached images.
    var count: Int { state.withLock { $0.images.count } }

    /// The cached image for the id, if any.
    func image(for id: String) -> UIImage? {
        state.withLock { $0.images[id] }
    }

    /// Caches the image for the id, unless `generation` is older than the current one.
    func store(_ image: UIImage, for id: String, generation: Int) {
        state.withLock { state in
            guard state.generation == generation else { return }
            state.images[id] = image
        }
    }

    /// Drops the id's image.
    func remove(id: String) {
        state.withLock { _ = $0.images.removeValue(forKey: id) }
    }

    /// Drops every image and starts a new generation.
    func removeAll() {
        state.withLock { state in
            state.images = [:]
            state.generation &+= 1
        }
    }
}
