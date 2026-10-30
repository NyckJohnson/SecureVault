import Foundation
import Testing
import UIKit

@testable import KoalaTVault

@Suite struct LiveThumbnailProviderTests {
    private let size = CGSize(width: 80, height: 60)
    private let scale: CGFloat = 2

    /// A provider wired to fakes, with a temporary folder for the item files.
    private struct Rig {
        let directory = MediaTestDirectory()
        let store = MockVaultStoring(withSampleContent: false)
        let cipher = MockFileCipher()
        let videoAssets = MockVideoAssetProviding()
        let preferences = MockPreferencesStoring()
        let renderer: FakeThumbnailRenderer
        let provider: LiveThumbnailProvider

        init(gate: MediaTestGate? = nil) {
            let renderer = FakeThumbnailRenderer(gate: gate)
            self.renderer = renderer
            provider = LiveThumbnailProvider(
                store: store, cipher: cipher, videoAssets: videoAssets, renderer: renderer,
                preferences: preferences)
        }

        func plaintext(_ name: String) -> VaultItem {
            makeMediaItem(name: name, diskURL: directory.file(name))
        }

        /// The sort arguments of every folder listing the provider asked the store for.
        var listings: [(SortOption, SortDirection)] {
            store.calls.compactMap { call in
                if case .contents(_, let option, let direction) = call { (option, direction) } else { nil }
            }
        }

        func encrypted(_ name: String, contents: Data = Data("secret".utf8)) -> VaultItem {
            makeMediaItem(
                name: name, diskURL: directory.file(UUID().uuidString, contents), isEncrypted: true)
        }
    }

    // MARK: Frame time

    @Test(
        "The video frame time is the smaller of 5 seconds and half the duration",
        arguments: [(40.0, 5.0), (10.0, 5.0), (4.0, 2.0), (1.0, 0.5), (0.0, 0.0)])
    func frameTime(duration: TimeInterval, expected: TimeInterval) {
        #expect(LiveThumbnailProvider.frameTime(forDuration: duration) == expected)
    }

    // MARK: Cache

    @Test("A second request for the same item returns the cached image without generating")
    func secondRequestHitsCache() async {
        let rig = Rig()
        let item = rig.plaintext("a.png")
        let first = await rig.provider.thumbnail(for: item, size: size, scale: scale)
        let second = await rig.provider.thumbnail(for: item, size: size, scale: scale)
        #expect(first != nil)
        #expect(second === first)
        #expect(rig.renderer.quickLookURLs.count == 1)
    }

    @Test("The same id with a changed modification date generates a fresh thumbnail")
    func changedDateRegenerates() async {
        let rig = Rig()
        let url = rig.directory.file("note.txt")
        let old = makeMediaItem(name: "note.txt", diskURL: url, fileSize: 10)
        let edited = makeMediaItem(
            name: "note.txt", diskURL: url, fileSize: 10, dateModified: Date(timeIntervalSince1970: 500))
        let first = await rig.provider.thumbnail(for: old, size: size, scale: scale)
        let second = await rig.provider.thumbnail(for: edited, size: size, scale: scale)
        #expect(first != nil && second != nil)
        #expect(rig.renderer.quickLookURLs.count == 2)
    }

    @Test("The same id with a changed file size generates a fresh thumbnail")
    func changedSizeRegenerates() async {
        let rig = Rig()
        let url = rig.directory.file("note.txt")
        let old = makeMediaItem(name: "note.txt", diskURL: url, fileSize: 10)
        let edited = makeMediaItem(name: "note.txt", diskURL: url, fileSize: 25)
        _ = await rig.provider.thumbnail(for: old, size: size, scale: scale)
        _ = await rig.provider.thumbnail(for: edited, size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs.count == 2)
    }

    @Test("An unchanged item (same id, date and size) still hits the cache")
    func unchangedItemHitsCache() async {
        let rig = Rig()
        let url = rig.directory.file("note.txt")
        let first = makeMediaItem(name: "note.txt", diskURL: url, fileSize: 10)
        let same = makeMediaItem(name: "note.txt", diskURL: url, fileSize: 10)
        let one = await rig.provider.thumbnail(for: first, size: size, scale: scale)
        let two = await rig.provider.thumbnail(for: same, size: size, scale: scale)
        #expect(two === one)
        #expect(rig.renderer.quickLookURLs.count == 1)
    }

