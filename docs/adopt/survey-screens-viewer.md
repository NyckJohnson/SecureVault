# Survey: screens (viewer and editor)

STATUS: done
PASS: screens

Files: `View/FileViewer.swift`, `View/FilePage.swift`, `View/TextEditor.swift`,
`Model/VaultResourceLoaderDelegate.swift`, `Model/FileKind.swift`. "FS" = `Model/FileSystem.swift` (read only at the
declarations these files call).

All three screens are UIKit in code, no storyboards/xibs, **no accessibility identifiers**, no view models.

## 1. FileViewerViewController (`View/FileViewer.swift`)

- Full-screen black, `.fullScreen`, status bar hidden (:51, :66).
- Reached from `FileBrowser.swift:425` with all non-directory siblings and the tapped index. `.rtf` goes straight to
  the editor (`FileBrowser.swift:417-421`); everything else (txt, md, pdf, audio…) comes here.
- Shows: `UIPageViewController` (horizontal scroll) of `FilePageViewController`; top bar (60pt, 50% black) with X,
  centred title (`item.name`), share; bottom video bar (100pt) with current/total time, scrubber + buffer indicator,
  skip −10s, play/pause, +10s, buffering spinner. Video bar hidden unless `FileKind` is `.video` (:262).
- Actions:
  - Tap page area toggles both bars (:243); not coordinated with the image double-tap (`require(toFail:)` absent; guess).
  - X (`close`, :272): remove time observer, pause, **`FileSystem.shared.cleanupTempFiles()`** (deletes everything in
    `NSTemporaryDirectory`), dismiss.
  - Share (`exportCurrent`, :279): `ExportService.shared.export(items[currentIndex], from: self, sourceView: navBar)`.
  - Play/pause (:284): no-op without player; pause cancels hide timer; play starts a 3s fade timer.
  - Skip ±10s: unclamped seek.
  - Scrubber: touchDown sets `isScrubbing`, cancels timer; valueChanged updates label; touchUp seeks with zero
    tolerance, restarts timer; invalid duration just clears `isScrubbing`.
  - Swipe: `didFinishAnimating` sets `currentIndex` from the page's `item.id`, `updateUI(for:)`.
- Data source builds neighbours from `currentIndex ± 1`, not the `viewController` argument (:460-470); no wrap; new page
  every call.
- `player` `didSet`: removes old observers/KVO, resets controls, adds 0.5s periodic observer + `timeControlStatus` and
  duration KVO. Swiping to a non-video page never clears `player`. `hideControlsTimer` not invalidated on close.
- View-model logic: items/index/title, kind → controls visibility, `formatTime`, seek math, buffer fraction,
  play/buffer state, auto-hide rules, temp cleanup on close.

## 2. FilePageViewController (`View/FilePage.swift`)

- One page per item, created only by the pager. Routing by `FileKind` (:33-44):
  - **image** (jpg, jpeg, png, heic, gif, webp): zoomable `UIScrollView` 1x-5x + `UIImageView`; double-tap zooms out if
    zoomed, else to a rect ⅓ of the view centred on the tap; re-centres on zoom; static (gif/webp not animated, guess).
  - **video** (mp4, mov, m4v): `AVPlayerLayer` aspect; sets `viewer?.player = player`; no autoplay.
    - Encrypted + streamable: `vault-stream://` URL from `item.diskURL`, `AVURLAsset` with `VaultResourceLoaderDelegate`
      on serial queue `com.KoalaTVault.resourceloader`; page holds the delegate strongly.
    - Unencrypted: `FileSystem.open` returns `item.diskURL`, played directly.
    - Encrypted but `streamInfo` fails (delegate `init?` nil): falls back to `FileSystem.open` → **whole-file decrypt to tmp**.
  - **rtf** (only by swiping onto an rtf sibling): presents `TextEditorViewController` full-screen from `viewDidLoad` (:141-146).
  - **everything else** (audio, pdf, office, zip, txt, md, other): embedded `QLPreviewController` via `FileSystem.open`
    to a temp URL; data source returns `previewURL ?? item.diskURL` (ciphertext if decrypt failed). Audio has no player.
- Failure paths all silent: open throws → black page; `UIImage(contentsOfFile:)` nil → blank; QuickLook shows its own
  error for ciphertext. No alerts.
