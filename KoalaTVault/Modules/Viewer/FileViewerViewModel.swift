import Combine
import Foundation

/// The logic of the full-screen viewer: paging, video controls, auto-hiding bars and temp-file cleanup.
@MainActor
final class FileViewerViewModel: ObservableObject {
    /// The files being paged through; folders are removed.
    let items: [VaultItem]

    @Published private(set) var currentIndex: Int
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var barsVisible = true

    private let store: any VaultStoring
    private let sleep: @Sendable (Duration) async throws -> Void
    private var temporaryFiles: Set<URL> = []
    private var isClosed = false
    private var isPlaying = false
    private var isScrubbing = false
    private var hideTask: Task<Void, Never>?

    /// - Parameters:
    ///   - items: the items to page through; folders are dropped.
    ///   - index: an index into `items` as given, mapped to the same item once folders are removed.
    ///   - sleep: waits out the bars' auto-hide delay.
    init(
        items: [VaultItem], startingAt index: Int, store: any VaultStoring,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let files = items.filter { !$0.isDirectory }
        self.items = files
        // The number of files before `index` is the file's position once the folders are gone.
        let filesBefore = items.prefix(max(index, 0)).filter { !$0.isDirectory }.count
        self.currentIndex = min(filesBefore, max(files.count - 1, 0))
        self.store = store
        self.sleep = sleep
    }

    deinit {
        hideTask?.cancel()
    }

    // MARK: - Paging

    /// The current item's name.
    var title: String {
        items.indices.contains(currentIndex) ? items[currentIndex].name : ""
    }

    /// Whether the current item gets the video controls.
    var showsVideoControls: Bool {
        items.indices.contains(currentIndex) && items[currentIndex].kind == .video
    }

    func pageDidChange(to index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }

    /// The page before `index`, with no wrap. Asked about a page, not `currentIndex`: the pager can ask for
    /// a new page's neighbours before it reports the page change.
    func previousIndex(of index: Int) -> Int? {
        guard items.indices.contains(index), items.indices.contains(index - 1) else { return nil }
        return index - 1
    }

    /// The page after `index`, with no wrap.
    func nextIndex(of index: Int) -> Int? {
        guard items.indices.contains(index), items.indices.contains(index + 1) else { return nil }
        return index + 1
    }

    // MARK: - Playback

    /// `seconds` as "m:ss"; "0:00" for NaN, infinite, negative or unrepresentably large values.
    nonisolated static func formatTime(_ seconds: Double) -> String {
        guard seconds >= 0, let whole = Int(exactly: seconds.rounded(.down)) else { return "0:00" }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The fraction of the duration played; 0 when the duration is 0.
    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    /// Records the player's position; values that aren't finite (an unknown duration) count as 0.
    func updatePlayback(currentTime: Double, duration: Double) {
        self.currentTime = currentTime.isFinite ? currentTime : 0
        self.duration = duration.isFinite ? duration : 0
    }

    /// Moves 10 s forward, up to the duration. Returns the time to seek to.
    func skipForward() -> Double {
        skip(by: 10)
    }

    /// Moves 10 s back, down to 0. Returns the time to seek to.
    func skipBackward() -> Double {
        skip(by: -10)
    }

    /// With an unknown duration (0) the time stays put: clamping to 0…0 would restart the video.
    private func skip(by seconds: Double) -> Double {
        guard duration > 0 else { return currentTime }
        currentTime = min(max(currentTime + seconds, 0), duration)
        return currentTime
    }

    // MARK: - Bars

    func playbackStateChanged(isPlaying: Bool) {
        self.isPlaying = isPlaying
        restartHide()
    }

    func scrubbingChanged(_ isScrubbing: Bool) {
        self.isScrubbing = isScrubbing
        restartHide()
    }

    func showBars() {
        barsVisible = true
        restartHide()
    }

    /// A tap on the page: hides visible bars and drops any pending hide; shows hidden bars as `showBars` does.
    func toggleBars() {
        if barsVisible {
            barsVisible = false
            hideTask?.cancel()
            hideTask = nil
        } else {
            showBars()
        }
    }

    /// Hides the bars 3 s from now if a video is playing and not being scrubbed; any earlier hide is dropped.
    private func restartHide() {
        hideTask?.cancel()
        hideTask = nil
        guard isPlaying, !isScrubbing, !isClosed else { return }
        hideTask = Task { [weak self, sleep] in
            do {
                try await sleep(.seconds(3))
            } catch {
                return  // Cancelled: a newer state decides.
            }
            guard !Task.isCancelled else { return }
            self?.barsVisible = false
        }
    }

    // MARK: - Temp files

    /// Records a decrypted copy a page opened, to remove on close. A page can finish opening after the viewer
    /// has closed; its copy is then removed at once so no plaintext stays behind.
    func registerTemporaryFile(_ url: URL) {
        if isClosed {
            store.removeTemporary(url)
        } else {
            temporaryFiles.insert(url)
        }
    }

    /// Removes this viewer's own temp files. Never the store's other temp files: exports may be using them.
    func close() {
        isClosed = true
        hideTask?.cancel()
        hideTask = nil
        for url in temporaryFiles {
            store.removeTemporary(url)
        }
        temporaryFiles = []
    }
}
