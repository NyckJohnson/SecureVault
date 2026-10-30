import AVFoundation
import Foundation
import Testing

@testable import KoalaTVault

/// A loading request that records how it was answered.
final class FakeLoadingRequest: LoadingRequest, @unchecked Sendable {
    final class ContentInfo: LoadingContentInformation, @unchecked Sendable {
        var contentType: String?
        var contentLength: Int64 = 0
        var isByteRangeAccessSupported = false
    }

    final class LoadingData: LoadingDataRequest, @unchecked Sendable {
        let requestedOffset: Int64
        let requestedLength: Int
        let requestsAllDataToEndOfResource: Bool
        private(set) var currentOffset: Int64
        private(set) var received = Data()

        init(offset: Int64, length: Int, toEnd: Bool) {
            requestedOffset = offset
            requestedLength = length
            requestsAllDataToEndOfResource = toEnd
            currentOffset = offset
        }

        func respond(with data: Data) {
            received.append(data)
            currentOffset += Int64(data.count)
        }
    }

    let requestURL: URL?
    let contentInformationRequest: LoadingContentInformation?
    let dataRequest: LoadingDataRequest?
    private(set) var finishCount = 0
    private(set) var failure: (any Error)?
    private(set) var failedCount = 0

    init(url: URL?, contentInfo: ContentInfo? = nil, data: LoadingData? = nil) {
        requestURL = url
        contentInformationRequest = contentInfo
        dataRequest = data
    }

    var succeeded: Bool { finishCount == 1 && failedCount == 0 }

    func finishLoading() { finishCount += 1 }

    func finishLoading(with error: (any Error)?) {
        if let error {
            failedCount += 1
            failure = error
        } else {
            finishCount += 1
        }
    }
}

@Suite struct EncryptedVideoLoaderTests {
    private static let oneMiB = MockFileCipher.chunkSize

    /// A plaintext pattern of `count` bytes the tests can slice and compare.
    private static func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    private struct Rig {
        let directory = MediaTestDirectory()
        let cipher = MockFileCipher()
        let loader: EncryptedVideoLoader
        let plaintext: Data

        init(size: Int = 3 * EncryptedVideoLoaderTests.oneMiB + 100) {
            plaintext = EncryptedVideoLoaderTests.pattern(size)
            loader = EncryptedVideoLoader(cipher: cipher)
        }

        /// An encrypted item whose "ciphertext" file is the pattern (the mock cipher copies bytes through).
        func encrypted(_ name: String = "clip.mp4") -> VaultItem {
            makeMediaItem(
                name: name, diskURL: directory.file(UUID().uuidString, plaintext), isEncrypted: true,
                fileSize: plaintext.count)
        }

        func streamURL(for item: VaultItem) throws -> URL {
            try loader.asset(for: item).url
        }

        func decryptedChunkIndexes() -> [Int] {
            cipher.calls.compactMap { call in
                if case .decryptChunk(let index, _) = call { index } else { nil }
            }
        }
    }

    // MARK: asset(for:)

    @Test("A plaintext item's asset plays its disk URL")
    func plaintextAssetUsesDiskURL() throws {
        let rig = Rig()
        let item = makeMediaItem(name: "clip.mp4", diskURL: rig.directory.file("clip.mp4"))
        let asset = try rig.loader.asset(for: item)
        #expect(asset.url == item.diskURL)
        #expect(rig.cipher.calls.isEmpty)
    }

    @Test("An encrypted item's asset uses a vault-stream URL")
    func encryptedAssetUsesStreamScheme() throws {
        let rig = Rig()
        let asset = try rig.loader.asset(for: rig.encrypted())
        #expect(asset.url.scheme == "vault-stream")
    }

    @Test("An encrypted item's asset is loaded through the loader")
    func encryptedAssetDelegatesToLoader() throws {
        let rig = Rig()
        let asset = try rig.loader.asset(for: rig.encrypted())
        #expect(asset.resourceLoader.delegate === rig.loader)
    }

    @Test("An encrypted item with an invalid header throws")
    func invalidHeaderThrows() {
        let rig = Rig()
        rig.cipher.errorToThrow = .decryptionFailed
        #expect(throws: (any Error).self) { try rig.loader.asset(for: rig.encrypted()) }
    }

    @Test("Different encrypted items get different stream URLs")
    func distinctStreamURLs() throws {
        let rig = Rig()
        let first = try rig.streamURL(for: rig.encrypted())
        let second = try rig.streamURL(for: rig.encrypted())
        #expect(first != second)
    }