- `viewDidDisappear` pauses `viewer.player` (:52-55).
- View-model logic: kind routing, decrypt-or-stream decision, stream URL construction.

## 3. TextEditorViewController (`View/TextEditor.swift`)

- Always in a full-screen nav. Title `item.name`, right Done.
- Reached from `FileBrowser.swift:418` (open rtf), `FileBrowser.swift:234` (New Document), `FilePage.swift:142` (rtf page).
- Shows: `UITextView`, `allowsEditingTextAttributes = true`; input-accessory toolbar: bold, italic, underline, size −/+,
  align left/centre/right. Keyboard inset = full keyboard height (safe area not subtracted).
- Load (`loadDocument`, :101): `FileSystem.open(item)` **on main**; records temp sub-dir if encrypted; empty data →
  empty text; else RTF → `attributedText`; any error → `showError` + `textView.text = ""`.
- Save (`saveDocument`, :122): RTF-encode → `FileSystem.write(data:to:)`. Encrypted: plaintext tmp → encrypt to second
  tmp → delete plaintext (`defer`) → `replaceItemAt` (main thread). Unencrypted: `data.write(to: diskURL)`. Failure → alert.
- Autosave: 1s debounce `Timer` after each change; `viewWillDisappear`; Done saves then dismisses (so saves twice).
- Formatting: bold/italic toggle traits on typing attributes and selection; underline toggles; size ±2pt (min 8, no
  max); alignment on typing attributes and selected range only.
- `viewWillDisappear` removes only the editor's own decrypted temp dir (:44-47).
- View-model logic: RTF encode/decode, load/save/debounce policy, whether to save, trait/alignment transforms.

## How decrypted content reaches the screen

- **Plaintext touches disk** for every encrypted item except streamed video: images, QuickLook types and the editor use
  `FileSystem.open` (FS:343-349) → whole file to `tmp/<UUID>/<item.name>`, synchronously on main from `viewDidLoad`. A
  rebuilt page decrypts again.
- Encrypted video streams via `VaultResourceLoaderDelegate`: `CryptoService.decryptChunk` per needed chunk, in memory,
  nothing on disk; `streamInfo` (total, chunk size) read once in `init?`; decrypt on `DispatchQueue.global(.userInitiated)`.
- Editor save: short-lived plaintext tmp, removed by `defer`.
- `cleanupTempFiles` removes **every** temp entry. Called at viewer close (`FileViewer.swift:275`), cold launch
  (`SceneDelegate.swift:37`), background lock (`AuthService.swift:234`, only when `lockMode != .none`). So plaintext
  lives until viewer close, backgrounding (if locked) or next launch; swiping never cleans; a force-quit leaves it.

## FileKind (`Model/FileKind.swift`)

- `nonisolated enum`, 10 cases, `init(extension:)` lowercases: image (jpg, jpeg, png, heic, gif, webp); video (mp4,
  mov, m4v; avi unsupported per comment); audio (mp3, m4a, wav, aac); pdf; word (doc, docx); spreadsheet (xls, xlsx);
  presentation (ppt, pptx); archive (zip, rar, 7z); text (txt, rtf, md); other.
- Viewer routes only `.image`/`.video` by kind; `rtf` special-cased by raw extension (`FilePage.swift:39`). txt/md go to
  QuickLook, not editable.

## VaultResourceLoaderDelegate (`Model/VaultResourceLoaderDelegate.swift`)

- `init?(encryptedURL:fileExtension:)` nil if `CryptoService.streamInfo` throws; content type
  `UTType(filenameExtension:)`, default mpeg4Movie.
- `shouldWaitForLoadingOfRequestedResource` returns true, fulfils on a global queue.
- Content-info: type, length (plaintext total), byte ranges supported.
- Data: range `[offset, min(offset+length, totalSize))` or to end for `requestsAllDataToEndOfResource`; empty range
  finishes; decrypts overlapping chunks, slices, `respond(with:)`; `finishLoading()` unless cancelled; error →
  `finishLoading(with:)`. `didCancel` does nothing.
- API-Memo obs #19 confirmed (`return` inside `autoreleasepool`, :67), harmless.
- If the key is wiped on background, decrypt throws and the stream errors.

## Navigation

