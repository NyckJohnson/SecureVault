import AVFoundation
import UniformTypeIdentifiers
import os

/// The content-information part of a loading request (stands in for
/// `AVAssetResourceLoadingContentInformationRequest`).
protocol LoadingContentInformation: AnyObject, Sendable {
    var contentType: String? { get set }
    var contentLength: Int64 { get set }
    var isByteRangeAccessSupported: Bool { get set }
}

/// The data part of a loading request (stands in for `AVAssetResourceLoadingDataRequest`).
protocol LoadingDataRequest: AnyObject, Sendable {
    var requestedOffset: Int64 { get }
    var requestedLength: Int { get }
    var requestsAllDataToEndOfResource: Bool { get }
    var currentOffset: Int64 { get }
    func respond(with data: Data)
}

/// A resource loading request (stands in for `AVAssetResourceLoadingRequest`).
protocol LoadingRequest: AnyObject, Sendable {
    var requestURL: URL? { get }
    var contentInformationRequest: LoadingContentInformation? { get }
    var dataRequest: LoadingDataRequest? { get }
    /// Whether AVFoundation has cancelled the request; serving stops between chunks when it has.
    var isCancelled: Bool { get }
    func finishLoading()
    func finishLoading(with error: (any Error)?)
}

/// Why `EncryptedVideoLoader` failed a loading request.
enum EncryptedVideoLoaderError: Error, Equatable, Sendable {
    /// The request's URL is not a stream this loader registered.
    case unknownStream
    /// A chunk held fewer bytes than the stream header promised, or the header's chunk size is zero.
    case truncatedStream
}

/// Plays encrypted videos without writing plaintext to disk.
///
/// `asset(for:)` gives an encrypted item an `AVURLAsset` with a `vault-stream://<token>` URL (one token per
/// item) whose resource loader is this object. AVFoundation then asks for content information and byte
/// ranges, and the loader answers by decrypting only the chunks those ranges cover, in memory.
final class EncryptedVideoLoader: NSObject, AVAssetResourceLoaderDelegate, VideoAssetProviding {
    private static let scheme = "vault-stream"

    private struct Stream: Sendable {
        let fileURL: URL
        let info: StreamInfo
        let contentType: String
    }

    private struct Registry: Sendable {
        var streams: [String: Stream] = [:]
        var tokenByItemID: [String: String] = [:]
    }

    private let cipher: any FileCipher
    private let registry = OSAllocatedUnfairLock(initialState: Registry())
    private let delegateQueue = DispatchQueue(label: "KoalaTVault.EncryptedVideoLoader")

    /// - Parameter cipher: reads stream headers and decrypts chunks.
    init(cipher: any FileCipher) {
        self.cipher = cipher
        super.init()
    }

    /// Plaintext → the disk URL; encrypted → a streaming asset. Throws the cipher's error when the
    /// encrypted file's header is invalid (or the vault is locked).
    func asset(for item: VaultItem) throws -> AVURLAsset {
        guard item.isEncrypted else { return AVURLAsset(url: item.diskURL) }
        let info = try cipher.streamInfo(of: item.diskURL)
        let stream = Stream(fileURL: item.diskURL, info: info, contentType: Self.contentType(forName: item.name))
        let token = registry.withLock { registry -> String in
            let token = registry.tokenByItemID[item.id] ?? UUID().uuidString.lowercased()
            registry.tokenByItemID[item.id] = token
            registry.streams[token] = stream
            return token
        }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = token
        guard let url = components.url else { throw EncryptedVideoLoaderError.unknownStream }
        let asset = AVURLAsset(url: url)
        // The resource loader holds its delegate weakly; this loader lives for the app's lifetime.
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate

    // coverage-exempt-begin: AVFoundation delegate entry point; needs a real AVAssetResourceLoadingRequest
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        let request = ResourceLoadingRequestAdapter(loadingRequest)
        // Decrypting blocks, so it runs on the loader's serial queue rather than the cooperative pool.
        delegateQueue.async { self.respond(to: request, isTaskCancelled: { false }) }
        return true
    }
    // coverage-exempt-end

    // MARK: Serving

    /// Answers the request and finishes it (successfully, or with an error) before returning;
    /// a request AVFoundation cancelled is abandoned between chunks. If the calling task is cancelled,
    /// no further chunk is decrypted and the request fails with `CancellationError`.
    func serve(_ request: any LoadingRequest) async {
        respond(to: request, isTaskCancelled: { Task.isCancelled })
    }

    /// The blocking work behind `serve(_:)`: content information, then the requested bytes, decrypting
    /// only the chunks the range covers. `isTaskCancelled` is checked before every chunk.
    private func respond(to request: any LoadingRequest, isTaskCancelled: () -> Bool) {
        guard let url = request.requestURL, let stream = stream(for: url) else {
            request.finishLoading(with: EncryptedVideoLoaderError.unknownStream)
            return
        }
        let total = Int64(stream.info.totalSize)
        if let information = request.contentInformationRequest {
            information.contentType = stream.contentType
            information.contentLength = total
            information.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }

        let start = max(0, dataRequest.requestedOffset)
        let end: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            end = total
        } else {
            // Clamped so a huge requested length cannot overflow.
            let length = Int64(clamping: max(0, dataRequest.requestedLength))
            end = length > total - start ? total : start + length
        }
        guard start < end else {
            request.finishLoading()
            return
        }

