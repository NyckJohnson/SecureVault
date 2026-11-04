import Foundation
import Testing
import UIKit

@testable import KoalaTVault

// API under test (chosen by the test-writer; the code-writer implements it):
//
// @MainActor final class FileCellModel {
//     init(thumbnails: ThumbnailProviding, folderAssetAvailable: Bool)
//     private(set) var item: VaultItem?
//     func configure(with item: VaultItem)       // the cell now shows `item`
//     func prepareForReuse()                      // cancels the shown item's thumbnail; item = nil
//     var name: String                            // item?.name ?? ""
//     var sizeText: String                        // ByteCountFormatter .file; "" for folders / no item
//     var icon: FileIcon?                         // FileIconMapping.icon(...); nil with no item
//     func thumbnail(size: CGSize, scale: CGFloat) async -> UIImage?
//         // asks ThumbnailProviding for the shown item; returns nil if the cell shows a
//         // different item (or none) by the time the answer arrives
// }

@MainActor
@Suite struct FileCellModelTests {
    /// A thumbnail provider that holds each request until the test releases it.
    private final class GatedThumbnails: ThumbnailProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var requested = 0
        private var cancelled: [String] = []
        let image = UIImage(systemName: "photo")

        var requestCount: Int { lock.withLock { requested } }
        var cancelledIDs: [String] { lock.withLock { cancelled } }

