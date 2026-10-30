import AVFoundation
import Foundation
import UIKit
import os

@testable import KoalaTVault

/// A unique temporary directory, removed when the value goes away.
final class MediaTestDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes `data` to a new file called `name` and returns its URL.
    func file(_ name: String, _ data: Data = Data("payload".utf8)) -> URL {
        let fileURL = url.appendingPathComponent(name)
        try? data.write(to: fileURL)
        return fileURL
    }
}

/// A vault item for tests; the id is the disk file name.
func makeMediaItem(
    name: String, diskURL: URL, isDirectory: Bool = false, isEncrypted: Bool = false,
    fileSize: Int? = nil, dateModified: Date = Date(timeIntervalSince1970: 0)
) -> VaultItem {
    VaultItem(
        id: diskURL.lastPathComponent, name: name, isDirectory: isDirectory,
        dateModified: dateModified, fileSize: isDirectory ? nil : fileSize,
        deletedAt: nil, diskURL: diskURL, rootURL: diskURL.deletingLastPathComponent(),
        isEncrypted: isEncrypted)
}

/// A square image of the given side, so tests can tell images apart by identity or size.
func makeTestImage(side: CGFloat) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
}

/// Parks callers of `pass()` until `open()`, and lets a test wait until a number of callers arrived.
final class MediaTestGate: Sendable {
    private struct State: Sendable {
        var entered = 0
        var isOpen = false
        var parked: [CheckedContinuation<Void, Never>] = []
        var waiters: [Waiter] = []
    }
    private struct Waiter: Sendable {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var enteredCount: Int { state.withLock { $0.entered } }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (resumeNow, toWake): (Bool, [CheckedContinuation<Void, Never>]) = state.withLock { state in
                state.entered += 1
                var wake: [CheckedContinuation<Void, Never>] = []
                var rest: [Waiter] = []
                for waiter in state.waiters {
                    if state.entered >= waiter.count {
                        wake.append(waiter.continuation)
                    } else {
                        rest.append(waiter)
                    }
                }
                state.waiters = rest
                if state.isOpen { return (true, wake) }
                state.parked.append(continuation)
                return (false, wake)
            }
            if resumeNow { continuation.resume() }
            for waiter in toWake { waiter.resume() }
        }
    }

    func waitUntilEntered(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = state.withLock { state -> Bool in
                if state.entered >= count { return true }
                state.waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    func open() {
        let parked = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let parked = state.parked
            state.parked = []
            return parked
        }
        for continuation in parked { continuation.resume() }
    }
}

/// Lets other tasks run so work that is going to start has started.
func settleTasks() async {
    for _ in 0..<100 { await Task.yield() }
}

/// A renderer that records its calls and returns configurable images.
final class FakeThumbnailRenderer: ThumbnailRendering {
    private struct State: Sendable {
        var quickLookURLs: [URL] = []
        var quickLookSizes: [CGSize] = []
        var quickLookScales: [CGFloat] = []
        var quickLookFileExisted: [Bool] = []
        var quickLookFileContents: [Data?] = []
        var quickLookCancelled: [Bool] = []
        var inFlight = 0
        var maxInFlight = 0
        var frameRequests: [FrameRequest] = []
        var composeCount = 0
        var quickLookResult: UIImage?
        var duration: TimeInterval? = 60
        var frameResult: UIImage?
        var folderIconResult: UIImage?
        var composedResult: UIImage?
    }

    struct FrameRequest: Equatable, Sendable {
        let url: URL
        let time: TimeInterval
    }

    let quickLookImage = makeTestImage(side: 10)
    let frameImage = makeTestImage(side: 20)
    let folderIconImage = makeTestImage(side: 30)
    let composedImage = makeTestImage(side: 40)

    private let state: OSAllocatedUnfairLock<State>
    private let gate: MediaTestGate?

    /// With a gate, every QuickLook request parks on it.
    init(gate: MediaTestGate? = nil) {
        self.gate = gate
        state = OSAllocatedUnfairLock(
            initialState: State(
                quickLookResult: quickLookImage, frameResult: frameImage,
                folderIconResult: folderIconImage, composedResult: composedImage))
    }

