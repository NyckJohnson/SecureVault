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

## Round 2
- EncryptedVideoLoader.swift:34 `extension LoadingRequest { var isCancelled: Bool { false } }` — not-in-spec (dead code). Both conformers (`FakeLoadingRequest` in tests, `ResourceLoadingRequestAdapter`) declare their own `isCancelled`; nothing uses the default. Remove lines 33-35 (the extension); the protocol requirement at line 28 stays.
- EncryptedVideoLoader.swift:101, :109 — exempt (marker fixed). The begin/end pair now wraps the whole `resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)` method, signature to closing brace.
- LiveThumbnailRenderer.swift:52 `return nil` in `folderIcon` — not-in-spec (unreachable). `folderImage(named:pointSize:)` returns nil only if `UIImage(systemName: "folder.fill")` is nil, which never happens on iOS. Would remove: the `guard let ... else { return nil }` (make `folderImage` return a non-optional, e.g. fall back to `UIImage()`, which adds another unreachable line) — or accept the nil path with a human-approved exemption. Not exempted here because the pipeline rule prefers removal over exemption.

## Exemption review (2026-10-30) — fail, reclassified
- LiveThumbnailRenderer.swift:36 `seconds.isFinite && seconds >= 0 ? seconds : nil` — exemption invalid (pure logic) → **missed**: extract `static func finiteDuration(_ seconds: Double) -> TimeInterval?`, test 0, 12.5 (returned), -1, .nan, .infinity (nil). :35 exemption valid.
- EncryptedVideoLoader.swift:94-105 delegate's scheme check → **missed** (optional, taken): extract `func handles(_ url: URL?) -> Bool`, test vault-stream / other scheme / nil.
- Folder-image fallback test: also assert a yellow-ish pixel.
- Adapters (192-267): exemption accepted (nil fallbacks unreachable without a real request).

## Round 3
- LiveThumbnailRenderer.swift:36 `return Self.finiteDuration(seconds)` — exempt (marker added; reviewer to confirm). Reached only after `asset.load(.duration)` succeeds, which needs a real video asset (line 35 is exempt for the same reason). It is a one-call delegation; the logic (finite and non-negative check) lives in `finiteDuration`, which is tested directly.