    // MARK: Content information

    @Test(
        "Content info reports the type from the extension",
        arguments: [
            ("clip.mp4", "public.mpeg-4"), ("clip.mov", "com.apple.quicktime-movie"),
            // swiftlint:disable:next trailing_comma
            ("clip.m4v", "com.apple.m4v-video"), ("CLIP.MOV", "com.apple.quicktime-movie"),
        ])
    func contentTypeFromExtension(name: String, expectedType: String) async throws {
        let rig = Rig()
        let url = try rig.streamURL(for: rig.encrypted(name))
        let info = FakeLoadingRequest.ContentInfo()
        let request = FakeLoadingRequest(url: url, contentInfo: info)
        await rig.loader.serve(request)
        #expect(info.contentType == expectedType)
        #expect(request.succeeded)
    }

    @Test(
        "Content info defaults to mpeg-4 for an unknown or missing extension",
        arguments: ["clip.xyz", "clip"])
    func contentTypeDefault(name: String) async throws {
        let rig = Rig()
        let url = try rig.streamURL(for: rig.encrypted(name))
        let info = FakeLoadingRequest.ContentInfo()
        await rig.loader.serve(FakeLoadingRequest(url: url, contentInfo: info))
        #expect(info.contentType == "public.mpeg-4")
    }

    @Test("Content info length is the plaintext size and byte ranges are supported")
    func contentLengthAndRanges() async throws {
        let rig = Rig(size: 2_500_000)
        let url = try rig.streamURL(for: rig.encrypted())
        let info = FakeLoadingRequest.ContentInfo()
        let request = FakeLoadingRequest(url: url, contentInfo: info)
        await rig.loader.serve(request)
        #expect(info.contentLength == 2_500_000)
        #expect(info.isByteRangeAccessSupported)
        #expect(request.succeeded)
        #expect(rig.decryptedChunkIndexes().isEmpty)
    }

    @Test("An empty encrypted item still gets a stream asset, with length 0 and byte ranges")
    func emptyEncryptedItemStreams() async throws {
        let rig = Rig(size: 0)
        let asset = try rig.loader.asset(for: rig.encrypted())
        #expect(asset.url.scheme == "vault-stream")
        let info = FakeLoadingRequest.ContentInfo()
        let request = FakeLoadingRequest(url: asset.url, contentInfo: info)
        await rig.loader.serve(request)
        #expect(info.contentLength == 0)
        #expect(info.isByteRangeAccessSupported)
        #expect(request.succeeded)
    }

    @Test("A data request on an empty encrypted item finishes without decrypting")
    func emptyEncryptedItemDataRequest() async throws {
        let rig = Rig(size: 0)
        let url = try rig.streamURL(for: rig.encrypted())
        let data = FakeLoadingRequest.LoadingData(offset: 0, length: 1000, toEnd: false)
        let request = FakeLoadingRequest(url: url, data: data)
        await rig.loader.serve(request)
        #expect(request.succeeded)
        #expect(data.received.isEmpty)
        #expect(rig.decryptedChunkIndexes().isEmpty)
    }

    // MARK: Data requests

    @Test("A range inside one chunk decrypts only that chunk")
    func rangeInsideOneChunk() async throws {
        let rig = Rig()
        let url = try rig.streamURL(for: rig.encrypted())
        let offset = Self.oneMiB + 10
        let data = FakeLoadingRequest.LoadingData(offset: Int64(offset), length: 100, toEnd: false)
        let request = FakeLoadingRequest(url: url, data: data)
        await rig.loader.serve(request)
        #expect(data.received == rig.plaintext.subdata(in: offset..<(offset + 100)))
        #expect(Set(rig.decryptedChunkIndexes()) == [1])
        #expect(request.succeeded)
    }

    @Test("A range across a chunk boundary decrypts both chunks and returns the bytes in order")
    func rangeAcrossChunks() async throws {
        let rig = Rig()
        let url = try rig.streamURL(for: rig.encrypted())
        let offset = Self.oneMiB - 10
        let data = FakeLoadingRequest.LoadingData(offset: Int64(offset), length: 20, toEnd: false)
        let request = FakeLoadingRequest(url: url, data: data)
        await rig.loader.serve(request)
        #expect(data.received == rig.plaintext.subdata(in: offset..<(offset + 20)))
        #expect(Set(rig.decryptedChunkIndexes()) == [0, 1])
        #expect(request.succeeded)
    }

