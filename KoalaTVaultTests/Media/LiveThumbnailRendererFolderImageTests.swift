import Testing
import UIKit

@testable import KoalaTVault

@Suite struct LiveThumbnailRendererFolderImageTests {
    @Test("A folder image for a bogus asset name falls back to a non-empty symbol image")
    func bogusAssetNameFallsBackToSymbol() throws {
        let image = try #require(
            LiveThumbnailRenderer.folderImage(named: "no-such-asset-\(UUID().uuidString)", pointSize: 40))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}
