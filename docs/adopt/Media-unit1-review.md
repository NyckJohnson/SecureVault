# Media unit 1 review (2026-10-30) — RESULT: pass, minor findings

1. LiveThumbnailProvider.swift:67 — cache keyed by item id only (as memo says); legacy key also had modification date + size, so a file replaced/edited at the same path never showed a stale thumbnail. Now relies on callers calling `clearCache(for:)`. → decide; check in switch-over.
2. LiveThumbnailProvider.swift:168 — folder picks first media by `.name, .ascending`; legacy followed the user's `sortOption`/`sortDirection`. Behavior change not in decisions log. → decide.
3. LiveThumbnailProvider.swift:70-78 — tiny window between creating the generation Task and registering it; a cancel in that window is missed (harmless).
4. EncryptedVideoLoader.swift:104, :150 — `serve` runs blocking `decryptChunk` on the cooperative pool (legacy: serial DispatchQueue). Optional: move onto `delegateQueue`.
5. EncryptedVideoLoader.swift:150-155 — a short non-final chunk that partly covers the range is answered with a gap (misaligned data) instead of throwing `truncatedStream`.
6. EncryptedVideoLoader.swift:80-85 — stream registry never shrinks (one small entry per encrypted item; token reused per id).
7. EncryptedVideoLoaderTests — no assertions for `unknownStream`, `truncatedStream`, `chunkSize == 0`, `serve`'s `isCancelled` early return (isCancelled not in spec). → coverage triage `missed`; decide whether isCancelled belongs in spec.
8. LiveThumbnailRenderer.swift and the private adapters (EncryptedVideoLoader.swift:183-254) — untested; exempt only lines that truly need AVFoundation/QuickLook; test folder drawing / AVMakeRect / compose.
9. LiveThumbnailRenderer.swift:9 — "nej_FolderIconB" asset name duplicated from SharedUI's mapping (no import; boundary kept).
