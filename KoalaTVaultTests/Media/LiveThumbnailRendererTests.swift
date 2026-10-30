import AVFoundation
import Foundation
import Testing
import UIKit

@testable import KoalaTVault

@Suite struct LiveThumbnailRendererTests {
    private let renderer = LiveThumbnailRenderer()
    private let size = CGSize(width: 100, height: 100)

    // MARK: Pixel helpers

    private struct Pixel: Equatable {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int

        func isClose(to other: Pixel, tolerance: Int = 4) -> Bool {
            abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance
                && abs(blue - other.blue) <= tolerance && abs(alpha - other.alpha) <= tolerance
        }
    }

    private static let red = Pixel(red: 255, green: 0, blue: 0, alpha: 255)
    private static let green = Pixel(red: 0, green: 255, blue: 0, alpha: 255)
    private static let blue = Pixel(red: 0, green: 0, blue: 255, alpha: 255)

    /// A solid image whose point size equals its pixel size.
    private static func solidImage(_ color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let data: [UInt8]
    }

    /// The premultiplied RGBA pixels of the image, row 0 at the top.
    private static func pixels(of image: UIImage) -> Bitmap? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drew = data.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? Bitmap(width: width, height: height, data: data) : nil
    }

    private static func pixel(in image: UIImage, x: Int, y: Int) -> Pixel? {
        guard let bitmap = pixels(of: image), x < bitmap.width, y < bitmap.height else { return nil }
        let offset = (y * bitmap.width + x) * 4
        return Pixel(
            red: Int(bitmap.data[offset]), green: Int(bitmap.data[offset + 1]),
            blue: Int(bitmap.data[offset + 2]), alpha: Int(bitmap.data[offset + 3]))
    }

    private static func hasVisiblePixel(_ image: UIImage) -> Bool {
        guard let bitmap = pixels(of: image) else { return false }
        return stride(from: 3, to: bitmap.data.count, by: 4).contains { bitmap.data[$0] > 0 }
    }

    private func missingAsset(extension fileExtension: String = "mp4") -> AVURLAsset {
        AVURLAsset(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString).\(fileExtension)"))
    }

    private func garbageAsset() -> (asset: AVURLAsset, directory: MediaTestDirectory) {
        let directory = MediaTestDirectory()
        let url = directory.file("garbage.mp4", Data((0..<2048).map { UInt8($0 % 251) }))
        return (AVURLAsset(url: url), directory)
    }

    // MARK: QuickLook

    @Test("QuickLook from an already cancelled task gives nil")
    func quickLookCancelledGivesNil() async {
        let renderer = renderer
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let size = size
        let task = Task { () -> UIImage? in
            while !Task.isCancelled { await Task.yield() }
            return await renderer.quickLookThumbnail(for: url, size: size, scale: 1)
        }
        task.cancel()
        #expect(await task.value == nil)
    }

    // MARK: Video

    @Test("The duration of a nonexistent asset is nil")
    func durationOfMissingAssetIsNil() async {
        #expect(await renderer.videoDuration(of: missingAsset()) == nil)
    }

    @Test("The duration of a garbage file is nil")
    func durationOfGarbageIsNil() async {
        let garbage = garbageAsset()
        #expect(await renderer.videoDuration(of: garbage.asset) == nil)
    }

    @Test("A video frame from an already cancelled task gives nil")
    func videoFrameCancelledGivesNil() async {
        let renderer = renderer
        let asset = missingAsset()
        let size = size
        let task = Task { () -> UIImage? in
            while !Task.isCancelled { await Task.yield() }
            return await renderer.videoFrame(of: asset, at: 0, size: size, scale: 1)
        }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test("A video frame of a nonexistent asset is nil")
    func videoFrameOfMissingAssetIsNil() async {
        #expect(await renderer.videoFrame(of: missingAsset(), at: 0, size: size, scale: 1) == nil)
    }

    @Test("A video frame of a garbage file is nil")
    func videoFrameOfGarbageIsNil() async {
        let garbage = garbageAsset()
        #expect(await renderer.videoFrame(of: garbage.asset, at: 0, size: size, scale: 1) == nil)
    }

    // MARK: Folder icon

    @Test("The folder icon has the requested point size and is not blank")
    func folderIconSizeAndContent() throws {
        let icon = try #require(renderer.folderIcon(size: CGSize(width: 120, height: 90), scale: 1))
        #expect(icon.size == CGSize(width: 120, height: 90))
        #expect(Self.hasVisiblePixel(icon))
    }

    @Test("Rendered images carry the requested scale", arguments: [1, 2, 3] as [CGFloat])
    func renderedScale(scale: CGFloat) throws {
        let icon = try #require(renderer.folderIcon(size: size, scale: scale))
        #expect(icon.scale == scale)
        #expect(icon.cgImage?.width == Int(size.width * scale))
        #expect(icon.cgImage?.height == Int(size.height * scale))

        let media = Self.solidImage(.green, size: CGSize(width: 10, height: 10))
        let composed = try #require(renderer.compose(media, onto: icon, size: size, scale: scale))
        #expect(composed.scale == scale)
        #expect(composed.size == size)
        #expect(composed.cgImage?.width == Int(size.width * scale))
    }

    // MARK: Compose

    @Test("Composing draws the media inside the window and the folder outside it")
    func composeWindow() throws {
        let folder = Self.solidImage(.blue, size: size)
        let media = Self.solidImage(.green, size: size)
        let composed = try #require(renderer.compose(media, onto: folder, size: size, scale: 1))
        #expect(composed.size == size)
        #expect(try #require(Self.pixel(in: composed, x: 50, y: 50)).isClose(to: Self.green))
        #expect(try #require(Self.pixel(in: composed, x: 2, y: 50)).isClose(to: Self.blue))
        #expect(try #require(Self.pixel(in: composed, x: 97, y: 50)).isClose(to: Self.blue))
        #expect(try #require(Self.pixel(in: composed, x: 50, y: 4)).isClose(to: Self.blue))
        #expect(try #require(Self.pixel(in: composed, x: 50, y: 95)).isClose(to: Self.blue))
    }

    @Test("A non-square media image keeps its aspect ratio inside the window")
    func composeNonSquareMedia() throws {
        let folder = Self.solidImage(.blue, size: size)
        let media = Self.solidImage(.green, size: CGSize(width: 200, height: 100))
        let composed = try #require(renderer.compose(media, onto: folder, size: size, scale: 1))
        // The window is 90x80 at (5, 10); a 2:1 image fits 90x45, centred vertically (y 27.5 to 72.5).
        #expect(try #require(Self.pixel(in: composed, x: 50, y: 50)).isClose(to: Self.green))
        #expect(try #require(Self.pixel(in: composed, x: 50, y: 15)).isClose(to: Self.blue))
        #expect(try #require(Self.pixel(in: composed, x: 50, y: 85)).isClose(to: Self.blue))
    }

    @Test("A tall media image is fitted to the window height")
    func composeTallMedia() throws {
        let folder = Self.solidImage(.blue, size: size)
        let media = Self.solidImage(.green, size: CGSize(width: 50, height: 100))
        let composed = try #require(renderer.compose(media, onto: folder, size: size, scale: 1))
        // A 1:2 image fits 40x80, centred horizontally (x 30 to 70).
        #expect(try #require(Self.pixel(in: composed, x: 50, y: 50)).isClose(to: Self.green))
        #expect(try #require(Self.pixel(in: composed, x: 15, y: 50)).isClose(to: Self.blue))
        #expect(try #require(Self.pixel(in: composed, x: 85, y: 50)).isClose(to: Self.blue))
    }
}
