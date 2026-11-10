import Testing
import UIKit

@testable import KoalaTVault

@Suite struct ThumbnailCacheTests {
    private let image = makeTestImage(side: 8)

    /// The key API the tests expect: `ThumbnailCache.Key(id:dateModified:fileSize:)`.
    private func key(_ id: String, modified: TimeInterval = 0, size: Int? = 10) -> ThumbnailCache.Key {
        ThumbnailCache.Key(id: id, dateModified: Date(timeIntervalSince1970: modified), fileSize: size)
    }

    @Test("A new cache has no image for any id")
    func emptyCache() {
        let cache = ThumbnailCache()
        #expect(cache.image(for: key("a")) == nil)
        #expect(cache.count < 1)
    }

    @Test("A stored image is returned for its id only")
    func storeAndFetchByID() {
        let cache = ThumbnailCache()
        cache.store(image, for: key("a"), generation: cache.generation)
        #expect(cache.image(for: key("a")) === image)
        #expect(cache.image(for: key("b")) == nil)
        #expect(cache.count == 1)
    }

    @Test("Storing again for the same id replaces the image")
    func storeReplaces() {
        let cache = ThumbnailCache()
        let other = makeTestImage(side: 9)
        cache.store(image, for: key("a"), generation: cache.generation)
        cache.store(other, for: key("a"), generation: cache.generation)
        #expect(cache.image(for: key("a")) === other)
        #expect(cache.count == 1)
    }

    @Test("Removing an id drops only that image")
    func removeOne() {
        let cache = ThumbnailCache()
        cache.store(image, for: key("a"), generation: cache.generation)
        cache.store(image, for: key("b"), generation: cache.generation)
        cache.remove(id: "a")
        #expect(cache.image(for: key("a")) == nil)
        #expect(cache.image(for: key("b")) === image)
    }

    @Test("Removing a missing id does nothing")
    func removeMissing() {
        let cache = ThumbnailCache()
        cache.store(image, for: key("a"), generation: cache.generation)
        cache.remove(id: "zzz")
        #expect(cache.count == 1)
    }

    @Test("Removing all empties the cache")
    func removeAllEmpties() {
        let cache = ThumbnailCache()
        cache.store(image, for: key("a"), generation: cache.generation)
        cache.store(image, for: key("b"), generation: cache.generation)
        cache.removeAll()
        #expect(cache.count < 1)
        #expect(cache.image(for: key("a")) == nil)
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
        cache.store(image, for: key("a"), generation: stale)
        #expect(cache.image(for: key("a")) == nil)
        #expect(cache.count < 1)
    }

    @Test("An image stored with the current generation after a clear is kept")
    func currentGenerationAfterClearKept() {
        let cache = ThumbnailCache()
        cache.removeAll()
        cache.store(image, for: key("a"), generation: cache.generation)
        #expect(cache.image(for: key("a")) === image)
    }

    @Test("Concurrent stores and reads do not lose entries")
    func concurrentAccess() async {
        let cache = ThumbnailCache()
        let image = self.image
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { cache.store(image, for: key("id-\(index)"), generation: cache.generation) }
                group.addTask { _ = cache.image(for: key("id-\(index)")) }
            }
        }
        #expect(cache.count == 50)
    }

    @Test("The same id with a different modification date is a different entry")
    func differentDateIsDifferentEntry() {
        let cache = ThumbnailCache()
        let other = makeTestImage(side: 9)
        cache.store(image, for: key("a", modified: 1), generation: cache.generation)
        #expect(cache.image(for: key("a", modified: 2)) == nil)
        cache.store(other, for: key("a", modified: 2), generation: cache.generation)
        #expect(cache.image(for: key("a", modified: 2)) === other)
    }

    @Test("The same id with a different file size is a different entry")
    func differentSizeIsDifferentEntry() {
        let cache = ThumbnailCache()
        cache.store(image, for: key("a", size: 10), generation: cache.generation)
        #expect(cache.image(for: key("a", size: 11)) == nil)
        #expect(cache.image(for: key("a", size: nil)) == nil)
        #expect(cache.image(for: key("a", size: 10)) === image)
    }

    @Test("Keys with the same id, date and size are equal")
    func equalKeysHit() {
        let cache = ThumbnailCache()
        cache.store(image, for: key("a", modified: 5, size: 7), generation: cache.generation)
        #expect(cache.image(for: key("a", modified: 5, size: 7)) === image)
    }

    @Test("Removing an id drops every version of that item and leaves other ids")
    func removeIDDropsAllVersions() {
        let cache = ThumbnailCache()
        cache.store(image, for: key("a", modified: 1), generation: cache.generation)
        cache.store(image, for: key("a", modified: 2, size: 99), generation: cache.generation)
        cache.store(image, for: key("b"), generation: cache.generation)
        cache.remove(id: "a")
        #expect(cache.image(for: key("a", modified: 1)) == nil)
        #expect(cache.image(for: key("a", modified: 2, size: 99)) == nil)
        #expect(cache.image(for: key("b")) === image)
    }
}
