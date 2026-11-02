import AVFoundation
import Foundation
import Testing

@testable import KoalaTVault

@MainActor
final class ReportedURLs {
    var urls: [URL] = []
}

@MainActor
@Suite struct FilePageViewModelTests {
    private let store = MockVaultStoring(withSampleContent: false)
    private let videoAssets = MockVideoAssetProviding()

    private func makeStoredItem(_ name: String, encrypted: Bool = false) async throws -> VaultItem {
        let item = try await store.addFile(
            from: URL(fileURLWithPath: "/tmp/ViewerTestsSource"), named: name, to: store.root)
        guard encrypted else { return item }
        return VaultItem(
            id: item.id, name: item.name, isDirectory: false, dateModified: item.dateModified,
            fileSize: item.fileSize, deletedAt: nil, diskURL: item.diskURL, rootURL: item.rootURL,
            isEncrypted: true)
    }

    private func makeViewModel(
        _ item: VaultItem, onTemporaryFile: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> FilePageViewModel {
        FilePageViewModel(
            item: item, store: store, videoAssets: videoAssets, onTemporaryFile: onTemporaryFile)
    }

    // MARK: - Routing

    @Test("An image opens as a zoomable image of the opened file")
    func imageRouting() async throws {
        let item = try await makeStoredItem("Photo.jpg")
        let viewModel = makeViewModel(item)
        await viewModel.load()
        #expect(viewModel.content == .image(item.diskURL))
        #expect(store.calls.contains(.open(item.id)))
    }

    @Test("An .rtf file opens the editor")
    func rtfRouting() async throws {
        let item = try await makeStoredItem("Note.rtf")
        let viewModel = makeViewModel(item)
        await viewModel.load()
        #expect(viewModel.content == .editor)
    }

    @Test("An .RTF extension in capitals also opens the editor")
    func rtfUppercaseRouting() async throws {
        let item = try await makeStoredItem("NOTE.RTF")
        let viewModel = makeViewModel(item)
        await viewModel.load()
        #expect(viewModel.content == .editor)
    }

    @Test(
        "Other kinds are previewed with QuickLook of the opened file",
        arguments: ["Report.pdf", "Notes.txt", "Readme.md", "Song.mp3", "Sheet.xlsx", "Archive.zip", "Blob.xyz"])
    func otherKindsRouting(name: String) async throws {
        let item = try await makeStoredItem(name)
        let viewModel = makeViewModel(item)
        await viewModel.load()
        #expect(viewModel.content == .document(item.diskURL))
    }

    @Test("A video page shows the video content")
    func videoRouting() async throws {
        let item = try await makeStoredItem("Clip.mp4")
        let viewModel = makeViewModel(item)
        viewModel.setVisible(true)
        await viewModel.load()
        #expect(viewModel.content == .video)
    }

    // MARK: - Shared player

    @Test("A video page that is not visible does not take the shared player")
    func hiddenVideoDoesNotTakePlayer() async throws {
        let item = try await makeStoredItem("Clip.mp4")
        let viewModel = makeViewModel(item)
        await viewModel.load()
        #expect(viewModel.playerAsset == nil)
        #expect(videoAssets.requestedIDs.isEmpty)
    }

    @Test("A video page takes the shared player when it becomes visible")
    func visibleVideoTakesPlayer() async throws {
        let item = try await makeStoredItem("Clip.mp4")
        let viewModel = makeViewModel(item)
        await viewModel.load()
        viewModel.setVisible(true)
        #expect(viewModel.playerAsset != nil)
        #expect(videoAssets.requestedIDs == [item.id])
    }

    @Test("A video page that was made visible before loading takes the player once loaded")
    func visibleBeforeLoadTakesPlayer() async throws {
        let item = try await makeStoredItem("Clip.mp4")
        let viewModel = makeViewModel(item)
        viewModel.setVisible(true)
        await viewModel.load()
        #expect(viewModel.playerAsset != nil)
        #expect(videoAssets.requestedIDs == [item.id])
    }

    @Test("A video page lets go of the shared player when it stops being visible")
    func leavingVideoReleasesPlayer() async throws {
        let item = try await makeStoredItem("Clip.mp4")
        let viewModel = makeViewModel(item)
        await viewModel.load()
        viewModel.setVisible(true)
        viewModel.setVisible(false)
        #expect(viewModel.playerAsset == nil)
    }

    @Test("A visible non-video page never asks for a player asset")
    func nonVideoNeverTakesPlayer() async throws {
        let item = try await makeStoredItem("Photo.jpg")
        let viewModel = makeViewModel(item)
        viewModel.setVisible(true)
        await viewModel.load()
        #expect(viewModel.playerAsset == nil)
        #expect(videoAssets.requestedIDs.isEmpty)
    }

    @Test("A video whose asset cannot be made shows the can't-be-opened message")
    func videoAssetFailure() async throws {
        let item = try await makeStoredItem("Clip.mp4")
        videoAssets.errorToThrow = .noKeyLoaded
        let viewModel = makeViewModel(item)
        viewModel.setVisible(true)
        await viewModel.load()
        #expect(viewModel.content == .failed("This file can't be opened."))
        #expect(viewModel.playerAsset == nil)
    }

    // MARK: - Failure

    @Test("A file that fails to open shows \"This file can't be opened.\"")
    func openFailure() async throws {
        let item = try await makeStoredItem("Photo.jpg")
        store.errorToThrow = .notFound
        let viewModel = makeViewModel(item)
        await viewModel.load()
        #expect(viewModel.content == .failed("This file can't be opened."))
    }

    @Test("A document that fails to open is not handed to QuickLook")
    func documentFailureNotPreviewed() async throws {
        let item = try await makeStoredItem("Report.pdf")
        store.errorToThrow = .locked
        let viewModel = makeViewModel(item)
        await viewModel.load()
        #expect(viewModel.content == .failed("This file can't be opened."))
    }

    @Test("Reporting a failure shows the can't-be-opened message and lets go of the player")
    func reportFailureShowsMessage() async throws {
        let item = try await makeStoredItem("Clip.mp4")
        let viewModel = makeViewModel(item)
        viewModel.setVisible(true)
        await viewModel.load()
        #expect(viewModel.playerAsset != nil)
        viewModel.reportFailure()
        #expect(viewModel.content == .failed("This file can't be opened."))
        #expect(viewModel.playerAsset == nil)
    }

    @Test("Reporting a failure twice is safe")
    func reportFailureTwice() async throws {
        let item = try await makeStoredItem("Photo.jpg")
        let viewModel = makeViewModel(item)
        await viewModel.load()
        viewModel.reportFailure()
        viewModel.reportFailure()
        #expect(viewModel.content == .failed("This file can't be opened."))
        #expect(viewModel.playerAsset == nil)
    }

    @Test("A later load replaces a reported failure")
    func loadReplacesReportedFailure() async throws {
        let item = try await makeStoredItem("Photo.jpg")
        let viewModel = makeViewModel(item)
        viewModel.reportFailure()
        await viewModel.load()
        #expect(viewModel.content == .image(item.diskURL))
    }

    // MARK: - Temp files

    @Test("The opened copy of an encrypted file is reported as a temp file")
    func encryptedOpenReported() async throws {
        let item = try await makeStoredItem("Photo.jpg", encrypted: true)
        let reported = ReportedURLs()
        let viewModel = makeViewModel(item) { reported.urls.append($0) }
        await viewModel.load()
        #expect(reported.urls == [item.diskURL])
    }

    @Test("An unencrypted file's own disk URL is not reported as a temp file")
    func plainOpenNotReported() async throws {
        let item = try await makeStoredItem("Photo.jpg")
        let reported = ReportedURLs()
        let viewModel = makeViewModel(item) { reported.urls.append($0) }
        await viewModel.load()
        #expect(reported.urls.isEmpty)
    }

    @Test("A failed open reports no temp file")
    func failedOpenNotReported() async throws {
        let item = try await makeStoredItem("Photo.jpg", encrypted: true)
        store.errorToThrow = .notFound
        let reported = ReportedURLs()
        let viewModel = makeViewModel(item) { reported.urls.append($0) }
        await viewModel.load()
        #expect(reported.urls.isEmpty)
    }
}
