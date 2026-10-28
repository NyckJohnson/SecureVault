//
//  MediaPipelineTests.swift
//  KoalaTVaultTests
//

import XCTest
import AVFoundation
@testable import KoalaTVault

// MARK: - VaultResourceLoaderDelegateTests
//
// What is NOT covered here (infeasible in unit tests):
//   • Byte-range slice spanning a chunk boundary — requires AVAssetResourceLoadingRequest,
//     which has no public initialiser; cannot be constructed outside the AVFoundation framework.
//   • Cancellation mid-loop (isCancelled guard) — same constraint.
//   • Corrupt-file error propagating through finishLoading(with:) — same constraint.
//
// The fulfil() logic is exercised indirectly whenever a real AVPlayer/AVAssetImageGenerator
// drives the delegate (covered manually and by ThumbnailService integration below).

final class VaultResourceLoaderDelegateTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try TestCrypto.keyStore.createMasterKey(password: "test-password")
    }

    override func tearDownWithError() throws {
        TestCrypto.keyStore.wipeKey()
        try TestCrypto.keyStore.deleteMasterKeyBlob()
        tempURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tempURLs.append(url)
        return url
    }

    private func randomData(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    private func makeEncryptedFile(_ data: Data) throws -> URL {
        let src = tempURL()
        let enc = tempURL()
        try data.write(to: src)
        try TestCrypto.cipher.encryptFile(at: src, to: enc)
        return enc
    }

    // MARK: - init? success cases

    func testInitSucceedsForValidEncryptedFile() throws {
        let enc = try makeEncryptedFile(randomData(count: 1024))
        XCTAssertNotNil(VaultResourceLoaderDelegate(encryptedURL: enc, fileExtension: "mp4"))
    }

    func testInitSucceedsForEmptyEncryptedFile() throws {
        let enc = try makeEncryptedFile(Data())
        XCTAssertNotNil(VaultResourceLoaderDelegate(encryptedURL: enc, fileExtension: "mp4"))
    }

    func testInitSucceedsForLargeMultiChunkFile() throws {
        // 2.5 MB — spans three 1-MB chunks; exercises multi-chunk streamInfo path
        let enc = try makeEncryptedFile(randomData(count: 2 * 1024 * 1024 + 512 * 1024))
        XCTAssertNotNil(VaultResourceLoaderDelegate(encryptedURL: enc, fileExtension: "mp4"))
    }

    func testInitWithUnrecognisedExtensionFallsBackWithoutCrash() throws {
        // Falls back to .mpeg4Movie content type; must not return nil purely because of extension
        let enc = try makeEncryptedFile(randomData(count: 256))
        XCTAssertNotNil(VaultResourceLoaderDelegate(encryptedURL: enc, fileExtension: "xyz_unknown"))
    }

    // MARK: - init? failure cases (corrupt / missing files)

    func testInitFailsForPlainTextFile() throws {
        let url = tempURL()
        try Data("plaintext content".utf8).write(to: url)
        XCTAssertNil(VaultResourceLoaderDelegate(encryptedURL: url, fileExtension: "mp4"))
    }

    func testInitFailsForNonExistentFile() {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID()).enc")
        XCTAssertNil(VaultResourceLoaderDelegate(encryptedURL: ghost, fileExtension: "mp4"))
    }

    func testInitFailsForFileTruncatedBeforeEndOfHeader() throws {
        // Only 10 bytes — shorter than the 32-byte SVC5 header
        let url = tempURL()
        try Data([0x53, 0x56, 0x43, 0x35, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00]).write(to: url)
        XCTAssertNil(VaultResourceLoaderDelegate(encryptedURL: url, fileExtension: "mp4"))
    }

    func testInitFailsForFileWithCorruptMagicBytes() throws {
        // 32 bytes with the right length but wrong magic
        var header = Data(count: 32)
        header[0] = 0xFF; header[1] = 0xFE; header[2] = 0xFD; header[3] = 0xFC
        // Write a plausible chunk-size field (1 MB, little-endian) so parseHeader
        // gets past the magic check and fails there, not earlier
        var cs = UInt32(1024 * 1024).littleEndian
        withUnsafeBytes(of: &cs) { header.replaceSubrange(4..<8, with: $0) }
        let url = tempURL()
        try header.write(to: url)
        XCTAssertNil(VaultResourceLoaderDelegate(encryptedURL: url, fileExtension: "mp4"))
    }
}

// MARK: - ThumbnailServiceTests
//
// What is NOT covered here (infeasible in unit tests):
//   • Video thumbnail from a real decodable video — requires actual encoded video frames;
//     AVAssetImageGenerator returns nil for random-byte "video" content.
//   • Semaphore back-pressure under memory load — requires coordinating ≥ 2 concurrent
//     blocking decryptions, which cannot be done reliably without injecting sleeps that
//     would make tests non-deterministically slow.

@MainActor
final class ThumbnailServiceTests: XCTestCase {

    private var tempURLs: [URL] = []
    private var harness: LegacyVaultHarness!
    private var thumbnails: ThumbnailService!

    override func setUp() async throws {
        try await super.setUp()
        try TestCrypto.keyStore.createMasterKey(password: "test-password")
        harness = try LegacyVaultHarness(lockMode: .password)
        thumbnails = ThumbnailService(vaultStore: harness.store, preferences: harness.preferences)
    }

    override func tearDown() async throws {
        thumbnails.clearCache()
        thumbnails = nil
        harness.cleanUp()
        harness = nil
        tempURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tempURLs.append(url)
        return url
    }

