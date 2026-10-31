import Foundation
import Testing

@testable import KoalaTVault

// Assumed: `struct PhotoLibraryAccess: CameraRollDeleting` with `init()` (the live Photos wrapper).
// Requesting read-write authorization and deleting real assets need the real photo library and its
// system prompts, so a unit test cannot reach them; they belong to the journey tests.
@Suite struct PhotoLibraryAccessTests {
    @Test("The live photo library access can be used as a CameraRollDeleting")
    func liveAccessIsACameraRollDeleter() {
        let deleter: any CameraRollDeleting = PhotoLibraryAccess()
        #expect(deleter is PhotoLibraryAccess)
    }

    @Test("A camera-roll deleter receives the asset identifiers it is asked to delete, in order")
    func mockRecordsDeleteRequests() async {
        let deleter = MockCameraRollDeleting()
        await deleter.deleteAssets(withIdentifiers: ["a", "b"])
        await deleter.deleteAssets(withIdentifiers: ["c"])
        #expect(deleter.deleteRequests == [["a", "b"], ["c"]])
    }
}
