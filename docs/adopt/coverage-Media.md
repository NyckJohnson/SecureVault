# Media coverage triage (2026-10-30)
Report: docs/adopt/coverage-Media-report.txt (102 lines, 21 blocks). not-in-spec: none.

## exempt (markers added; reviewer to confirm)
- EncryptedVideoLoader.swift `resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)` (needs a real AVAssetResourceLoadingRequest)
- EncryptedVideoLoader.swift AVFoundation adapters section to end of file
- LiveThumbnailRenderer.swift QLThumbnailGenerator call (24-28), real loaded duration (33-34), real frame → UIImage (44)

## missed (→ test-writer)
- LiveThumbnailRenderer: quickLookThumbnail from a cancelled Task → nil (22-23); videoDuration of nonexistent/garbage asset → nil (31-32); videoFrame from cancelled Task → nil (37-39); videoFrame of nonexistent/garbage asset → nil (39-43); folderIcon size/scale/non-blank (47-56); compose: media colour inside window, folder colour outside, non-square media (58-69); folderImage fallback via `folderImage(named:pointSize:)` seam with a bogus name → yellow symbol (72-78, code-writer adds seam); format scale 1/2/3 (80-84)
- LiveThumbnailProvider: outer-Task cancellation reaches `onCancel` (86-87); folder whose first media is already cached uses the cache (194)
- From the unit 1 re-review: cancelledServeDoesNoDecrypt also asserts failedCount == 1 / finishCount == 0; settable `isCancelled` on the fake to cover `if request.isCancelled { return }`; zeroChunkSizeDoesNotServe asserts the failure path directly
