import Testing
import UIKit

@testable import KoalaTVault

@Suite struct ThumbnailCacheTests {
    private let image = makeTestImage(side: 8)

    @Test("A new cache has no image for any id")
    func emptyCache() {
        let cache = ThumbnailCache()
        #expect(cache.image(for: "a") == nil)
        #expect(cache.count < 1)
    }

    @Test("A stored image is returned for its id only")
    func storeAndFetchByID() {
        let cache = ThumbnailCache()
        cache.store(image, for: "a", generation: cache.generation)
        #expect(cache.image(for: "a") === image)
        #expect(cache.image(for: "b") == nil)
        #expect(cache.count == 1)
    }

    @Test("Storing again for the same id replaces the image")
    func storeReplaces() {
        let cache = ThumbnailCache()
        let other = makeTestImage(side: 9)
        cache.store(image, for: "a", generation: cache.generation)
        cache.store(other, for: "a", generation: cache.generation)
        #expect(cache.image(for: "a") === other)
        #expect(cache.count == 1)
    }

    @Test("Removing an id drops only that image")
    func removeOne() {
        let cache = ThumbnailCache()
        cache.store(image, for: "a", generation: cache.generation)
        cache.store(image, for: "b", generation: cache.generation)
        cache.remove(id: "a")
        #expect(cache.image(for: "a") == nil)
        #expect(cache.image(for: "b") === image)
    }

    @Test("Removing a missing id does nothing")
    func removeMissing() {
        let cache = ThumbnailCache()
        cache.store(image, for: "a", generation: cache.generation)
        cache.remove(id: "zzz")
        #expect(cache.count == 1)
    }

    @Test("Removing all empties the cache")
    func removeAllEmpties() {
        let cache = ThumbnailCache()
        cache.store(image, for: "a", generation: cache.generation)
        cache.store(image, for: "b", generation: cache.generation)
        cache.removeAll()
        #expect(cache.count < 1)
        #expect(cache.image(for: "a") == nil)
    }

    @Test("Removing all starts a new generation")
    func removeAllBumpsGeneration() {
        let cache = ThumbnailCache()
        let before = cache.generation
        cache.removeAll()
        #expect(cache.generation != before)
    }

    @Test("An image stored with a generation from before a clear is not kept")
    func staleGenerationIgnored() {
        let cache = ThumbnailCache()
        let stale = cache.generation
        cache.removeAll()
        cache.store(image, for: "a", generation: stale)
        #expect(cache.image(for: "a") == nil)
        #expect(cache.count < 1)
    }

    @Test("An image stored with the current generation after a clear is kept")
    func currentGenerationAfterClearKept() {
        let cache = ThumbnailCache()
        cache.removeAll()
        cache.store(image, for: "a", generation: cache.generation)
        #expect(cache.image(for: "a") === image)
    }

    @Test("Concurrent stores and reads do not lose entries")
    func concurrentAccess() async {
        let cache = ThumbnailCache()
        let image = self.image
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { cache.store(image, for: "id-\(index)", generation: cache.generation) }
                group.addTask { _ = cache.image(for: "id-\(index)") }
            }
        }
        #expect(cache.count == 50)
    }
}
