# Media unit 1: types the tests require (from the test-writer, 2026-10-30)

## ThumbnailCache.swift
- `final class ThumbnailCache: Sendable`, `init()`, lock-protected state.
- `var generation: Int { get }` (changes on `removeAll()`); `var count: Int { get }`
- `func image(for id: String) -> UIImage?`
- `func store(_ image: UIImage, for id: String, generation: Int)` (ignored when generation is stale)
- `func remove(id: String)`; `func removeAll()` (starts a new generation)

## LiveThumbnailProvider.swift
- `protocol ThumbnailRendering: Sendable`:
  - `func quickLookThumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> UIImage?`
  - `func videoDuration(of asset: AVURLAsset) async -> TimeInterval?`
  - `func videoFrame(of asset: AVURLAsset, at time: TimeInterval, size: CGSize, scale: CGFloat) async -> UIImage?`
  - `func folderIcon(size: CGSize, scale: CGFloat) -> UIImage?`
  - `func compose(_ media: UIImage, onto folderIcon: UIImage, size: CGSize, scale: CGFloat) -> UIImage?`
- `LiveThumbnailProvider: ThumbnailProviding`, `init(store: VaultStoring, cipher: FileCipher, videoAssets: VideoAssetProviding, renderer: ThumbnailRendering)` (may add defaulted `maxConcurrentDecrypts: Int = 2` after `renderer`).
- `static func frameTime(forDuration: TimeInterval) -> TimeInterval` = min(5, duration / 2).

## EncryptedVideoLoader.swift
- `final class EncryptedVideoLoader: NSObject, AVAssetResourceLoaderDelegate, VideoAssetProviding`, `init(cipher: FileCipher)`.
- Protocols standing in for AVFoundation loading-request types (real `AVAssetResourceLoadingRequest` wrapped by adapters):
  - `protocol LoadingContentInformation: AnyObject, Sendable { var contentType: String? {get set}; var contentLength: Int64 {get set}; var isByteRangeAccessSupported: Bool {get set} }`
  - `protocol LoadingDataRequest: AnyObject, Sendable { var requestedOffset: Int64 {get}; var requestedLength: Int {get}; var requestsAllDataToEndOfResource: Bool {get}; var currentOffset: Int64 {get}; func respond(with data: Data) }`
  - `protocol LoadingRequest: AnyObject, Sendable { var requestURL: URL? {get}; var contentInformationRequest: LoadingContentInformation? {get}; var dataRequest: LoadingDataRequest? {get}; func finishLoading(); func finishLoading(with error: (any Error)?) }`
- `func serve(_ request: any LoadingRequest) async`: finishes the request before returning; the real delegate method wraps it in a Task.
- `asset(for:)`: plaintext → `AVURLAsset(url: item.diskURL)`; encrypted → `cipher.streamInfo(of:)` (throws on invalid header), registers the item, returns an `AVURLAsset` with a per-item unique `vault-stream://` URL whose `resourceLoader.delegate` is the loader.

## Notes
- Gated tests carry `.timeLimit(.minutes(1))`.
- Cancel before start → nil with no decrypt/render; cancelling a folder must cancel the media request as a Swift Task (renderer sees `Task.isCancelled`).
- The 2-decrypt slot covers decrypt through temp removal (test counts `makeTempDirectory` on `MockVaultStoring`).
- Folder children: `store.contents(of:sortedBy: .name, .ascending)`; first image or video wins.
- Mock cipher `decryptChunk` returns raw bytes; chunk size is the mock's 1 MiB.
- Shared test helpers: `KoalaTVaultTests/Media/MediaTestSupport.swift`.
