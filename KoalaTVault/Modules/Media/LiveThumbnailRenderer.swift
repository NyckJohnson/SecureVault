import AVFoundation
import QuickLookThumbnailing
import UIKit

/// The production `ThumbnailRendering`: QuickLook, `AVAssetImageGenerator`, and the folder icon drawing.
final class LiveThumbnailRenderer: ThumbnailRendering {
    private enum FolderIconLayout {
        /// The app's folder image asset (the one SharedUI's icon mapping uses for folders).
        static let assetName = "nej_FolderIconB"
        static let symbolName = "folder.fill"
        static let symbolPointSizeRatio: CGFloat = 0.8
        static let verticalOffsetRatio: CGFloat = 0.075
        static let mediaInsetX: CGFloat = 0.05
        static let mediaInsetY: CGFloat = 0.1
        static let mediaWidthRatio: CGFloat = 0.9
        static let mediaHeightRatio: CGFloat = 0.8
        static let mediaCornerRadius: CGFloat = 3
    }

    init() {}

    func quickLookThumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        // coverage-exempt-begin: QLThumbnailGenerator needs the real QuickLook service
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        // A file QuickLook can't read is not an error for the grid: it shows the kind's icon.
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation?.uiImage
        // coverage-exempt-end
    }

    func videoDuration(of asset: AVURLAsset) async -> TimeInterval? {
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)  // coverage-exempt: needs a real video duration
        return Self.finiteDuration(seconds)  // coverage-exempt: needs a real loaded video duration
    }

    /// `seconds` when it is a usable duration (finite and not negative), otherwise `nil`.
    /// `CMTimeGetSeconds` gives NaN or infinity for indefinite and invalid times.
    static func finiteDuration(_ seconds: Double) -> TimeInterval? {
        seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    func videoFrame(of asset: AVURLAsset, at time: TimeInterval, size: CGSize, scale: CGFloat) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * scale, height: size.height * scale)
        let frameTime = CMTime(seconds: time, preferredTimescale: 600)
        guard let frame = try? await generator.image(at: frameTime) else { return nil }
        return UIImage(cgImage: frame.image)  // coverage-exempt: needs a real AVAssetImageGenerator frame
    }

    func folderIcon(size: CGSize, scale: CGFloat) -> UIImage? {
        let pointSize = size.height * FolderIconLayout.symbolPointSizeRatio
        let folder = Self.folderImage(named: FolderIconLayout.assetName, pointSize: pointSize)
        return UIGraphicsImageRenderer(size: size, format: Self.format(scale: scale)).image { _ in
            var rect = AVMakeRect(aspectRatio: folder.size, insideRect: CGRect(origin: .zero, size: size))
            rect.origin.y += size.height * FolderIconLayout.verticalOffsetRatio
            folder.draw(in: rect)
        }
    }

    func compose(_ media: UIImage, onto folderIcon: UIImage, size: CGSize, scale: CGFloat) -> UIImage? {
        UIGraphicsImageRenderer(size: size, format: Self.format(scale: scale)).image { _ in
            folderIcon.draw(at: .zero)
            let window = CGRect(
                x: size.width * FolderIconLayout.mediaInsetX,
                y: size.height * FolderIconLayout.mediaInsetY,
                width: size.width * FolderIconLayout.mediaWidthRatio,
                height: size.height * FolderIconLayout.mediaHeightRatio)
            UIBezierPath(roundedRect: window, cornerRadius: FolderIconLayout.mediaCornerRadius).addClip()
            media.draw(in: AVMakeRect(aspectRatio: media.size, insideRect: window))
        }
    }

    /// The image named `assetName` when the bundle has it, otherwise the yellow `folder.fill` symbol
    /// at `pointSize`. Internal (not private) so tests can exercise the fallback with a missing name.
    /// `UIImage(systemName:)` is optional in the API but `folder.fill` always exists on iOS; the empty
    /// `UIImage()` keeps the result non-optional without a separate unreachable branch.
    static func folderImage(named assetName: String, pointSize: CGFloat) -> UIImage {
        if let asset = UIImage(named: assetName) { return asset }
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return UIImage(systemName: FolderIconLayout.symbolName)?
            .withConfiguration(configuration)
            .withTintColor(.systemYellow, renderingMode: .alwaysOriginal) ?? UIImage()
    }

    private static func format(scale: CGFloat) -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return format
    }
}