    @Test("Clearing an item's cache clears it whichever version was cached")
    func clearCacheForChangedItem() async {
        let rig = Rig()
        let url = rig.directory.file("note.txt")
        let old = makeMediaItem(name: "note.txt", diskURL: url, fileSize: 10)
        let edited = makeMediaItem(name: "note.txt", diskURL: url, fileSize: 25)
        _ = await rig.provider.thumbnail(for: edited, size: size, scale: scale)
        rig.provider.clearCache(for: old)
        _ = await rig.provider.thumbnail(for: edited, size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs.count == 2)
    }

    @Test("Different items are cached separately")
    func itemsCachedSeparately() async {
        let rig = Rig()
        _ = await rig.provider.thumbnail(for: rig.plaintext("a.png"), size: size, scale: scale)
        _ = await rig.provider.thumbnail(for: rig.plaintext("b.png"), size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs.count == 2)
    }

    @Test("Clearing the cache makes the next request generate again")
    func clearCacheRegenerates() async {
        let rig = Rig()
        let item = rig.plaintext("a.png")
        _ = await rig.provider.thumbnail(for: item, size: size, scale: scale)
        rig.provider.clearCache()
        _ = await rig.provider.thumbnail(for: item, size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs.count == 2)
    }

    @Test("Clearing one item's cache leaves the others cached")
    func clearCacheForItem() async {
        let rig = Rig()
        let first = rig.plaintext("first.png")
        let second = rig.plaintext("second.png")
        _ = await rig.provider.thumbnail(for: first, size: size, scale: scale)
        _ = await rig.provider.thumbnail(for: second, size: size, scale: scale)
        rig.provider.clearCache(for: first)
        _ = await rig.provider.thumbnail(for: first, size: size, scale: scale)
        _ = await rig.provider.thumbnail(for: second, size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs.count == 3)
        #expect(rig.renderer.quickLookURLs.last == first.diskURL)
    }

    @Test(
        "A generation finishing after the cache was cleared does not refill it", .timeLimit(.minutes(1))
    )
    func generationAfterClearDoesNotRefill() async {
        let gate = MediaTestGate()
        let rig = Rig(gate: gate)
        let item = rig.plaintext("a.png")
        let provider = rig.provider
        let size = self.size
        let scale = self.scale
        let request = Task { await provider.thumbnail(for: item, size: size, scale: scale) }
        await gate.waitUntilEntered(1)
        provider.clearCache()
        gate.open()
        _ = await request.value
        _ = await provider.thumbnail(for: item, size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs.count == 2)
    }

    @Test("A failed generation is not cached")
    func failureNotCached() async {
        let rig = Rig()
        rig.renderer.quickLookResult = nil
        let item = rig.plaintext("a.png")
        #expect(await rig.provider.thumbnail(for: item, size: size, scale: scale) == nil)
        rig.renderer.quickLookResult = rig.renderer.quickLookImage
        #expect(await rig.provider.thumbnail(for: item, size: size, scale: scale) != nil)
    }

    // MARK: Plaintext

    @Test("A plaintext file gets its QuickLook thumbnail at the requested size and scale")
    func plaintextUsesQuickLook() async {
        let rig = Rig()
        let item = rig.plaintext("doc.pdf")
        let image = await rig.provider.thumbnail(for: item, size: size, scale: scale)
        #expect(image === rig.renderer.quickLookImage)
        #expect(rig.renderer.quickLookURLs == [item.diskURL])
        #expect(rig.renderer.quickLookSizes == [size])
        #expect(rig.renderer.quickLookScales == [scale])
        #expect(rig.cipher.calls.isEmpty)
    }

    @Test("A plaintext video is thumbnailed by QuickLook, not by the streaming loader")
    func plaintextVideoUsesQuickLook() async {
        let rig = Rig()
        let item = rig.plaintext("clip.mp4")
        _ = await rig.provider.thumbnail(for: item, size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs == [item.diskURL])
        #expect(rig.videoAssets.requestedIDs.isEmpty)
    }

    // MARK: Encrypted video