    var quickLookURLs: [URL] { state.withLock { $0.quickLookURLs } }
    var quickLookSizes: [CGSize] { state.withLock { $0.quickLookSizes } }
    var quickLookScales: [CGFloat] { state.withLock { $0.quickLookScales } }
    var quickLookFileExisted: [Bool] { state.withLock { $0.quickLookFileExisted } }
    var quickLookFileContents: [Data?] { state.withLock { $0.quickLookFileContents } }
    var quickLookCancelled: [Bool] { state.withLock { $0.quickLookCancelled } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    var frameRequests: [FrameRequest] { state.withLock { $0.frameRequests } }
    var composeCount: Int { state.withLock { $0.composeCount } }

    var quickLookResult: UIImage? {
        get { state.withLock { $0.quickLookResult } }
        set { state.withLock { $0.quickLookResult = newValue } }
    }
    var duration: TimeInterval? {
        get { state.withLock { $0.duration } }
        set { state.withLock { $0.duration = newValue } }
    }
    var frameResult: UIImage? {
        get { state.withLock { $0.frameResult } }
        set { state.withLock { $0.frameResult = newValue } }
    }
    var folderIconResult: UIImage? {
        get { state.withLock { $0.folderIconResult } }
        set { state.withLock { $0.folderIconResult = newValue } }
    }

    func quickLookThumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let existed = FileManager.default.fileExists(atPath: url.path)
        let contents = try? Data(contentsOf: url)
        let result = state.withLock { state -> UIImage? in
            state.quickLookURLs.append(url)
            state.quickLookSizes.append(size)
            state.quickLookScales.append(scale)
            state.quickLookFileExisted.append(existed)
            state.quickLookFileContents.append(contents)
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
            return state.quickLookResult
        }
        await gate?.pass()
        state.withLock { state in
            state.inFlight -= 1
            state.quickLookCancelled.append(Task.isCancelled)
        }
        return result
    }

    func videoDuration(of asset: AVURLAsset) async -> TimeInterval? {
        state.withLock { $0.duration }
    }

    // swiftlint:disable opening_brace
    func videoFrame(of asset: AVURLAsset, at time: TimeInterval, size: CGSize, scale: CGFloat) async
        -> UIImage?
    {
        state.withLock { state in
            state.frameRequests.append(FrameRequest(url: asset.url, time: time))
            return state.frameResult
        }
    }
    // swiftlint:enable opening_brace

    func folderIcon(size: CGSize, scale: CGFloat) -> UIImage? {
        state.withLock { $0.folderIconResult }
    }

    func compose(_ media: UIImage, onto folderIcon: UIImage, size: CGSize, scale: CGFloat) -> UIImage? {
        state.withLock { state in
            state.composeCount += 1
            return state.composedResult
        }
    }
}

/// A cipher whose stream info and chunks are scripted, to test short or odd chunks.
final class ScriptedFileCipher: FileCipher, @unchecked Sendable {
    private let info: StreamInfo
    private let chunks: [Int: Data]
    private let decryptCount = OSAllocatedUnfairLock(initialState: 0)

    init(info: StreamInfo, chunks: [Int: Data]) {
        self.info = info
        self.chunks = chunks
    }

    var decryptedChunks: Int { decryptCount.withLock { $0 } }

    func streamInfo(of url: URL) throws -> StreamInfo { info }

    func decryptChunk(_ index: Int, of url: URL, info: StreamInfo) throws -> Data {
        decryptCount.withLock { $0 += 1 }
        guard let data = chunks[index] else { throw VaultCryptoError.decryptionFailed }
        return data
    }

    func encrypt(_ data: Data, context: String) throws -> Data { throw VaultCryptoError.encryptionFailed }
    func decrypt(_ data: Data, contexts: [String]) throws -> Data { throw VaultCryptoError.decryptionFailed }
    func encryptFile(at source: URL, to destination: URL) throws { throw VaultCryptoError.encryptionFailed }
    func decryptFile(at source: URL, to destination: URL) throws { throw VaultCryptoError.decryptionFailed }
}
