import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct FileViewerViewModelTests {
    private let store = MockVaultStoring(withSampleContent: false)
    private let sleeper = ViewerManualSleeper()

    private static func files(_ names: String...) -> [VaultItem] {
        names.map { ViewerTestSupport.makeItem($0) }
    }

    nonisolated private static let timeCases: [(Double, String)] =
        [(65.0, "1:05"), (0.0, "0:00"), (9.0, "0:09"), (59.0, "0:59")]
        + [(60.0, "1:00"), (600.0, "10:00"), (3599.0, "59:59"), (65.9, "1:05")]

    private func makeViewModel(
        _ items: [VaultItem]? = nil, startingAt index: Int = 0
    ) -> FileViewerViewModel {
        let sleeper = self.sleeper
        return FileViewerViewModel(
            items: items ?? Self.files("a.jpg", "b.mp4", "c.png"),
            startingAt: index, store: store, sleep: { try await sleeper.sleep($0) })
    }

    // MARK: - Items and paging

    @Test("Folders are excluded from the viewer's items")
    func foldersExcluded() {
        let folderA = ViewerTestSupport.makeItem("Folder", isDirectory: true)
        let folderB = ViewerTestSupport.makeItem("Other", isDirectory: true)
        let files = Self.files("a.jpg", "b.png")
        let viewModel = makeViewModel([folderA, files[0], folderB, files[1]])
        #expect(viewModel.items.map(\.name) == ["a.jpg", "b.png"])
    }

    @Test("The starting index follows the same item after folders are removed")
    func startingIndexMapsToSameItem() {
        let folder = ViewerTestSupport.makeItem("Folder", isDirectory: true)
        let files = Self.files("a.jpg", "b.mp4")
        let viewModel = makeViewModel([folder, files[0], files[1]], startingAt: 2)
        #expect(viewModel.currentIndex == 1)
        #expect(viewModel.title == "b.mp4")
    }

    @Test("The current index and title start at the requested item")
    func startsAtRequestedItem() {
        let viewModel = makeViewModel(startingAt: 1)
        #expect(viewModel.currentIndex == 1)
        #expect(viewModel.title == "b.mp4")
    }

    @Test("Paging updates the current index and title")
    func pagingUpdatesIndexAndTitle() {
        let viewModel = makeViewModel()
        viewModel.pageDidChange(to: 2)
        #expect(viewModel.currentIndex == 2)
        #expect(viewModel.title == "c.png")
        viewModel.pageDidChange(to: 0)
        #expect(viewModel.currentIndex == 0)
        #expect(viewModel.title == "a.jpg")
    }

    @Test("Neighbours are computed from the page asked about, not the current page")
    func neighboursFromAskedPage() {
        let viewModel = makeViewModel(startingAt: 0)
        #expect(viewModel.previousIndex(of: 1) == 0)
        #expect(viewModel.nextIndex(of: 1) == 2)
        #expect(viewModel.previousIndex(of: 2) == 1)
    }

    @Test("There is no previous neighbour before the first page and no next after the last")
    func neighboursDoNotWrap() {
        let viewModel = makeViewModel()
        #expect(viewModel.previousIndex(of: 0) == nil)
        #expect(viewModel.nextIndex(of: 2) == nil)
    }

    // MARK: - Video controls

    @Test("Video controls show only for a video item")
    func videoControlsOnlyForVideo() {
        let viewModel = makeViewModel(startingAt: 0)
        #expect(!viewModel.showsVideoControls)
        viewModel.pageDidChange(to: 1)
        #expect(viewModel.showsVideoControls)
        viewModel.pageDidChange(to: 2)
        #expect(!viewModel.showsVideoControls)
    }

    @Test("Audio and other kinds do not get video controls")
    func nonVideoKindsHaveNoVideoControls() {
        let viewModel = makeViewModel(Self.files("a.mp3", "b.pdf", "c.MOV"))
        #expect(!viewModel.showsVideoControls)
        viewModel.pageDidChange(to: 1)
        #expect(!viewModel.showsVideoControls)
        viewModel.pageDidChange(to: 2)
        #expect(viewModel.showsVideoControls)
    }

    // MARK: - Time formatting

    @Test(
        "formatTime writes m:ss",
        arguments: Self.timeCases)
    func formatTimeOrdinary(seconds: Double, expected: String) {
        #expect(FileViewerViewModel.formatTime(seconds) == expected)
    }

    @Test("formatTime gives 0:00 for NaN, infinite and negative values")
    func formatTimeInvalid() {
        #expect(FileViewerViewModel.formatTime(.nan) == "0:00")
        #expect(FileViewerViewModel.formatTime(.infinity) == "0:00")
        #expect(FileViewerViewModel.formatTime(-5) == "0:00")
    }

    // MARK: - Progress and skipping

    @Test("Progress is the fraction of the duration played")
    func progressFraction() {
        let viewModel = makeViewModel()
        viewModel.updatePlayback(currentTime: 25, duration: 100)
        #expect(viewModel.progress == 0.25)
    }

    @Test("Progress is 0 when the duration is 0")
    func progressZeroDuration() {
        let viewModel = makeViewModel()
        viewModel.updatePlayback(currentTime: 5, duration: 0)
        #expect(viewModel.progress == 0)
    }

    @Test("Skipping forward adds 10 seconds")
    func skipForward() {
        let viewModel = makeViewModel()
        viewModel.updatePlayback(currentTime: 20, duration: 100)
        #expect(viewModel.skipForward() == 30)
        #expect(viewModel.currentTime == 30)
    }

    @Test("Skipping backward subtracts 10 seconds")
    func skipBackward() {
        let viewModel = makeViewModel()
        viewModel.updatePlayback(currentTime: 20, duration: 100)
        #expect(viewModel.skipBackward() == 10)
        #expect(viewModel.currentTime == 10)
    }

    @Test("Skipping forward is clamped to the duration")
    func skipForwardClamped() {
        let viewModel = makeViewModel()
        viewModel.updatePlayback(currentTime: 95, duration: 100)
        #expect(viewModel.skipForward() == 100)
        #expect(viewModel.currentTime == 100)
    }

    @Test("Skipping backward is clamped to 0")
    func skipBackwardClamped() {
        let viewModel = makeViewModel()
        viewModel.updatePlayback(currentTime: 4, duration: 100)
        #expect(viewModel.skipBackward() == 0)
        #expect(viewModel.currentTime == 0)
    }

    @Test("Skipping with an unknown duration leaves the time alone and returns it")
    func skipWithZeroDuration() {
        let viewModel = makeViewModel()
        viewModel.updatePlayback(currentTime: 5, duration: 0)
        #expect(viewModel.skipForward() == 5)
        #expect(viewModel.currentTime == 5)
        #expect(viewModel.skipBackward() == 5)
        #expect(viewModel.currentTime == 5)
    }

    // MARK: - Auto-hiding bars

    @Test("The bars are visible at first")
    func barsVisibleInitially() {
        #expect(makeViewModel().barsVisible)
    }

    @Test("The bars hide 3 seconds after play starts")
    func barsHideAfterPlayStarts() async {
        let viewModel = makeViewModel()
        viewModel.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requestedDurations == [.seconds(3)])
        #expect(viewModel.barsVisible)
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !viewModel.barsVisible }
        #expect(!viewModel.barsVisible)
    }

    @Test("Pausing cancels the pending hide and keeps the bars visible")
    func pausingKeepsBars() async {
        let viewModel = makeViewModel()
        viewModel.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        viewModel.playbackStateChanged(isPlaying: false)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 0 }
        sleeper.advance()
        await ViewerTestSupport.settle()
        #expect(viewModel.barsVisible)
    }

    @Test("Bars do not hide while paused")
    func barsNeverHideWhilePaused() async {
        let viewModel = makeViewModel()
        await ViewerTestSupport.settle()
        #expect(sleeper.requestedDurations.isEmpty)
        #expect(viewModel.barsVisible)
    }

    @Test("Scrubbing cancels the hide and the bars stay visible")
    func scrubbingKeepsBars() async {
        let viewModel = makeViewModel()
        viewModel.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        viewModel.scrubbingChanged(true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 0 }
        sleeper.advance()
        await ViewerTestSupport.settle()
        #expect(viewModel.barsVisible)
    }

    @Test("Finishing a scrub while playing starts a new 3 second hide")
    func scrubEndRestartsHide() async {
        let viewModel = makeViewModel()
        viewModel.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        viewModel.scrubbingChanged(true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 0 }
        viewModel.scrubbingChanged(false)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requestedDurations.last == .seconds(3))
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !viewModel.barsVisible }
        #expect(!viewModel.barsVisible)
    }

    @Test("Finishing a scrub while paused starts no hide")
    func scrubEndWhilePausedNoHide() async {
        let viewModel = makeViewModel()
        viewModel.scrubbingChanged(true)
        viewModel.scrubbingChanged(false)
        await ViewerTestSupport.settle()
        #expect(sleeper.requestedDurations.isEmpty)
        #expect(viewModel.barsVisible)
    }

    @Test("Showing the bars again while playing restarts the hide")
    func showBarsRestartsHide() async {
        let viewModel = makeViewModel()
        viewModel.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !viewModel.barsVisible }
        viewModel.showBars()
        #expect(viewModel.barsVisible)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !viewModel.barsVisible }
        #expect(!viewModel.barsVisible)
    }

    @Test("Closing while playing keeps the bars visible when the hide delay passes")
    func closeCancelsPendingHide() async {
        let viewModel = makeViewModel()
        viewModel.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        viewModel.close()
        sleeper.advance()
        await ViewerTestSupport.settle()
        #expect(viewModel.barsVisible)
    }

    @Test("Playback starting after close requests no hide")
    func playAfterCloseStartsNoHide() async {
        let viewModel = makeViewModel()
        viewModel.close()
        viewModel.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.settle()
        #expect(sleeper.requestedDurations.isEmpty)
        #expect(viewModel.barsVisible)
    }

    // MARK: - Toggling the bars

    @Test("Toggling visible bars hides them")
    func toggleHidesVisibleBars() {
        let viewModel = makeViewModel()
        viewModel.toggleBars()
        #expect(!viewModel.barsVisible)
    }

    @Test("Toggling hidden bars shows them")
    func toggleShowsHiddenBars() {
        let viewModel = makeViewModel()
        viewModel.toggleBars()
        viewModel.toggleBars()
        #expect(viewModel.barsVisible)
    }

    @Test("Showing the bars by toggle while playing restarts the 3 second hide")
    func toggleShowWhilePlayingRestartsHide() async {
        let viewModel = makeViewModel()
        viewModel.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        viewModel.toggleBars()
        viewModel.toggleBars()
        #expect(viewModel.barsVisible)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 && sleeper.requestedDurations.count >= 2 }
        #expect(sleeper.requestedDurations.last == .seconds(3))
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !viewModel.barsVisible }
        #expect(!viewModel.barsVisible)
    }

    @Test("Hiding the bars by toggle cancels the pending hide")
    func toggleHideCancelsPendingHide() async {
        let viewModel = makeViewModel()
        viewModel.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        viewModel.toggleBars()
        #expect(!viewModel.barsVisible)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 0 }
        #expect(sleeper.pendingCount == 0)
        #expect(sleeper.requestedDurations.count == 1)
    }

    @Test("Showing the bars by toggle while paused starts no timer")
    func toggleShowWhilePausedStartsNoTimer() async {
        let viewModel = makeViewModel()
        viewModel.toggleBars()
        viewModel.toggleBars()
        await ViewerTestSupport.settle()
        #expect(viewModel.barsVisible)
        #expect(sleeper.requestedDurations.isEmpty)
    }

    // MARK: - Close

    @Test("Closing removes each temp file this viewer registered")
    func closeRemovesOwnTempFiles() {
        let viewModel = makeViewModel()
        let first = URL(fileURLWithPath: "/tmp/ViewerTestsRoot/temp-1/a.jpg")
        let second = URL(fileURLWithPath: "/tmp/ViewerTestsRoot/temp-2/c.png")
        viewModel.registerTemporaryFile(first)
        viewModel.registerTemporaryFile(second)
        viewModel.close()
        let removed = store.calls.compactMap { call -> URL? in
            if case .removeTemporary(let url) = call { return url }
            return nil
        }
        #expect(Set(removed) == [first, second])
    }

    @Test("Closing never removes all temporary files")
    func closeNeverRemovesAll() {
        let viewModel = makeViewModel()
        viewModel.registerTemporaryFile(URL(fileURLWithPath: "/tmp/ViewerTestsRoot/temp-1/a.jpg"))
        viewModel.close()
        #expect(!store.calls.contains(.removeAllTemporaryFiles))
    }

    @Test("Closing a viewer with no temp files removes nothing")
    func closeWithNoTempFiles() {
        let viewModel = makeViewModel()
        viewModel.close()
        #expect(store.calls.isEmpty)
    }

    @Test("A temp file registered after close is removed at once")
    func lateTempFileRemovedAtOnce() {
        let viewModel = makeViewModel()
        viewModel.close()
        let late = URL(fileURLWithPath: "/tmp/ViewerTestsRoot/temp-late/a.jpg")
        viewModel.registerTemporaryFile(late)
        #expect(store.calls.contains(.removeTemporary(late)))
    }

    @Test("A page that finishes opening after the viewer closed has its copy removed, not left behind")
    func pageOpeningAfterCloseCopyRemoved() async throws {
        let stored = try await store.addFile(
            from: URL(fileURLWithPath: "/tmp/ViewerTestsSource"), named: "Late.jpg", to: store.root)
        let encrypted = VaultItem(
            id: stored.id, name: stored.name, isDirectory: false, dateModified: stored.dateModified,
            fileSize: stored.fileSize, deletedAt: nil, diskURL: stored.diskURL, rootURL: stored.rootURL,
            isEncrypted: true)
        let viewModel = makeViewModel([encrypted])
        let page = FilePageViewModel(
            item: encrypted, store: store, videoAssets: MockVideoAssetProviding(),
            onTemporaryFile: { viewModel.registerTemporaryFile($0) })
        viewModel.close()
        await page.load()
        #expect(store.calls.contains(.removeTemporary(encrypted.diskURL)))
    }
}