    @Test("An encrypted video gets a frame from the streaming asset at half its duration when short")
    func encryptedVideoShortFrameTime() async {
        let rig = Rig()
        rig.renderer.duration = 4
        let item = rig.encrypted("clip.mp4")
        let image = await rig.provider.thumbnail(for: item, size: size, scale: scale)
        #expect(image === rig.renderer.frameImage)
        #expect(rig.videoAssets.requestedIDs == [item.id])
        #expect(rig.renderer.frameRequests.map(\.time) == [2])
    }

    @Test("An encrypted video's frame time is capped at 5 seconds")
    func encryptedVideoFrameTimeCapped() async {
        let rig = Rig()
        rig.renderer.duration = 120
        _ = await rig.provider.thumbnail(for: rig.encrypted("clip.mov"), size: size, scale: scale)
        #expect(rig.renderer.frameRequests.map(\.time) == [5])
    }

    @Test("An encrypted video writes nothing to disk")
    func encryptedVideoWritesNothing() async {
        let rig = Rig()
        _ = await rig.provider.thumbnail(for: rig.encrypted("clip.mp4"), size: size, scale: scale)
        #expect(!rig.store.calls.contains(.makeTempDirectory))
        #expect(!rig.cipher.calls.contains { if case .decryptFile = $0 { true } else { false } })
        #expect(rig.renderer.quickLookURLs.isEmpty)
    }

