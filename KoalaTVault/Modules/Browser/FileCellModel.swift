import Combine
import Foundation
import UIKit

/// The logic of one grid cell: the shown item's name, size text and icon, and its thumbnail, which is
/// cancelled on reuse and dropped if the cell shows another item by the time it arrives.
@MainActor
final class FileCellModel: ObservableObject {
    /// The item the cell shows, if any.
    @Published private(set) var item: VaultItem?

    private let thumbnails: any ThumbnailProviding
    private let folderAssetAvailable: Bool

    /// - Parameters:
    ///   - thumbnails: makes and caches thumbnails.
    ///   - folderAssetAvailable: whether the bundle has the folder image.
    init(thumbnails: any ThumbnailProviding, folderAssetAvailable: Bool) {
        self.thumbnails = thumbnails
        self.folderAssetAvailable = folderAssetAvailable
    }

    /// The cell now shows `item`.
    func configure(with item: VaultItem) {
        self.item = item
    }

    /// Cancels the shown item's thumbnail request and clears the cell.
    func prepareForReuse() {
        if let item {
            thumbnails.cancel(item)
        }
        item = nil
    }

    /// The shown item's name, or "" with no item.
    var name: String { item?.name ?? "" }

    /// The file's size in the file byte-count style; "" for folders and with no item.
    var sizeText: String {
        guard let item, !item.isDirectory, let size = item.fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// The shown item's icon, or nil with no item.
    var icon: FileIcon? {
        guard let item else { return nil }
        return FileIconMapping.icon(
            for: item.kind, isDirectory: item.isDirectory, folderAssetAvailable: folderAssetAvailable)
    }

    /// The shown item's thumbnail; nil if there is none, or if the cell shows a different item (or
    /// none) by the time it arrives.
    func thumbnail(size: CGSize, scale: CGFloat) async -> UIImage? {
        guard let requested = item else { return nil }
        let image = await thumbnails.thumbnail(for: requested, size: size, scale: scale)
        guard item?.id == requested.id else { return nil }
        return image
    }
}
