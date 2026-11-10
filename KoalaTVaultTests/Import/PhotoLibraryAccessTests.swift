import Foundation
import Testing

@testable import KoalaTVault

// Assumed: `struct PhotoLibraryAccess: CameraRollDeleting` with `init()` (the live Photos wrapper).
// Deleting real assets needs the real photo library and its system confirmation, so a unit test can
// only cover the call that needs no assets; the rest belongs to the journey tests.
@Suite struct PhotoLibraryAccessTests {
    @Test("Deleting an empty list of assets completes without a prompt")
    func deletingNoAssetsCompletes() async {
        await PhotoLibraryAccess().deleteAssets(withIdentifiers: [])
    }
}