    @Test("An encrypted video with an invalid header gives nil")
    func encryptedVideoInvalidHeader() async {
        let rig = Rig()
        rig.videoAssets.errorToThrow = .decryptionFailed
        #expect(
            await rig.provider.thumbnail(for: rig.encrypted("clip.mp4"), size: size, scale: scale) == nil)
    }

    @Test("An encrypted video whose frame cannot be read gives nil")
    func encryptedVideoFrameFails() async {
        let rig = Rig()
        rig.renderer.frameResult = nil
        #expect(
            await rig.provider.thumbnail(for: rig.encrypted("clip.mp4"), size: size, scale: scale) == nil)
    }

    // MARK: Other encrypted files

    @Test(
        "An encrypted document is decrypted into a store temp folder, thumbnailed, and the temp removed"
    )
    func encryptedDocumentUsesTempFolder() async throws {
        let rig = Rig()
        let item = rig.encrypted("report.pdf", contents: Data("plain bytes".utf8))
        let image = await rig.provider.thumbnail(for: item, size: size, scale: scale)
        #expect(image === rig.renderer.quickLookImage)

        let calls = rig.store.calls
        #expect(calls.contains(.makeTempDirectory))
        let removed = try #require(
            calls.compactMap { call -> URL? in
                if case .removeTemporary(let url) = call { url } else { nil }
            }.first)
        let rendered = try #require(rig.renderer.quickLookURLs.first)
        #expect(rendered.standardizedFileURL.path.hasPrefix(removed.standardizedFileURL.path))
        #expect(rendered != item.diskURL)
        #expect(rig.renderer.quickLookFileExisted == [true])
        #expect(rig.renderer.quickLookFileContents == [Data("plain bytes".utf8)])
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(
            rig.cipher.calls.contains {
                if case .decryptFile(let source, _) = $0 { source == item.diskURL } else { false }
            })
    }

    @Test("The temp folder is removed even when the thumbnail cannot be made")
    func tempRemovedOnRenderFailure() async {
        let rig = Rig()
        rig.renderer.quickLookResult = nil
        #expect(
            await rig.provider.thumbnail(for: rig.encrypted("a.pdf"), size: size, scale: scale) == nil)
        let made = rig.store.calls.filter { $0 == .makeTempDirectory }.count
        let removed = rig.store.calls.filter { if case .removeTemporary = $0 { true } else { false } }
            .count
        #expect(made == 1)
        #expect(removed == 1)
    }

    @Test("A locked vault gives nil and leaves no temp folder")
    func lockedGivesNil() async {
        let rig = Rig()
        rig.cipher.errorToThrow = .noKeyLoaded
        #expect(
            await rig.provider.thumbnail(for: rig.encrypted("a.pdf"), size: size, scale: scale) == nil)
        #expect(rig.renderer.quickLookURLs.isEmpty)
        let made = rig.store.calls.filter { $0 == .makeTempDirectory }.count
        let removed = rig.store.calls.filter { if case .removeTemporary = $0 { true } else { false } }
            .count
        #expect(made == removed)
    }

    @Test("A corrupt or truncated encrypted file gives nil")
    func corruptGivesNil() async {
        let rig = Rig()
        rig.cipher.errorToThrow = .decryptionFailed
        #expect(
            await rig.provider.thumbnail(for: rig.encrypted("a.pdf"), size: size, scale: scale) == nil)
        #expect(
            await rig.provider.thumbnail(for: rig.encrypted("b.mp4"), size: size, scale: scale) == nil)
    }

    @Test("A missing source file gives nil")
    func missingFileGivesNil() async {
        let rig = Rig()
        let item = makeMediaItem(
            name: "a.pdf", diskURL: rig.directory.url.appendingPathComponent("does-not-exist"),
            isEncrypted: true)
        #expect(await rig.provider.thumbnail(for: item, size: size, scale: scale) == nil)
    }

    // MARK: Concurrency and cancellation

    @Test("At most two encrypted files are decrypted at once", .timeLimit(.minutes(1)))
    func atMostTwoDecryptsAtOnce() async {
        let gate = MediaTestGate()
        let rig = Rig(gate: gate)
        let items = (0..<5).map { rig.encrypted("f\($0).pdf") }
        let provider = rig.provider
        let size = self.size
        let scale = self.scale
        let requests = items.map { item in
            Task { await provider.thumbnail(for: item, size: size, scale: scale) }
        }

        await gate.waitUntilEntered(2)
        await settleTasks()
        #expect(gate.enteredCount == 2)
        #expect(rig.store.calls.filter { $0 == .makeTempDirectory }.count == 2)

        gate.open()
        var results: [UIImage?] = []
        for request in requests { results.append(await request.value) }
        #expect(results.allSatisfy { $0 != nil })
        #expect(rig.renderer.maxInFlight == 2)
        #expect(rig.renderer.quickLookURLs.count == 5)
    }

    @Test(
        "Cancelling a request that has not started gives nil and does no work", .timeLimit(.minutes(1)))
    func cancelBeforeWorkStarts() async {
        let gate = MediaTestGate()
        let rig = Rig(gate: gate)
        let first = rig.encrypted("a.pdf")
        let second = rig.encrypted("b.pdf")
        let waiting = rig.encrypted("c.pdf")
        let provider = rig.provider
        let size = self.size
        let scale = self.scale
        let running = [first, second].map { item in
            Task { await provider.thumbnail(for: item, size: size, scale: scale) }
        }
        await gate.waitUntilEntered(2)
        let cancelled = Task { await provider.thumbnail(for: waiting, size: size, scale: scale) }
        await settleTasks()

        provider.cancel(waiting)
        gate.open()

        #expect(await cancelled.value == nil)
        for request in running { #expect(await request.value != nil) }
        #expect(rig.renderer.quickLookURLs.count == 2)
        #expect(
            !rig.cipher.calls.contains {
                if case .decryptFile(let source, _) = $0 { source == waiting.diskURL } else { false }
            })
    }

    // MARK: Folders

    private func makeFolder(_ rig: Rig, children: [String]) async throws -> VaultItem {
        let folder = try await rig.store.createFolder(named: "Trip", in: rig.store.root)
        let directory = try #require(folder.asDirectory)
        for name in children {
            let source = rig.directory.file(name)
            _ = try await rig.store.addFile(from: source, named: name, to: directory)
        }
        return folder
    }

    @Test("A folder shows its first image composed onto the folder icon")
    func folderComposesFirstImage() async throws {
        let rig = Rig()
        let folder = try await makeFolder(rig, children: ["a.txt", "b.png", "c.png"])
        let image = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        #expect(image === rig.renderer.composedImage)
        #expect(rig.renderer.composeCount == 1)
        #expect(rig.renderer.quickLookURLs.map(\.lastPathComponent) == ["b.png"])
    }

    @Test("A folder whose first media is a video composes that video's thumbnail")
    func folderComposesFirstVideo() async throws {
        let rig = Rig()
        let folder = try await makeFolder(rig, children: ["a.txt", "clip.mp4"])
        let image = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        #expect(image === rig.renderer.composedImage)
        #expect(rig.renderer.quickLookURLs.map(\.lastPathComponent) == ["clip.mp4"])
    }

    @Test("A folder with no media shows the plain folder icon")
    func folderWithoutMedia() async throws {
        let rig = Rig()
        let folder = try await makeFolder(rig, children: ["a.txt", "b.pdf"])
        let image = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        #expect(image === rig.renderer.folderIconImage)
        #expect(rig.renderer.composeCount == 0)
        #expect(rig.renderer.quickLookURLs.isEmpty)
    }

    @Test("An empty folder shows the plain folder icon")
    func emptyFolder() async throws {
        let rig = Rig()
        let folder = try await makeFolder(rig, children: [])
        #expect(
            await rig.provider.thumbnail(for: folder, size: size, scale: scale)
                === rig.renderer.folderIconImage)
    }

    @Test("A folder whose media thumbnail fails shows the plain folder icon")
    func folderMediaFails() async throws {
        let rig = Rig()
        rig.renderer.quickLookResult = nil
        let folder = try await makeFolder(rig, children: ["b.png"])
        #expect(
            await rig.provider.thumbnail(for: folder, size: size, scale: scale)
                === rig.renderer.folderIconImage)
    }

    @Test("A folder thumbnail is cached by the folder's id")
    func folderCached() async throws {
        let rig = Rig()
        let folder = try await makeFolder(rig, children: ["b.png"])
        _ = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        _ = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        #expect(rig.renderer.composeCount == 1)
    }

    @Test("Cancelling a folder cancels its media request", .timeLimit(.minutes(1)))
    func cancellingFolderCancelsMedia() async throws {
        let gate = MediaTestGate()
        let rig = Rig(gate: gate)
        let folder = try await makeFolder(rig, children: ["b.png"])
        let provider = rig.provider
        let size = self.size
        let scale = self.scale
        let request = Task { await provider.thumbnail(for: folder, size: size, scale: scale) }
        await gate.waitUntilEntered(1)

        provider.cancel(folder)
        gate.open()
        _ = await request.value

        #expect(rig.renderer.quickLookCancelled == [true])
    }

    // MARK: Folder media order

    @Test("A folder asks the store for its children in the user's sort at request time")
    func folderPassesPreferencesToStore() async throws {
        let rig = Rig()
        rig.preferences.sortOption = .dateModified
        rig.preferences.sortDirection = .descending
        let folder = try await makeFolder(rig, children: ["b.png"])
        _ = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        let listings = rig.listings
        #expect(listings.count == 1)
        #expect(listings.first?.0 == .dateModified)
        #expect(listings.first?.1 == .descending)
    }

    @Test("Name descending picks the last name as the folder's media")
    func folderDescendingNamePicksOtherChild() async throws {
        let rig = Rig()
        rig.preferences.sortDirection = .descending
        let folder = try await makeFolder(rig, children: ["b.png", "c.png"])
        _ = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs.map(\.lastPathComponent) == ["c.png"])
    }

    @Test("Name ascending picks the first name as the folder's media")
    func folderAscendingNamePicksFirstChild() async throws {
        let rig = Rig()
        let folder = try await makeFolder(rig, children: ["b.png", "c.png"])
        _ = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs.map(\.lastPathComponent) == ["b.png"])
    }

    @Test(
        "Sorting by type picks the media whose extension sorts first or last",
        arguments: [(SortDirection.ascending, "x.mp4"), (SortDirection.descending, "y.png")])
    func folderTypeSort(direction: SortDirection, expected: String) async throws {
        let rig = Rig()
        rig.preferences.sortOption = .type
        rig.preferences.sortDirection = direction
        let folder = try await makeFolder(rig, children: ["y.png", "x.mp4"])
        _ = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs.map(\.lastPathComponent) == [expected])
        #expect(rig.listings.first?.0 == .type)
        #expect(rig.listings.first?.1 == direction)
    }

    @Test("Changing the sort between requests of an uncached folder changes the pick")
    func folderPickFollowsPreferenceChange() async throws {
        let rig = Rig()
        let folder = try await makeFolder(rig, children: ["b.png", "c.png"])
        _ = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        rig.preferences.sortDirection = .descending
        rig.provider.clearCache(for: folder)
        _ = await rig.provider.thumbnail(for: folder, size: size, scale: scale)
        #expect(rig.renderer.quickLookURLs.map(\.lastPathComponent) == ["b.png", "c.png"])
        #expect(rig.listings.map(\.1) == [.ascending, .descending])
    }
}