        let chunkSize = Int64(stream.info.chunkSize)
        guard chunkSize > 0 else {
            request.finishLoading(with: EncryptedVideoLoaderError.truncatedStream)
            return
        }
        do {
            for index in (start / chunkSize)...((end - 1) / chunkSize) {
                if request.isCancelled { return }
                if isTaskCancelled() { throw CancellationError() }
                let chunk = try cipher.decryptChunk(Int(index), of: stream.fileURL, info: stream.info)
                let chunkStart = index * chunkSize
                // The part of this chunk the range needs. Only the final chunk may be shorter than
                // `chunkSize`, and since `end <= total` the needed part always fits in a whole chunk;
                // a chunk too short to hold it is truncated, and answering with it would misalign
                // every later byte.
                let lower = Int(max(start, chunkStart) - chunkStart)
                let upper = Int(min(end, chunkStart + chunkSize) - chunkStart)
                guard upper <= chunk.count else { throw EncryptedVideoLoaderError.truncatedStream }
                dataRequest.respond(with: chunk.subdata(in: lower..<upper))
            }
            request.finishLoading()
        } catch {
            request.finishLoading(with: error)
        }
    }

    private func stream(for url: URL) -> Stream? {
        guard url.scheme == Self.scheme, let token = url.host else { return nil }
        return registry.withLock { $0.streams[token.lowercased()] }
    }

    /// The uniform type for the name's extension when it is audio or video; MPEG-4 otherwise.
    private static func contentType(forName name: String) -> String {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty,
            let type = UTType(filenameExtension: fileExtension),
            type.conforms(to: .audiovisualContent)
        else { return UTType.mpeg4Movie.identifier }
        return type.identifier
    }
}

// MARK: AVFoundation adapters

// coverage-exempt-begin: adapters over a real AVAssetResourceLoadingRequest (cannot be built in a unit test)
/// Wraps a real `AVAssetResourceLoadingRequest`. AVFoundation's request types are not `Sendable`, so the
/// request lives inside a lock and every access goes through it, one at a time.
private final class ResourceLoadingRequestAdapter: LoadingRequest {
    let requestURL: URL?
    let contentInformationRequest: LoadingContentInformation?
    let dataRequest: LoadingDataRequest?
    private let box: OSAllocatedUnfairLock<AVAssetResourceLoadingRequest>

    init(_ request: AVAssetResourceLoadingRequest) {
        let box = OSAllocatedUnfairLock(uncheckedState: request)
        self.box = box
        requestURL = request.request.url
        contentInformationRequest =
            request.contentInformationRequest == nil ? nil : ContentInformationAdapter(box: box)
        dataRequest = request.dataRequest.map { DataRequestAdapter(box: box, request: $0) }
    }

    var isCancelled: Bool { box.withLockUnchecked { $0.isCancelled } }

    func finishLoading() {
        box.withLockUnchecked { $0.finishLoading() }
    }

    func finishLoading(with error: (any Error)?) {
        box.withLockUnchecked { $0.finishLoading(with: error) }
    }
}

/// The content-information request of a wrapped loading request, accessed through its lock.
private final class ContentInformationAdapter: LoadingContentInformation {
    private let box: OSAllocatedUnfairLock<AVAssetResourceLoadingRequest>

    init(box: OSAllocatedUnfairLock<AVAssetResourceLoadingRequest>) {
        self.box = box
    }

    var contentType: String? {
        get { box.withLockUnchecked { $0.contentInformationRequest?.contentType } }
        set { box.withLockUnchecked { $0.contentInformationRequest?.contentType = newValue } }
    }

    var contentLength: Int64 {
        get { box.withLockUnchecked { $0.contentInformationRequest?.contentLength ?? 0 } }
        set { box.withLockUnchecked { $0.contentInformationRequest?.contentLength = newValue } }
    }

    var isByteRangeAccessSupported: Bool {
        get { box.withLockUnchecked { $0.contentInformationRequest?.isByteRangeAccessSupported ?? false } }
        set { box.withLockUnchecked { $0.contentInformationRequest?.isByteRangeAccessSupported = newValue } }
    }
}

/// The data request of a wrapped loading request; its fixed values are copied, the rest go through the lock.
private final class DataRequestAdapter: LoadingDataRequest {
    let requestedOffset: Int64
    let requestedLength: Int
    let requestsAllDataToEndOfResource: Bool
    private let box: OSAllocatedUnfairLock<AVAssetResourceLoadingRequest>

    init(box: OSAllocatedUnfairLock<AVAssetResourceLoadingRequest>, request: AVAssetResourceLoadingDataRequest) {
        self.box = box
        requestedOffset = request.requestedOffset
        requestedLength = request.requestedLength
        requestsAllDataToEndOfResource = request.requestsAllDataToEndOfResource
    }

    var currentOffset: Int64 {
        box.withLockUnchecked { $0.dataRequest?.currentOffset ?? requestedOffset }
    }

    func respond(with data: Data) {
        box.withLockUnchecked { $0.dataRequest?.respond(with: data) }
    }
}
// coverage-exempt-end