        func thumbnail(for item: VaultItem, size: CGSize, scale: CGFloat) async -> UIImage? {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    requested += 1
                    waiting.append(continuation)
                }
            }
            return image
        }

        func releaseAll() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { waiting = [] }
                return waiting
            }
            pending.forEach { $0.resume() }
        }

        func cancel(_ item: VaultItem) { lock.withLock { cancelled.append(item.id) } }
        func clearCache() {}
        func clearCache(for item: VaultItem) {}
    }

    private struct Samples {
        let file: VaultItem
        let folder: VaultItem
        let other: VaultItem
    }

    private func sampleItems() throws -> Samples {
        let store = MockVaultStoring()
        let file = try #require(store.allItems.first { $0.name == "Beach.jpg" })
        let folder = try #require(store.allItems.first { $0.name == "Photos" })
        let other = try #require(store.allItems.first { $0.name == "Notes.rtf" })
        return Samples(file: file, folder: folder, other: other)
    }

    @Test("The cell shows the item's name")
    func showsName() throws {
        let samples = try sampleItems()
        let model = FileCellModel(thumbnails: MockThumbnailProviding(), folderAssetAvailable: true)
        model.configure(with: samples.file)
        #expect(model.name == "Beach.jpg")
    }

    @Test("A file's size text uses the file byte-count style")
    func fileSizeText() throws {
        let samples = try sampleItems()
        let model = FileCellModel(thumbnails: MockThumbnailProviding(), folderAssetAvailable: true)
        model.configure(with: samples.file)
        #expect(model.sizeText == ByteCountFormatter.string(fromByteCount: 2_481_152, countStyle: .file))
    }

    @Test("A file of zero bytes still shows a size text")
    func zeroByteSizeText() async throws {
        let store = MockVaultStoring(withSampleContent: false)
        let created = try await store.createDocument(named: "Empty", in: store.root)
        let model = FileCellModel(thumbnails: MockThumbnailProviding(), folderAssetAvailable: true)
        model.configure(with: created)
        #expect(model.sizeText == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
    }

    @Test("A folder's size text is empty")
    func folderSizeTextEmpty() throws {
        let samples = try sampleItems()
        let model = FileCellModel(thumbnails: MockThumbnailProviding(), folderAssetAvailable: true)
        model.configure(with: samples.folder)
        #expect(model.sizeText.isEmpty)
    }

    @Test("A file's icon comes from FileIconMapping", arguments: [true, false])
    func fileIcon(folderAssetAvailable: Bool) throws {
        let samples = try sampleItems()
        let model = FileCellModel(thumbnails: MockThumbnailProviding(), folderAssetAvailable: folderAssetAvailable)
        model.configure(with: samples.file)
        #expect(
            model.icon
                == FileIconMapping.icon(
                    for: .image, isDirectory: false, folderAssetAvailable: folderAssetAvailable))
    }

    @Test("A folder's icon comes from FileIconMapping and follows folder asset availability", arguments: [true, false])
    func folderIcon(folderAssetAvailable: Bool) throws {
        let samples = try sampleItems()
        let model = FileCellModel(thumbnails: MockThumbnailProviding(), folderAssetAvailable: folderAssetAvailable)
        model.configure(with: samples.folder)
        #expect(
            model.icon
                == FileIconMapping.icon(
                    for: .other, isDirectory: true, folderAssetAvailable: folderAssetAvailable))
    }

    @Test("The cell requests a thumbnail for the item it shows")
    func requestsThumbnail() async throws {
        let samples = try sampleItems()
        let thumbnails = MockThumbnailProviding()
        let model = FileCellModel(thumbnails: thumbnails, folderAssetAvailable: true)
        model.configure(with: samples.file)
        let image = await model.thumbnail(size: CGSize(width: 80, height: 80), scale: 2)
        #expect(thumbnails.calls == [.thumbnail("Beach.jpg")])
        #expect(image != nil)
    }

    @Test("Reusing the cell cancels the shown item's thumbnail request")
    func reuseCancelsThumbnail() throws {
        let samples = try sampleItems()
        let thumbnails = MockThumbnailProviding()
        let model = FileCellModel(thumbnails: thumbnails, folderAssetAvailable: true)
        model.configure(with: samples.file)
        model.prepareForReuse()
        #expect(thumbnails.calls == [.cancel("Beach.jpg")])
        #expect(model.item == nil)
    }

    @Test("Reusing a cell that shows nothing cancels nothing")
    func reuseWithNoItemCancelsNothing() {
        let thumbnails = MockThumbnailProviding()
        let model = FileCellModel(thumbnails: thumbnails, folderAssetAvailable: true)
        model.prepareForReuse()
        #expect(thumbnails.calls.isEmpty)
    }

    @Test("A thumbnail that arrives after the cell shows another item is ignored")
    func lateThumbnailIgnoredForOtherItem() async throws {
        let samples = try sampleItems()
        let gate = GatedThumbnails()
        let model = FileCellModel(thumbnails: gate, folderAssetAvailable: true)
        model.configure(with: samples.file)
        let task = Task { await model.thumbnail(size: CGSize(width: 80, height: 80), scale: 2) }
        while gate.requestCount == 0 { await Task.yield() }
        model.configure(with: samples.other)
        gate.releaseAll()
        #expect(await task.value == nil)
    }

    @Test("A thumbnail that arrives after the cell was reused is ignored")
    func lateThumbnailIgnoredAfterReuse() async throws {
        let samples = try sampleItems()
        let gate = GatedThumbnails()
        let model = FileCellModel(thumbnails: gate, folderAssetAvailable: true)
        model.configure(with: samples.file)
        let task = Task { await model.thumbnail(size: CGSize(width: 80, height: 80), scale: 2) }
        while gate.requestCount == 0 { await Task.yield() }
        model.prepareForReuse()
        gate.releaseAll()
        #expect(await task.value == nil)
        #expect(gate.cancelledIDs == ["Beach.jpg"])
    }

    @Test("A thumbnail that arrives while the cell still shows the item is delivered")
    func thumbnailDeliveredForSameItem() async throws {
        let samples = try sampleItems()
        let gate = GatedThumbnails()
        let model = FileCellModel(thumbnails: gate, folderAssetAvailable: true)
        model.configure(with: samples.file)
        let task = Task { await model.thumbnail(size: CGSize(width: 80, height: 80), scale: 2) }
        while gate.requestCount == 0 { await Task.yield() }
        gate.releaseAll()
        #expect(await task.value != nil)
    }
}