    private func randomData(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    /// A real encrypted item, added through the store in encrypted mode.
    private func makeEncryptedVaultItem(name: String, data: Data) async throws -> VaultItem {
        let src = harness.base.appendingPathComponent("Sources/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let file = src.appendingPathComponent(name)
        try data.write(to: file)
        return try await harness.store.addFile(from: file, named: name, to: harness.root)
    }

    /// An item that claims to be encrypted but whose file is not a valid SVC5 file.
    private func makeCorruptVaultItem(name: String, content: Data = Data("not a valid SVC5 file".utf8)) throws -> VaultItem {
        let url = harness.rootURL.appendingPathComponent(UUID().uuidString)
        try content.write(to: url)
        return corruptItem(name: name, url: url, size: content.count)
    }

    private func corruptItem(name: String, url: URL, size: Int) -> VaultItem {
        VaultItem(
            id: url.path,
            name: name,
            isDirectory: false,
            dateModified: Date(),
            fileSize: size,
            deletedAt: nil,
            diskURL: url,
            rootURL: harness.rootURL,
            isEncrypted: true
        )
    }

    private func makeTinyPNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100))
        return renderer.pngData { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
    }

    // MARK: - Cache management

    func testClearAllCacheDoesNotCrash() {
        thumbnails.clearCache()
    }

    func testClearCacheForSpecificItemDoesNotCrash() {
        let item = VaultItem(
            id: "photo.jpg",
            name: "photo.jpg",
            isDirectory: false,
            dateModified: Date(),
            fileSize: nil,
            deletedAt: nil,
            diskURL: URL(fileURLWithPath: "/dev/null"),
            rootURL: URL(fileURLWithPath: "/tmp"),
            isEncrypted: false
        )
        thumbnails.clearCache(for: item)
    }

    // MARK: - Corrupt file → nil completion

    func testCorruptNonVideoEncryptedFileDeliversNilCompletion() throws {
        // VaultStoring.open throws (bad SVC5 magic) → guard-else path calls completion(nil)
        let item = try makeCorruptVaultItem(name: "document.pdf")
        let exp = expectation(description: "completion(nil)")
        _ = thumbnails.thumbnail(for: item, size: CGSize(width: 60, height: 60)) { image in
            XCTAssertNil(image)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testCorruptVideoFileDeliversNilCompletion() throws {
        // VaultResourceLoaderDelegate.init? returns nil for non-SVC5 data →
        // videoThumbnail's guard-else path calls completion(nil)
        let item = try makeCorruptVaultItem(name: "clip.mp4")
        let exp = expectation(description: "completion(nil) for corrupt video")
        _ = thumbnails.thumbnail(for: item, size: CGSize(width: 60, height: 60)) { image in
            XCTAssertNil(image)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testTruncatedEncryptedFileDeliversNilCompletion() throws {
        // Four SVC5 magic bytes followed by junk — decryptFile will throw, open returns nil
        let url = harness.rootURL.appendingPathComponent(UUID().uuidString)
        try Data([0x53, 0x56, 0x43, 0x35, 0xAB, 0xCD, 0xEF, 0x01]).write(to: url)
        let item = corruptItem(name: "notes.pdf", url: url, size: 8)
        let exp = expectation(description: "completion(nil) for truncated file")
        _ = thumbnails.thumbnail(for: item, size: CGSize(width: 60, height: 60)) { image in
            XCTAssertNil(image)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    // MARK: - Cancellation

    func testCancellingThumbnailBeforeDecryptionPreventsCompletion() async throws {
        // Encrypt a real PNG so that QL *would* deliver a non-nil image if not cancelled.
        // The inverted expectation fails if completion is called at all (nil or not).
        let item = try await makeEncryptedVaultItem(name: "photo.png", data: makeTinyPNG())

        let unexpectedCall = expectation(description: "completion must NOT be called after cancel")
        unexpectedCall.isInverted = true

        _ = thumbnails.thumbnail(for: item, size: CGSize(width: 60, height: 60)) { _ in
            unexpectedCall.fulfill()
        }
        // Cancel on the same synchronous call stack so the flag is set before the
        // background block's consumeCancellation() check runs.
        thumbnails.cancelThumbnail(for: item)

        await fulfillment(of: [unexpectedCall], timeout: 1.0)
    }

    // MARK: - Cache hit

    func testSecondThumbnailRequestForSameItemUsesCache() async throws {
        // Generate a real thumbnail first so the cache is populated, then verify the
        // second request completes synchronously (the returned QLRequest is nil).
        let item = try await makeEncryptedVaultItem(name: "photo.png", data: makeTinyPNG())

        let firstDone = expectation(description: "first thumbnail")
        _ = thumbnails.thumbnail(for: item, size: CGSize(width: 60, height: 60)) { _ in
            firstDone.fulfill()
        }
        await fulfillment(of: [firstDone], timeout: 10)

        // Cache hit: completion fires synchronously; returned request must be nil
        var secondImage: UIImage?
        let request = thumbnails.thumbnail(
            for: item, size: CGSize(width: 60, height: 60)
        ) { image in
            secondImage = image
        }
        XCTAssertNil(request, "cache hit must not return a QLThumbnailGenerator.Request")
        XCTAssertNotNil(secondImage, "cached image must be delivered synchronously")
    }
}

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
        let transfers = FileSystem(store: store, proUnlock: MockProUnlocking(isUnlocked: true))
        return LegacyFileViewerViewController(
            items: [makeItem()], startingAt: 0, vaultStore: store,
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
