import Testing
import UIKit

@testable import KoalaTVault

/// Seam assumed: `FileCell(frame:)`, `configure(with:thumbnails:folderAssetAvailable:)`, `prepareForReuse()`,
/// internal `thumbnailView: UIImageView` showing the icon, replaced by the thumbnail when one arrives.
@MainActor
@Suite struct FileCellTests {
    private func makeCell() -> FileCell {
        FileCell(frame: CGRect(x: 0, y: 0, width: 100, height: 120))
    }

    private func sampleItem(_ name: String) throws -> VaultItem {
        let store = MockVaultStoring()
        return try #require(store.allItems.first { $0.name == name })
    }

    @Test("A file cell shows the name, the size text and an icon")
    func showsNameSizeAndIcon() throws {
        let cell = makeCell()
        let item = try sampleItem("Tax Return 2025.pdf")
        cell.configure(with: item, thumbnails: BrowserFakeThumbnails(), folderAssetAvailable: true)
        let texts = BrowserViewHost.texts(in: cell)
        #expect(texts.contains("Tax Return 2025.pdf"))
        let sizeBytes = Int64(try #require(item.fileSize))
        let expectedSize = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        #expect(texts.contains(expectedSize))
        #expect(cell.thumbnailView.image != nil)
    }

    @Test("A folder cell shows its name and no size text")
    func folderHasNoSize() throws {
        let cell = makeCell()
        cell.configure(with: try sampleItem("Photos"), thumbnails: BrowserFakeThumbnails(), folderAssetAvailable: true)
        let texts = BrowserViewHost.texts(in: cell).filter { !$0.isEmpty }
        #expect(texts == ["Photos"])
    }

    @Test("The cell is identified as browser.cell.<name>, with identified name, size and checkmark")
    func identifier() throws {
        let cell = makeCell()
        cell.configure(
            with: try sampleItem("Beach.jpg"), thumbnails: BrowserFakeThumbnails(), folderAssetAvailable: true)
        #expect(cell.accessibilityIdentifier == "browser.cell.Beach.jpg")
        #expect(BrowserViewHost.find("browser.cell.Beach.jpg.nameLabel", in: cell) is UILabel)
        #expect(BrowserViewHost.find("browser.cell.Beach.jpg.sizeLabel", in: cell) is UILabel)
        #expect(BrowserViewHost.find("browser.cell.Beach.jpg.checkmark", in: cell) != nil)
    }

    @Test("An image's thumbnail replaces the icon once it arrives")
    func thumbnailReplacesIcon() async throws {
        let thumbnails = BrowserFakeThumbnails()
        let cell = makeCell()
        let item = try sampleItem("Beach.jpg")
        cell.configure(with: item, thumbnails: thumbnails, folderAssetAvailable: true)
        let expected = thumbnails.image(for: item.id)
        await BrowserViewSupport.waitUntil { cell.thumbnailView.image === expected }
        #expect(cell.thumbnailView.image === expected)
        #expect(thumbnails.requested().contains(item.id))
    }

    @Test("Reusing the cell cancels the thumbnail of the item it showed")
    func reuseCancelsThumbnail() async throws {
        let thumbnails = BrowserFakeThumbnails()
        let cell = makeCell()
        let item = try sampleItem("Beach.jpg")
        thumbnails.hold(item.id)
        cell.configure(with: item, thumbnails: thumbnails, folderAssetAvailable: true)
        await BrowserViewSupport.waitUntil { thumbnails.isWaiting }
        cell.prepareForReuse()
        #expect(thumbnails.cancelled() == [item.id])
        thumbnails.release(item.id)
    }

    @Test("A thumbnail that arrives after the cell shows another item is ignored")
    func lateThumbnailIgnored() async throws {
        let thumbnails = BrowserFakeThumbnails()
        let cell = makeCell()
        let first = try sampleItem("Beach.jpg")
        let second = try sampleItem("Tax Return 2025.pdf")
        thumbnails.hold(first.id)
        cell.configure(with: first, thumbnails: thumbnails, folderAssetAvailable: true)
        await BrowserViewSupport.waitUntil { thumbnails.isWaiting }
        cell.prepareForReuse()
        cell.configure(with: second, thumbnails: thumbnails, folderAssetAvailable: true)
        thumbnails.release(first.id)
        await BrowserViewSupport.settle()
        #expect(cell.thumbnailView.image !== thumbnails.image(for: first.id))
        #expect(BrowserViewHost.texts(in: cell).contains("Tax Return 2025.pdf"))
        #expect(!BrowserViewHost.texts(in: cell).contains("Beach.jpg"))
    }

    // MARK: - Folder icon size (device test 2026-11-16)

    private func laidOutCell() -> FileCell {
        let cell = makeCell()
        cell.layoutIfNeeded()
        return cell
    }

    @Test("A folder cell asks for its thumbnail at the size of its icon area, not 40 by 40")
    func folderThumbnailRequestedAtIconAreaSize() async throws {
        let thumbnails = BrowserFakeThumbnails()
        let cell = laidOutCell()
        let item = try sampleItem("Photos")
        cell.configure(with: item, thumbnails: thumbnails, folderAssetAvailable: true)
        await BrowserViewSupport.waitUntil { !thumbnails.sizes(for: item.id).isEmpty }
        let size = try #require(thumbnails.sizes(for: item.id).first)
        cell.layoutIfNeeded()
        #expect(size != CGSize(width: 40, height: 40))
        #expect(size.width > 40 && size.height > 40)
        #expect(size == cell.thumbnailView.bounds.size)
    }

    @Test("A folder's plain icon and its thumbnail occupy the same frame")
    func folderIconAndThumbnailShareFrame() async throws {
        let thumbnails = BrowserFakeThumbnails()
        let cell = laidOutCell()
        let item = try sampleItem("Photos")
        thumbnails.hold(item.id)
        cell.configure(with: item, thumbnails: thumbnails, folderAssetAvailable: true)
        await BrowserViewSupport.waitUntil { thumbnails.isWaiting }
        cell.layoutIfNeeded()
        let plainImage = try #require(cell.thumbnailView.image)
        let plainFrame = cell.thumbnailView.frame
        let plainMode = cell.thumbnailView.contentMode
        #expect(plainMode == .scaleAspectFit)

        thumbnails.release(item.id)
        let expected = thumbnails.image(for: item.id)
        await BrowserViewSupport.waitUntil { cell.thumbnailView.image === expected }
        cell.layoutIfNeeded()
        #expect(cell.thumbnailView.image === expected)
        #expect(cell.thumbnailView.image !== plainImage)
        #expect(cell.thumbnailView.frame == plainFrame)
        #expect(cell.thumbnailView.contentMode == plainMode)
    }

    @Test("The plain folder icon is fitted to the cell's 80 pt icon area")
    func plainFolderIconFillsIconArea() async throws {
        let cell = laidOutCell()
        cell.configure(with: try sampleItem("Photos"), thumbnails: BrowserFakeThumbnails(), folderAssetAvailable: true)
        cell.layoutIfNeeded()
        #expect(cell.thumbnailView.bounds.width >= 80)
        #expect(cell.thumbnailView.bounds.height >= 80)
        #expect(cell.thumbnailView.contentMode == .scaleAspectFit)
    }

    @Test("A file cell still asks for its thumbnail at 40 by 40")
    func fileThumbnailSizeUnchanged() async throws {
        let thumbnails = BrowserFakeThumbnails()
        let cell = laidOutCell()
        let item = try sampleItem("Beach.jpg")
        cell.configure(with: item, thumbnails: thumbnails, folderAssetAvailable: true)
        await BrowserViewSupport.waitUntil { !thumbnails.sizes(for: item.id).isEmpty }
        #expect(thumbnails.sizes(for: item.id).first == CGSize(width: 40, height: 40))
    }
}
