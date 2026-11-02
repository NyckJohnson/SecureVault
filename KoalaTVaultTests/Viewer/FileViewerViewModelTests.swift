import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct FileViewerViewModelTests {
    private let store = MockVaultStoring(withSampleContent: false)
    private let sleeper = ViewerManualSleeper()

    private func makeViewModel(
        _ items: [VaultItem]? = nil, startingAt index: Int = 0
    ) -> FileViewerViewModel {
        let sleeper = self.sleeper
        return FileViewerViewModel(
            items: items ?? [
                ViewerTestSupport.makeItem("a.jpg"), ViewerTestSupport.makeItem("b.mp4"),
                ViewerTestSupport.makeItem("c.png"),
            ],
            startingAt: index, store: store, sleep: { try await sleeper.sleep($0) })
    }

    // MARK: - Items and paging

    @Test("Folders are excluded from the viewer's items")
    func foldersExcluded() {
        let vm = makeViewModel([
            ViewerTestSupport.makeItem("Folder", isDirectory: true), ViewerTestSupport.makeItem("a.jpg"),
            ViewerTestSupport.makeItem("Other", isDirectory: true), ViewerTestSupport.makeItem("b.png"),
        ])
        #expect(vm.items.map(\.name) == ["a.jpg", "b.png"])
    }

    @Test("The starting index follows the same item after folders are removed")
    func startingIndexMapsToSameItem() {
        let vm = makeViewModel(
            [
                ViewerTestSupport.makeItem("Folder", isDirectory: true), ViewerTestSupport.makeItem("a.jpg"),
                ViewerTestSupport.makeItem("b.mp4"),
            ], startingAt: 2)
        #expect(vm.currentIndex == 1)
        #expect(vm.title == "b.mp4")
    }

    @Test("The current index and title start at the requested item")
    func startsAtRequestedItem() {
        let vm = makeViewModel(startingAt: 1)
        #expect(vm.currentIndex == 1)
        #expect(vm.title == "b.mp4")
    }

    @Test("Paging updates the current index and title")
    func pagingUpdatesIndexAndTitle() {
        let vm = makeViewModel()
        vm.pageDidChange(to: 2)
        #expect(vm.currentIndex == 2)
        #expect(vm.title == "c.png")
        vm.pageDidChange(to: 0)
        #expect(vm.currentIndex == 0)
        #expect(vm.title == "a.jpg")
    }

    @Test("Neighbours are computed from the page asked about, not the current page")
    func neighboursFromAskedPage() {
        let vm = makeViewModel(startingAt: 0)
        #expect(vm.previousIndex(of: 1) == 0)
        #expect(vm.nextIndex(of: 1) == 2)
        #expect(vm.previousIndex(of: 2) == 1)
    }

    @Test("There is no previous neighbour before the first page and no next after the last")
    func neighboursDoNotWrap() {
        let vm = makeViewModel()
        #expect(vm.previousIndex(of: 0) == nil)
        #expect(vm.nextIndex(of: 2) == nil)
    }

    // MARK: - Video controls

    @Test("Video controls show only for a video item")
    func videoControlsOnlyForVideo() {
        let vm = makeViewModel(startingAt: 0)
        #expect(!vm.showsVideoControls)
        vm.pageDidChange(to: 1)
        #expect(vm.showsVideoControls)
        vm.pageDidChange(to: 2)
        #expect(!vm.showsVideoControls)
    }

    @Test("Audio and other kinds do not get video controls")
    func nonVideoKindsHaveNoVideoControls() {
        let vm = makeViewModel([
            ViewerTestSupport.makeItem("a.mp3"), ViewerTestSupport.makeItem("b.pdf"),
            ViewerTestSupport.makeItem("c.MOV"),
        ])
        #expect(!vm.showsVideoControls)
        vm.pageDidChange(to: 1)
        #expect(!vm.showsVideoControls)
        vm.pageDidChange(to: 2)
        #expect(vm.showsVideoControls)
    }

    // MARK: - Time formatting

    @Test(
        "formatTime writes m:ss",
        arguments: [
            (65.0, "1:05"), (0.0, "0:00"), (9.0, "0:09"), (59.0, "0:59"), (60.0, "1:00"),
            (600.0, "10:00"), (3599.0, "59:59"), (65.9, "1:05"),
        ])
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
        let vm = makeViewModel()
        vm.updatePlayback(currentTime: 25, duration: 100)
        #expect(vm.progress == 0.25)
    }

    @Test("Progress is 0 when the duration is 0")
    func progressZeroDuration() {
        let vm = makeViewModel()
        vm.updatePlayback(currentTime: 5, duration: 0)
        #expect(vm.progress == 0)
    }

    @Test("Skipping forward adds 10 seconds")
    func skipForward() {
        let vm = makeViewModel()
        vm.updatePlayback(currentTime: 20, duration: 100)
        #expect(vm.skipForward() == 30)
        #expect(vm.currentTime == 30)
    }

    @Test("Skipping backward subtracts 10 seconds")
    func skipBackward() {
        let vm = makeViewModel()
        vm.updatePlayback(currentTime: 20, duration: 100)
        #expect(vm.skipBackward() == 10)
        #expect(vm.currentTime == 10)
    }

    @Test("Skipping forward is clamped to the duration")
    func skipForwardClamped() {
        let vm = makeViewModel()
        vm.updatePlayback(currentTime: 95, duration: 100)
        #expect(vm.skipForward() == 100)
        #expect(vm.currentTime == 100)
    }

    @Test("Skipping backward is clamped to 0")
    func skipBackwardClamped() {
        let vm = makeViewModel()
        vm.updatePlayback(currentTime: 4, duration: 100)
        #expect(vm.skipBackward() == 0)
        #expect(vm.currentTime == 0)
    }

    // MARK: - Auto-hiding bars

    @Test("The bars are visible at first")
    func barsVisibleInitially() {
        #expect(makeViewModel().barsVisible)
    }

    @Test("The bars hide 3 seconds after play starts")
    func barsHideAfterPlayStarts() async {
        let vm = makeViewModel()
        vm.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requestedDurations == [.seconds(3)])
        #expect(vm.barsVisible)
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !vm.barsVisible }
        #expect(!vm.barsVisible)
    }

    @Test("Pausing cancels the pending hide and keeps the bars visible")
    func pausingKeepsBars() async {
        let vm = makeViewModel()
        vm.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        vm.playbackStateChanged(isPlaying: false)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 0 }
        sleeper.advance()
        await ViewerTestSupport.settle()
        #expect(vm.barsVisible)
    }

    @Test("Bars do not hide while paused")
    func barsNeverHideWhilePaused() async {
        let vm = makeViewModel()
        await ViewerTestSupport.settle()
        #expect(sleeper.requestedDurations.isEmpty)
        #expect(vm.barsVisible)
    }

    @Test("Scrubbing cancels the hide and the bars stay visible")
    func scrubbingKeepsBars() async {
        let vm = makeViewModel()
        vm.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        vm.scrubbingChanged(true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 0 }
        sleeper.advance()
        await ViewerTestSupport.settle()
        #expect(vm.barsVisible)
    }

    @Test("Finishing a scrub while playing starts a new 3 second hide")
    func scrubEndRestartsHide() async {
        let vm = makeViewModel()
        vm.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        vm.scrubbingChanged(true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 0 }
        vm.scrubbingChanged(false)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requestedDurations.last == .seconds(3))
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !vm.barsVisible }
        #expect(!vm.barsVisible)
    }

    @Test("Finishing a scrub while paused starts no hide")
    func scrubEndWhilePausedNoHide() async {
        let vm = makeViewModel()
        vm.scrubbingChanged(true)
        vm.scrubbingChanged(false)
        await ViewerTestSupport.settle()
        #expect(sleeper.requestedDurations.isEmpty)
        #expect(vm.barsVisible)
    }

    @Test("Showing the bars again while playing restarts the hide")
    func showBarsRestartsHide() async {
        let vm = makeViewModel()
        vm.playbackStateChanged(isPlaying: true)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !vm.barsVisible }
        vm.showBars()
        #expect(vm.barsVisible)
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !vm.barsVisible }
        #expect(!vm.barsVisible)
    }

    // MARK: - Close

    @Test("Closing removes each temp file this viewer registered")
    func closeRemovesOwnTempFiles() {
        let vm = makeViewModel()
        let first = URL(fileURLWithPath: "/tmp/ViewerTestsRoot/temp-1/a.jpg")
        let second = URL(fileURLWithPath: "/tmp/ViewerTestsRoot/temp-2/c.png")
        vm.registerTemporaryFile(first)
        vm.registerTemporaryFile(second)
        vm.close()
        let removed = store.calls.compactMap { call -> URL? in
            if case .removeTemporary(let url) = call { return url }
            return nil
        }
        #expect(Set(removed) == [first, second])
    }

    @Test("Closing never removes all temporary files")
    func closeNeverRemovesAll() {
        let vm = makeViewModel()
        vm.registerTemporaryFile(URL(fileURLWithPath: "/tmp/ViewerTestsRoot/temp-1/a.jpg"))
        vm.close()
        #expect(!store.calls.contains(.removeAllTemporaryFiles))
    }

    @Test("Closing a viewer with no temp files removes nothing")
    func closeWithNoTempFiles() {
        let vm = makeViewModel()
        vm.close()
        #expect(store.calls.isEmpty)
    }
}