    @Test("A range from the start decrypts only the first chunk")
    func rangeFromStart() async throws {
        let rig = Rig()
        let url = try rig.streamURL(for: rig.encrypted())
        let data = FakeLoadingRequest.LoadingData(offset: 0, length: 1000, toEnd: false)
        await rig.loader.serve(FakeLoadingRequest(url: url, data: data))
        #expect(data.received == rig.plaintext.prefix(1000))
        #expect(Set(rig.decryptedChunkIndexes()) == [0])
    }

    @Test("A request to the end of the resource returns everything from the offset")
    func requestToEnd() async throws {
        let rig = Rig()
        let url = try rig.streamURL(for: rig.encrypted())
        let offset = 3 * Self.oneMiB - 5
        let data = FakeLoadingRequest.LoadingData(offset: Int64(offset), length: Int.max, toEnd: true)
        let request = FakeLoadingRequest(url: url, data: data)
        await rig.loader.serve(request)
        #expect(data.received == rig.plaintext.suffix(from: offset))
        #expect(Set(rig.decryptedChunkIndexes()) == [2, 3])
        #expect(request.succeeded)
    }

    @Test("A range running past the end is cut at the end of the file")
    func rangePastEnd() async throws {
        let rig = Rig()
        let url = try rig.streamURL(for: rig.encrypted())
        let offset = rig.plaintext.count - 10
        let data = FakeLoadingRequest.LoadingData(offset: Int64(offset), length: 5000, toEnd: false)
        let request = FakeLoadingRequest(url: url, data: data)
        await rig.loader.serve(request)
        #expect(data.received == rig.plaintext.suffix(10))
        #expect(request.succeeded)
    }

    @Test("An empty range finishes at once without decrypting")
    func emptyRangeFinishesAtOnce() async throws {
        let rig = Rig()
        let url = try rig.streamURL(for: rig.encrypted())
        let data = FakeLoadingRequest.LoadingData(offset: 500, length: 0, toEnd: false)
        let request = FakeLoadingRequest(url: url, data: data)
        await rig.loader.serve(request)
        #expect(request.succeeded)
        #expect(data.received.isEmpty)
        #expect(rig.decryptedChunkIndexes().isEmpty)
    }

    @Test("A decrypt error fails the request")
    func decryptErrorFailsRequest() async throws {
        let rig = Rig()
        let url = try rig.streamURL(for: rig.encrypted())
        rig.cipher.errorToThrow = .decryptionFailed
        let data = FakeLoadingRequest.LoadingData(offset: 0, length: 100, toEnd: false)
        let request = FakeLoadingRequest(url: url, data: data)
        await rig.loader.serve(request)
        #expect(request.failedCount == 1)
        #expect(request.finishCount == 0)
        #expect(request.failure != nil)
        #expect(data.received.isEmpty)
    }

    @Test("Two different streams are served independently")
    func streamsServedIndependently() async throws {
        let rig = Rig()
        let first = rig.encrypted("a.mp4")
        let second = rig.encrypted("b.mov")
        let firstURL = try rig.streamURL(for: first)
        let secondURL = try rig.streamURL(for: second)
        let firstInfo = FakeLoadingRequest.ContentInfo()
        let secondInfo = FakeLoadingRequest.ContentInfo()
        await rig.loader.serve(FakeLoadingRequest(url: firstURL, contentInfo: firstInfo))
        await rig.loader.serve(FakeLoadingRequest(url: secondURL, contentInfo: secondInfo))
        #expect(firstInfo.contentType == "public.mpeg-4")
        #expect(secondInfo.contentType == "com.apple.quicktime-movie")
    }

    // MARK: Unknown streams, truncation, cancellation

    @Test("A vault-stream URL the loader never issued fails the request")
    func unknownStreamFails() async {
        let rig = Rig()
        let data = FakeLoadingRequest.LoadingData(offset: 0, length: 100, toEnd: false)
        let request = FakeLoadingRequest(url: URL(string: "vault-stream://not-issued/clip.mp4"), data: data)
        await rig.loader.serve(request)
        #expect(request.failedCount == 1)
        #expect(request.finishCount == 0)
        #expect(data.received.isEmpty)
        #expect(rig.decryptedChunkIndexes().isEmpty)
    }

