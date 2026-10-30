import Testing
import UIKit

@testable import KoalaTVault

@Suite struct LiveThumbnailRendererFolderImageTests {
    /// Whether any opaque-ish pixel is yellow-ish (strong red and green, weak blue).
    private static func hasYellowishPixel(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
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
        guard drew else { return false }
        return stride(from: 0, to: data.count, by: 4).contains { offset in
            let alpha = Int(data[offset + 3])
            guard alpha > 200 else { return false }
            return Int(data[offset]) > 150 && Int(data[offset + 1]) > 120 && Int(data[offset + 2]) < 100
        }
    }

    @Test("A folder image for a bogus asset name falls back to a non-empty symbol image")
    func bogusAssetNameFallsBackToSymbol() {
        let image = LiveThumbnailRenderer.folderImage(named: "no-such-asset-\(UUID().uuidString)", pointSize: 40)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test("The folder image fallback is drawn in a yellow-ish color")
    func fallbackSymbolIsYellowish() {
        let image = LiveThumbnailRenderer.folderImage(named: "no-such-asset-\(UUID().uuidString)", pointSize: 40)
        #expect(Self.hasYellowishPixel(image))
    }
}
