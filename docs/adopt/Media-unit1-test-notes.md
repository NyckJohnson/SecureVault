# Media unit 1: types the tests require (from the test-writer, 2026-10-30)

## ThumbnailCache.swift
- `final class ThumbnailCache: Sendable`, `init()`, lock-protected state.
- `var generation: Int { get }` (changes on `removeAll()`); `var count: Int { get }`
- `struct ThumbnailCache.Key: Hashable, Sendable`, `init(id: String, dateModified: Date, fileSize: Int?)` (changed 2026-10-30: item id + `dateModified` + `fileSize`)
- `func image(for key: Key) -> UIImage?`
- `func store(_ image: UIImage, for key: Key, generation: Int)` (ignored when generation is stale)
- `func remove(id: String)` (removes every version of that item id); `func removeAll()` (starts a new generation)

## LiveThumbnailProvider.swift
- `protocol ThumbnailRendering: Sendable`:
  - `func quickLookThumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> UIImage?`
  - `func videoDuration(of asset: AVURLAsset) async -> TimeInterval?`
  - `func videoFrame(of asset: AVURLAsset, at time: TimeInterval, size: CGSize, scale: CGFloat) async -> UIImage?`
  - `func folderIcon(size: CGSize, scale: CGFloat) -> UIImage?`
  - `func compose(_ media: UIImage, onto folderIcon: UIImage, size: CGSize, scale: CGFloat) -> UIImage?`
- `LiveThumbnailProvider: ThumbnailProviding`, `init(store: VaultStoring, cipher: FileCipher, videoAssets: VideoAssetProviding, renderer: ThumbnailRendering, preferences: PreferencesStoring)` (changed 2026-10-30; may add defaulted `maxConcurrentDecrypts: Int = 2` after `preferences`). Cache key is built from the item's id, `dateModified`, `fileSize`.
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
- Folder children: `store.contents(of:sortedBy: preferences.sortOption, preferences.sortDirection)`, both read at request time; first image or video wins.
- Mock cipher `decryptChunk` returns raw bytes; chunk size is the mock's 1 MiB.
- Shared test helpers: `KoalaTVaultTests/Media/MediaTestSupport.swift`.
- Test-only helper `ScriptedFileCipher` (in `MediaTestSupport.swift`) scripts `StreamInfo` and chunk bytes (short chunks, chunkSize 0), since `MockFileCipher` always returns full chunks.
- `chunkSize == 0`: reachable through the `FileCipher` contract (`StreamInfo` is a plain struct with no validation), so tested: `asset(for:)` may refuse it, otherwise the data request must fail without trapping or returning data.
- `serve` on an already-cancelled task: only asserted that no chunk is decrypted (how the request finishes is not specified).
- Unknown/foreign URL (unissued `vault-stream://`, another loader's URL, other scheme): request fails with an error.
