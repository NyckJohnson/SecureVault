import Foundation
import os

/// An exporter that hands out the items' disk URLs; records every call and every clean-up.
final class MockVaultExporting: VaultExporting {
    /// A recorded call; items are identified by their `id`.
    enum Call: Equatable, Sendable {
        case prepareForSharing([String])
        case saveToPhotos([String])
        case canSaveToPhotos([String])
    }

    private struct State: Sendable {
        var calls: [Call] = []
        var cleanUpCount = 0
        var photoAccessGranted = true
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Every call so far, in order.
    var calls: [Call] { state.withLock { $0.calls } }

    /// How many times a bundle's `cleanUp` ran.
    var cleanUpCount: Int { state.withLock { $0.cleanUpCount } }

    /// Whether saving to the photo library is allowed.
    var photoAccessGranted: Bool {
        get { state.withLock { $0.photoAccessGranted } }
        set { state.withLock { $0.photoAccessGranted = newValue } }
    }

    func prepareForSharing(_ items: [VaultItem]) async throws -> ExportBundle {
        state.withLock { $0.calls.append(.prepareForSharing(items.map(\.id))) }
        guard !items.isEmpty else { throw ExportError.nothingToExport }
        return ExportBundle(urls: items.map(\.diskURL)) { [state] in
            state.withLock { $0.cleanUpCount += 1 }
        }
    }

    func saveToPhotos(_ items: [VaultItem]) async throws -> PhotoSaveResult {
        let granted = state.withLock { state in
            state.calls.append(.saveToPhotos(items.map(\.id)))
            return state.photoAccessGranted
        }
        guard granted else { throw ExportError.photoAccessDenied }
        let media = items.filter(Self.isMedia).count
        return PhotoSaveResult(saved: media, failed: 0, skipped: items.count - media)
    }

    func canSaveToPhotos(_ items: [VaultItem]) -> Bool {
        state.withLock { $0.calls.append(.canSaveToPhotos(items.map(\.id))) }
        return items.contains(where: Self.isMedia)
    }

    private static func isMedia(_ item: VaultItem) -> Bool {
        !item.isDirectory && (item.kind == .image || item.kind == .video)
    }
}
