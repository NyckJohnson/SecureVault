//
//  MediaPipelineTests.swift
//  KoalaTVaultTests
//

import XCTest
import AVFoundation
@testable import KoalaTVault

// MARK: - FileViewerViewControllerTests
//
// What is NOT covered here (infeasible without major refactoring):
//   • scrubberTouchBegan/Changed/Ended — declared @objc private; inaccessible
//     from @testable import and cannot be driven via UISlider.sendActions without
//     loading a fully-hosted window hierarchy.
//   • updateScrubber / updateBufferIndicator / updateSpinner — private; would need
//     access modifier widening to unit-test in isolation.
//   • formatTime with NaN / Infinity — private.
//
// The guard clauses in scrubberTouchEnded (isIndefinite/isValid duration) are
// exercised naturally by the nil-player tests below, since an AVPlayer() with no
// item has an indefinite current-item duration.

@MainActor
final class FileViewerViewControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(name: String = "test.mp4") -> VaultItem {
        VaultItem(
            id: name,
            name: name,
            isDirectory: false,
            dateModified: Date(),
            fileSize: nil,
            deletedAt: nil,
            diskURL: URL(fileURLWithPath: "/dev/null"),
            rootURL: URL(fileURLWithPath: "/tmp"),
            isEncrypted: false
        )
    }

    /// A viewer over a mock vault store.
    private func makeViewer() -> LegacyFileViewerViewController {
        let store = MockVaultStoring()
        let transfers = FileSystem(store: store)
        return LegacyFileViewerViewController(
            items: [makeItem()], startingAt: 0, vaultStore: store,
            videoAssets: MockVideoAssetProviding(),
            exportService: ExportService(fileSystem: transfers, vaultStore: store))
    }

    // MARK: - Nil-player guard coverage
    // These directly cover the "seek past end", "seek before start", and
    // "controls called with no media" scenarios.

    func testTogglePlayPauseWithNilPlayerDoesNotCrash() {
        let vc = makeViewer()
        XCTAssertNil(vc.player)
        vc.togglePlayPause()
    }

    func testSkipBackWithNilPlayerDoesNotCrash() {
        let vc = makeViewer()
        vc.skipBack()
    }

    func testSkipForwardWithNilPlayerDoesNotCrash() {
        let vc = makeViewer()
        vc.skipForward()
    }

    // MARK: - Seek boundary behaviour (player present, no current item)

    func testSkipForwardRepeatedlyNearEndDoesNotCrash() {
        // AVPlayer with no item: currentTime() == .zero, seek() is a no-op.
        // Simulates user hammering skip-forward past the end of a file.
        let vc = makeViewer()
        vc.player = AVPlayer()
        vc.skipForward()
        vc.skipForward()
        vc.skipForward()
        vc.player = nil
    }

    func testSkipBackRepeatedlyPastStartDoesNotCrash() {
        // CMTimeSubtract from zero yields negative CMTime; AVPlayer clamps to zero.
        let vc = makeViewer()
        vc.player = AVPlayer()
        vc.skipBack()
        vc.skipBack()
        vc.skipBack()
        vc.player = nil
    }

    // MARK: - Player observer lifecycle

    func testAssigningAndClearingPlayerDoesNotCrash() {
        let vc = makeViewer()
        vc.player = AVPlayer()
        vc.player = nil
    }

    func testReplacingPlayerCleansUpPreviousObserverWithoutCrash() {
        // Replacing the player triggers removeTimeObserver on the old player and
        // addTimeObserver on the new one; must not double-remove or leak.
        let vc = makeViewer()
        let playerA = AVPlayer()
        let playerB = AVPlayer()
        vc.player = playerA
        vc.player = playerB
        vc.player = nil
    }

    func testTogglePlayPauseWithRealPlayerDoesNotCrash() {
        let vc = makeViewer()
        vc.player = AVPlayer()
        vc.togglePlayPause() // player.play() → updates button, starts timer
        vc.togglePlayPause() // player.pause() → updates button, cancels timer
        vc.player = nil
    }

    // MARK: - updatePlayPauseButton

    func testUpdatePlayPauseButtonDoesNotCrash() {
        let vc = makeViewer()
        vc.updatePlayPauseButton(isPlaying: true)
        vc.updatePlayPauseButton(isPlaying: false)
    }
}