- Browser → viewer (non-dir, non-rtf; full-screen; X back). Browser → editor (rtf, full-screen nav; Done back).
  New Document → empty file → editor; browser reloads after presenting.
- Viewer → editor by swiping onto rtf; Done leaves a black page. Viewer → share sheet via `ExportService`.

## Journeys checked

### Journey 5 (view/edit)
- Image: tap → viewer at that image; encrypted → decrypted to tmp (main); pinch/double-tap zoom; swipe; tap toggles
  bars; X cleans tmp.
- Video: paused player; play → bars fade after 3s; tap brings back; scrubber/skip/spinner; swipe away pauses; X.
- Text: tap .rtf → editor (decrypt if needed); autosave 1s; formatting; Done saves and dismisses.
- Failures: image/video decrypt failure → black page, no message; editor load failure → alert (see data-loss issue).
- Differences: only `.rtf` is editable (txt/md → QuickLook); viewer also handles audio, pdf, office, archives via QuickLook.

### Journey 7 (viewer side)
- Share exports only `items[currentIndex]`, anchored to the top bar. `close()` deletes all temp files, including export
  temp files not yet shared.

## Other behavior

- Backgrounding with viewer/editor open (locked mode): `AuthService:231-234` wipes the key and clears tmp; viewer stays
  on screen; streaming errors; encrypted editor autosave fails with an alert. Lock screen presented over it by AuthService.
- Concurrency: all main except resource-loader chunk decrypt; `FileSystem.open`/`write` on main from views. Default
  MainActor isolation on; timers use `MainActor.assumeIsolated`; KVO hops via `Task`.
- Singletons: `FileSystem.shared`, `ExportService.shared`, `CryptoService.shared`, `NotificationCenter.default`.

## API-Memo observations

- #19 confirmed. No others name these files. Memo's FileViewer/FilePage/TextEditor sections match the code.

## Suspected issues

- `TextEditor.swift:116-119, 122-132` **possible data loss**: a failed load sets empty text and shows an alert but isn't
  tracked; `viewWillDisappear`/Done/autosave then write empty RTF over the original.
- `TextEditor.swift:39-48, 154-156` Done saves twice; repeated alerts possible; after a background key wipe an encrypted
  save fails with an alert.
- `FileBrowser.swift:221-234` New Document `isEncrypted: false` → editor's `write` stores **plaintext RTF in an
  encrypted vault** (guess; verify the mapping/encryption isn't applied later). Ad-hoc `VaultItem` not in the mapping.
- `FilePage.swift:57-58, 102-111, 149` decrypt on main with no progress; big files freeze UI; silent failures.
- `FilePage.swift:105-111` `streamInfo` failure falls back to whole-file decrypt to tmp; hides the streaming failure.
- `FileViewer.swift:456-470` neighbours from `currentIndex`, not the argument; pages rebuilt each call → repeated decrypt.
- `FilePage.swift:29-45, 122-132` (guess) preloaded neighbour pages: a video page could replace `viewer.player`; an rtf
  page could present the editor over the current item. Journey tests should check.
- `FilePage.swift:139-146` editor presented from `viewDidLoad` (may not be in a window); black page after Done.
- `FileViewer.swift:272-277` + FS:726-729 close deletes **all** temp files (exports in progress, thumbnail
  `stableURL` cache at FS:272 (guess), editor temp dir).
- Plaintext temp files live for the viewer's lifetime; no explicit file-protection attribute (guess); force-quit leaves
  them until next launch.
- `FileViewer.swift:378` `Float(current / total)` NaN/inf when duration is 0.
- `FileViewer.swift:299-306` skip unclamped, default tolerance.
- `FileViewer.swift:39-45, 272-277` old player not cleared on swipe.
- `FileViewer.swift:83-84` tap vs double-tap not coordinated (guess).
- `FileViewer.swift:313` timer not cancelled on close (weak self, harmless).
- `FilePage.swift:165` QuickLook gets ciphertext `item.diskURL` on decrypt failure.
- `TextEditor.swift:136-140` keyboard inset ignores safe area (guess).
- Notes say "basic text editor for text files"; only `.rtf` is editable.
- No accessibility identifiers in these files.

NOT READ: none skipped. Opened `FileBrowser.swift`, `SceneDelegate.swift`, `AuthService.swift`, `FileSystem.swift` only
at the lines named above.