    @Test("A stream URL issued by another loader fails the request")
    func foreignLoaderStreamFails() async throws {
        let rig = Rig()
        let other = Rig()
        let url = try other.streamURL(for: other.encrypted())
        let info = FakeLoadingRequest.ContentInfo()
        let request = FakeLoadingRequest(url: url, contentInfo: info)
        await rig.loader.serve(request)
        #expect(request.failedCount == 1)
        #expect(request.finishCount == 0)
    }

    @Test("A request for a foreign URL scheme fails")
    func foreignSchemeFails() async {
        let rig = Rig()
        let request = FakeLoadingRequest(
            url: URL(string: "https://example.com/clip.mp4"),
            contentInfo: FakeLoadingRequest.ContentInfo())
        await rig.loader.serve(request)
        #expect(request.failedCount == 1)
        #expect(request.finishCount == 0)
    }

    private func scriptedRig(
        info: StreamInfo, chunks: [Int: Data]
    ) throws -> (loader: EncryptedVideoLoader, url: URL) {
        let directory = MediaTestDirectory()
        let cipher = ScriptedFileCipher(info: info, chunks: chunks)
        let loader = EncryptedVideoLoader(cipher: cipher)
        let item = makeMediaItem(
            name: "clip.mp4", diskURL: directory.file(UUID().uuidString), isEncrypted: true,
            fileSize: info.totalSize)
        return (loader, try loader.asset(for: item).url)
    }

    @Test("A short non-final chunk that only partly covers the range fails the request")
    func truncatedStreamFails() async throws {
        let info = StreamInfo(totalSize: 300, chunkSize: 100)
        let first = Data(repeating: 1, count: 100)
        let second = Data(repeating: 2, count: 40)
        let third = Data(repeating: 3, count: 100)
        let rig = try scriptedRig(
            info: info,
            chunks: [0: first, 1: second, 2: third])
        let data = FakeLoadingRequest.LoadingData(offset: 50, length: 200, toEnd: false)
        let request = FakeLoadingRequest(url: rig.url, data: data)
        await rig.loader.serve(request)
        #expect(request.failedCount == 1)
        #expect(request.finishCount == 0)
    }

    @Test("Full-size chunks of a scripted stream are served in order")
    func scriptedFullChunksServed() async throws {
        let info = StreamInfo(totalSize: 250, chunkSize: 100)
        let first = Data(repeating: 1, count: 100)
        let second = Data(repeating: 2, count: 100)
        let third = Data(repeating: 3, count: 50)
        let rig = try scriptedRig(
            info: info,
            chunks: [0: first, 1: second, 2: third])
        let data = FakeLoadingRequest.LoadingData(offset: 90, length: 20, toEnd: false)
        let request = FakeLoadingRequest(url: rig.url, data: data)
        await rig.loader.serve(request)
        #expect(data.received == Data(repeating: 1, count: 10) + Data(repeating: 2, count: 10))
        #expect(request.succeeded)
    }

    @Test("A stream reporting a chunk size of zero never serves data or crashes")
    func zeroChunkSizeDoesNotServe() async throws {
        let info = StreamInfo(totalSize: 100, chunkSize: 0)
        let directory = MediaTestDirectory()
        let cipher = ScriptedFileCipher(info: info, chunks: [:])
        let loader = EncryptedVideoLoader(cipher: cipher)
        let item = makeMediaItem(
            name: "clip.mp4", diskURL: directory.file(UUID().uuidString), isEncrypted: true, fileSize: 100)
        // Either the asset is refused up front, or the data request fails; never a trap or data.
        guard let url = try? loader.asset(for: item).url else { return }
        let data = FakeLoadingRequest.LoadingData(offset: 0, length: 50, toEnd: false)
        let request = FakeLoadingRequest(url: url, data: data)
        await loader.serve(request)
        #expect(request.failedCount == 1)
        #expect(data.received.isEmpty)
    }

    @Test("Serving a request whose task is already cancelled does no decrypt work")
    func cancelledServeDoesNoDecrypt() async throws {
        let rig = Rig()
        let url = try rig.streamURL(for: rig.encrypted())
        let data = FakeLoadingRequest.LoadingData(offset: 0, length: 100, toEnd: false)
        let request = FakeLoadingRequest(url: url, data: data)
        let loader = rig.loader
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            await loader.serve(request)
        }
        task.cancel()
        await task.value
        #expect(rig.decryptedChunkIndexes().isEmpty)
        #expect(data.received.isEmpty)
    }
}
