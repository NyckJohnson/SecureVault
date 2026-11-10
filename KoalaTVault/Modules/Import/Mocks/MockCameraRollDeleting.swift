import Foundation
import os

/// Records the photo library assets it is asked to delete.
final class MockCameraRollDeleting: CameraRollDeleting {
    private let deleted = OSAllocatedUnfairLock<[[String]]>(initialState: [])

    init() {}

    /// The identifier lists of every delete request, in order.
    var deleteRequests: [[String]] { deleted.withLock { $0 } }

    func deleteAssets(withIdentifiers ids: [String]) async {
        deleted.withLock { $0.append(ids) }
    }
}
