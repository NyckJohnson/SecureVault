# SecureVault — API Surface Memo

Reference for public/internal-facing members across uploaded files (last updated 2026-09-27: added EntitlementService, PaywallViewController; updated FileSystem, SecuritySettings, ImportService). Private helpers omitted unless useful for context. Use this to scope future feature conversations without re-uploading everything.

---

## FileSystem.swift
Core file storage layer. Handles the vault directory tree, encryption-transparent CRUD, trash, and migration between encrypted/plaintext.

**Types**
- `struct VaultDirectory { name: String, diskURL: URL (internal), rootURL: URL (internal) }` — `.root` static var (Documents dir, display name "KoalaTVault"). `rootURL` is carried down through every subdirectory so trash/limit logic knows which vault root an item belongs to.
- `struct VaultItem: Identifiable, Hashable, Sendable` — `id, name, isDirectory, dateModified, fileSize, deletedAt, diskURL (internal), rootURL (internal), isEncrypted (internal)`. Hash/equality by `id` only.
- `struct VaultMapping: Codable { originalName: String }`
- `enum FileSystemError: LocalizedError { mappingUnreadable, fileLimitReached }`
- `FileSystem.TrashEntry: Codable { originalDiskName, originalDirectoryURL, deletedAt, isEncrypted, originalName, rootURL }` (DEBUG alias `TrashEntryForTesting`)

**FileSystem (singleton `.shared`)**
- `contents(of:) throws -> [VaultItem]` — list directory; folders always first, then PreferencesService sort settings. Throws `.mappingUnreadable` if the `.vault_map` exists but can't be read.
- `importItems(from:to:progress:) throws` — bulk import (files/folders), dedupes via SHA-256. **Free tier:** if `!EntitlementService.shared.isUnlockedSync`, counts existing files under `rootURL` + incoming files and throws `.fileLimitReached` if the total would exceed `EntitlementService.freeFileLimit` (all-or-nothing, checked before any copy)
- `checkImportAllowed(additionalCount:in:) throws` — same limit check; **caller must invoke before** `importFromCameraRoll`, which does not check itself
- `importFromCameraRoll(results:to:completion: ([String] succeededIdentifiers, Int failed))` — import from PHPickerResult; completion on main
- `open(_:) throws -> URL` — decrypts to temp file if needed, returns readable URL
- `write(data:to:) throws` — overwrite item contents (re-encrypts if needed)
- `prepareForExport(_:progress:) throws -> [URL]`
- `exportToCameraRoll(_:completion:)`
- `createFolder(named:in:) throws -> VaultDirectory`
- `move(_:to:) throws`, `copy(_:to:) throws`, `rename(_:to:) throws`, `delete(_:) throws` (→ trash) — move/copy/rename resolve name collisions against existing items in the target directory, including for encrypted items (compared by original display name via the mapping)
- **Trash is per vault root** (`.trash` folder + encrypted `.trash_map` under `rootURL`):
  - `trashDirectory(for rootURL:) -> VaultDirectory` (creates if missing)
  - `moveToTrash(_:) throws`, `restoreFromTrash(_:) throws`, `permanentlyDelete(_:) throws`
  - `contentsOfTrash(for root:) throws -> [VaultItem]` — newest first
  - `emptyTrash(for root:) throws` — deliberately best-effort; also sweeps files an unreadable map doesn't know about
  - `cleanupExpiredTrashItems(for root:)` — 30-day cutoff; never overwrites the map if it couldn't be read
- `filesToMigrate(toEncrypted:in:) throws -> [(item, directory)]`
- `migrateVaultToEncrypted(in:progress:) throws`, `migrateFileToEncrypted(_:in:) throws`
- `migrateVaultToDecrypted(in:progress:) throws`, `migrateFileToDecrypted(_:in:) throws`
- `cleanupTempFiles()`
- DEBUG-only: `testForcedMigrationFailureFileName` (also `UITEST_FAIL_MIGRATION_FILE` env var), `diagnoseDiskState()`, `testTrashMap(for:)`/`saveTestTrashMap(_:for:)`, `testMapping(in:)`
- `Notification.Name.fileRestored`

Uses `CryptoService`, `PreferencesService`, `EntitlementService`. Encrypted files stored under random UUID names with a `.vault_map` JSON mapping UUID→original name (itself encrypted if a key is loaded). Map loading: missing file = empty; unreadable file = throw `.mappingUnreadable` (never treated as empty, so a later save can't wipe real data). No key loaded → falls back to reading a legacy plaintext map.

---

## AuthService.swift
App lock/auth flow: password + biometrics, lock screen presentation, lifecycle hooks.

**Types:** `enum AuthError: wrongPassword, keychainError`

**AuthService (singleton `.shared`)**
- `lockMode: LockMode` (proxies PreferencesService)
- `createPassword(_:) throws`, `changePassword(to:) throws`, `verifyPassword(_:) throws`
- `hasPassword() -> Bool`, `removePassword()`
- `finalizeMigration(type:targetLockMode:completedFully:)` — called after MigrationViewController completes
- `biometricsAvailable: Bool`, `biometricType: String`
- `authenticateWithBiometrics(completion: (Bool, Error?) -> Void)`
- `isLocked: Bool`, `hasAuthenticated: Bool` (public state vars)
- `static let vaultUnlockedNotification: Notification.Name`
- `handleBackground(in:)`, `handleForeground(in:)`, `handleInitialLaunch(in:)` — scene lifecycle entry points
- `didAuthenticate(in:)` — call after successful unlock; dismisses lock screen, reloads browser, posts notification

Depends on `CryptoService` (wraps/unwraps master key), `PreferencesService`, `FileSystem.cleanupTempFiles()`, `ThumbnailService.clearCache()`, `LockScreenViewController`, `FileBrowserViewController`, `MigrationViewController`.

---

## CryptoService.swift
AES-GCM encryption, key derivation/wrapping, chunked streaming file format.

**Types:** `enum CryptoError: noKeyLoaded, encryptionFailed, decryptionFailed` (LocalizedError)

**CryptoService (singleton `.shared`, `@unchecked Sendable`)**
- `isKeyLoaded: Bool`
- `wipeKey()` — clears in-memory symmetric key (no side effects/logging)
- `createMasterKey(wrappedBy:) throws` — new random master key, wraps w/ password
- `unwrapMasterKey(with:) throws` — loads master key into memory from password
- `rewrapMasterKey(with:) throws` — requires key already in memory
- `hasMasterKeyBlob() -> Bool`, `wipeMasterKeyBlob()`
- `encrypt(data:) throws -> Data`, `decrypt(data:) throws -> Data` — single-shot, requires loaded key
- `encryptFile(at:to:) throws`, `decryptFile(at:to:) throws` — chunked streaming (1MB chunks, custom "SVC3" format: magic+chunkSize+totalSize header, then length-prefixed AES-GCM chunks)
- `streamInfo(for:) throws -> (totalSize: Int, chunkSize: Int)` — header-only read
- `decryptChunk(at:from:chunkSize:totalSize:) throws -> Data` — random access single-chunk decrypt (for streaming playback)

Password-derived wrapping key: PBKDF2-HMAC-SHA256, 100k iterations, salt persisted in Keychain. Master key + salt + wrapped blob all in Keychain (generic password items).

---

## ErrorPresenting.swift
`protocol ErrorPresenting: UIViewController` with default implementations:
- `showError(_ error: Error)`, `showError(_ message: String)`, `showSuccess(_ message: String)`

Conform any UIViewController to get one-line alert presentation.

---

## ExportService.swift
UI flow for exporting vault items out of the app.

**ExportService (singleton `.shared`)**
- `export(_ item:from:sourceView:barButtonItem:)` — single item convenience
- `exportMultiple(_:from:sourceView:barButtonItem:)` — action sheet: "Save to Files" / "Save to Camera Roll" (if media present) / Cancel

Delegates actual file work to `FileSystem.shared.prepareForExport` / `.exportToCameraRoll`.

---

## FileKind.swift
`nonisolated enum FileKind: image, video, audio, pdf, word, spreadsheet, presentation, archive, text, other`
- `init(extension: String)` — maps file extension (lowercased) to kind. Note: `.avi` deliberately unsupported (commented).

---

## ImportService.swift
UI flow for importing files into the vault (files, folders, photos).

**ImportService (singleton `.shared`, NSObject)**
- `cameraRollDeleter: CameraRollDeleting` (injectable, default `PhotoLibraryCameraRollDeleter`)
- `promptImport(into:from:barButtonItem:completion:)` — action sheet: Choose Files / Choose Folder / Choose Photos / Cancel
- Conforms to `UIDocumentPickerDelegate`, `PHPickerViewControllerDelegate`
- Files/folders: `FileSystem.importItems` runs on a background queue with a `ProgressOverlay` (updates throttled to ~10/s). On `.fileLimitReached`, it presents `PaywallViewController` (`.formSheet`); other errors go to `showError` if the presenter conforms to `ErrorPresenting`
- Photos: calls `FileSystem.checkImportAllowed(additionalCount:in:)` first and presents the paywall if that throws; otherwise runs `importFromCameraRoll` and shows an "N imported, M failed" alert when anything failed
- The paywall is presented without `onUnlock`, so after purchasing the user has to start the import again
- `confirmDeleteFromCameraRoll(identifiers:)` — deletes the imported originals through `cameraRollDeleter` right away (no in-app prompt; iOS shows its own delete confirmation)

**Protocol:** `CameraRollDeleting { deleteAssets(withIdentifiers:) }`
**Struct:** `PhotoLibraryCameraRollDeleter: CameraRollDeleting`

Delegates actual copy/encrypt work to `FileSystem.shared.importItems` / `.importFromCameraRoll`.

---

## PreferencesService.swift
UserDefaults-backed settings.

**Types:**
- `enum LockMode: String { none, password, passwordAndBiometrics }`
- `enum SortOption: String, CaseIterable { name, type, dateModified }` — has `displayName`
- `enum SortDirection: String { ascending, descending }`

**PreferencesService (singleton `.shared`)**
- `hasCompletedSetup: Bool`
- `lockMode: LockMode`
- `pendingMigrationType: MigrationViewController.MigrationType?`
- `pendingMigrationTargetLockMode: LockMode?` — only meaningful when pendingMigrationType == .encrypt
- `sortOption: SortOption`, `sortDirection: SortDirection`

---

## ThumbnailService.swift
Thumbnail generation/caching for files and folders (incl. encrypted files and video).

**ThumbnailService (singleton `.shared`)**
- `thumbnail(for:size:completion:) -> QLThumbnailGenerator.Request?` — returns nil if served from cache/async path; caller can cancel via returned request
- `cancelThumbnail(for:)`
- `clearCache()`, `clearCache(for:)`

Internals: decrypts encrypted files off a semaphore-limited (2 concurrent) queue before generating QuickLook thumbnails; videos use `VaultResourceLoaderDelegate` + AVAssetImageGenerator; folder thumbnails compose a folder icon with an inset preview of first media child (`FileIconProvider` dependency, not in this batch).

---

## VaultResourceLoaderDelegate.swift
`final class VaultResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate`
- `init?(encryptedURL:fileExtension:)` — fails if `CryptoService.streamInfo` can't read header
- Implements `AVAssetResourceLoaderDelegate` methods to serve byte-range requests by decrypting only the needed chunks via `CryptoService.decryptChunk`, enabling scrubbing/streaming playback of encrypted video without full decryption.

---

## FileBrowser.swift
Main grid view — the app's home screen and every subdirectory. Handles browsing, select mode, bulk actions, drag & drop, context menus.

**FileBrowserViewController: UIViewController, ErrorPresenting**
- `init(directory: VaultDirectory)`
- `reloadAfterAuth()` — called by AuthService after unlock
- Sections wired via `UICollectionViewDiffableDataSource<Int, VaultItem>`
- Nav bar (normal mode): Settings (root only) / New Folder, New Document (.rtf), Import, Sort, Select
- Nav bar (select mode): Cancel / Delete, Move, Export, Copy (bulk)
- Tapping a directory pushes another `FileBrowserViewController`; tapping `.rtf` opens `TextEditorViewController`; tapping other files opens `FileViewerViewController` (paged, non-directory siblings only)
- Context menu per item: Export, Move (via `FolderPickerViewController`), Copy, Rename, Delete
- Conforms to `UICollectionViewDragDelegate`/`DropDelegate` (drag files onto folders to move) and `FolderPickerDelegate`
- Listens for `.fileRestored` notification to refresh
- DEBUG: logs temp-file stats and calls `FileSystem.shared.diagnoseDiskState()` in `viewDidAppear`

All file ops delegate to `FileSystem.shared`; import to `ImportService.shared`; export to `ExportService.shared`.

---

## FileViewer.swift
Full-screen paged media viewer (photos/video/other) with custom video transport controls.

**FileViewerViewController: UIViewController**
- `init(items: [VaultItem], startingAt: Int)`
- `player: AVPlayer?` — public var; set by `FilePageViewController` when a video page loads. `didSet` wires/removes the time observer.
- `updatePlayPauseButton(isPlaying:)` — called externally by `FilePageViewController`
- Hosts a `UIPageViewController` of `FilePageViewController` pages (swipe between items)
- Custom transport bar: play/pause, skip ±10s, scrubber w/ buffer indicator, spinner, auto-hide after 3s of playback
- Nav bar: close (X) and export (delegates to `ExportService.shared.export`)
- Conforms to `UIPageViewControllerDataSource`/`Delegate`

---

## FilePage.swift
One page inside `FileViewerViewController` — renders a single item (image/video/QuickLook/rtf).

**FilePageViewController: UIViewController**
- `init(item: VaultItem, viewer: FileViewerViewController)`
- Image: zoomable `UIScrollView` + double-tap-to-zoom
- Video: builds `AVPlayer`, streams via `VaultResourceLoaderDelegate` if encrypted (custom `vault-stream://` scheme), else opens decrypted temp file directly
- `.rtf`: presents `TextEditorViewController` full-screen instead of rendering inline
- Everything else: `QLPreviewController` (data source only, `numberOfPreviewItems`/`previewController(_:previewItemAt:)`)
- Pauses `viewer.player` on `viewDidDisappear`

---

## FileCell.swift
`final class FileCell: UICollectionViewCell` — grid cell used by `FileBrowserViewController`.
- `static let reuseID`
- `configure(with item: VaultItem, gridMode: Bool)` — sets icon (via `FileIconProvider`), name, size, kicks off async thumbnail load via `ThumbnailService`
- `setSelected(_:inSelectMode:)` — checkmark overlay + dim for select mode
- Cancels/clears thumbnail request in `prepareForReuse`

---

## FileIconProvider.swift
`enum FileIconProvider` — stateless icon/color lookup, no instances.
- `static let hasCustomFolderAsset: Bool`
- `static func folderImage(pointSize:) -> UIImage?` — custom asset (`nej_FolderIconB`) if bundled, else SF Symbol `folder.fill`
- `static func icon(for item: VaultItem) -> UIImage?` — SF Symbol per `FileKind`
- `static func iconColor(for item: VaultItem) -> UIColor` — tint per `FileKind` (folders yellow unless custom asset, which is untinted/`.clear`)

Used by `FileCell`, `ThumbnailService` (folder composition), `RecentlyDeletedViewController`, `FolderPickerViewController` (folder icon only, hardcoded).

---

## FolderPicker.swift
Modal folder-navigation picker used for Move operations.

**Protocol:** `FolderPickerDelegate { folderPicker(_:didSelectFolder:) }`

**FolderPickerViewController: UIViewController**
- `init(rootDirectory: VaultDirectory, currentDirectory: VaultDirectory)`
- `delegate: FolderPickerDelegate?`
- Table of subfolders only; drilling in pushes a new picker instance; "Move Here" confirms `currentDirectory`; "Cancel" dismisses
- Has leftover `print()` debug statements in init/viewDidLoad

---

## LockScreen.swift
Password/biometric entry screen shown by `AuthService`.

**LockScreenViewController: UIViewController**
- Password field + Unlock button; biometric button shown only when `lockMode == .passwordAndBiometrics` and biometrics available
- Auto-attempts biometric unlock on `viewDidAppear` if lock mode requires it
- On success calls `AuthService.shared.didAuthenticate(in:)`
- Maps `LAError` cases to user-facing messages (userCancel/userFallback/systemCancel are silent)
- Accessibility identifiers: `passwordField`, `unlockButton` (UI test hooks)
- Conforms to `UITextFieldDelegate` (Return key submits)

---

## Migration.swift
Full-screen progress UI that drives bulk encrypt/decrypt of the vault, resumable across lock/background.

**MigrationViewController: UIViewController, ErrorPresenting**
- `nonisolated enum MigrationType: String { encrypt, decrypt }`
- `init(type:directory: .root, targetLockMode:, onComplete: (_ completedFully: Bool) -> Void)`
- Persists `PreferencesService.pendingMigrationType`/`pendingMigrationTargetLockMode` at start, clears on full success — allows resuming after relaunch
- Pauses itself if the crypto key becomes unavailable mid-run (e.g. backgrounded/locked) and listens for `AuthService.vaultUnlockedNotification` to resume
- On per-file failure: collects failures, then shows Retry/Skip alert at the end rather than aborting
- Uses a `UIBackgroundTaskIdentifier` to get extra time when backgrounded
- Calls back via `onComplete(completedFully: Bool)` — caller (typically `SecuritySettingsViewController`) is responsible for calling `AuthService.shared.finalizeMigration(...)` in that callback
- DEBUG: `testFailedFileNames`, `testIsPaused`, `testStatusText`, `testTapRetry()`, `testTapSkip()`

Drives `FileSystem.shared.filesToMigrate/migrateFileToEncrypted/migrateFileToDecrypted`.

---

## ProgressOverlay.swift
Reusable blocking progress HUD.

**ProgressOverlay: UIView**
- `static func show(in viewController:, title:, cancellable: Bool = false, onCancel: (() -> Void)? = nil) -> ProgressOverlay` — adds itself to the VC's view and returns the instance
- `update(progress: Float, status: String)` — thread-safe (hops to main)
- `dismiss()` — fades out and removes itself (thread-safe)

Used by `ExportService` and `ImportService` during long-running file operations.

---

## RecentlyDeleted.swift
Trash UI.

**RecentlyDeletedViewController: UIViewController, ErrorPresenting**
- Lists `FileSystem.shared.contentsOfTrash(for:)`; shows days-until-permanent-deletion (30-day window) per item
- Nav bar "Empty Trash" (disabled when empty) → confirms → `FileSystem.shared.emptyTrash(for:)`
- (Signatures updated to FileSystem's per-root trash API; this file hasn't been re-uploaded since, so details may be stale.)
- Row tap → action sheet: Restore (`restoreFromTrash`, posts `.fileRestored`) or Delete Permanently (`permanentlyDelete`)

---

## SecuritySettings.swift
Security/lock settings screen — lock mode picker, password change, trash entry point.

**SecuritySettingsViewController: UIViewController, ErrorPresenting**
- Sections (in order): Pro, Lock Mode, Password, Storage
  - **Pro** (no header): "Upgrade to Pro" (disclosure) → presents `PaywallViewController` as `.formSheet`, `onUnlock` reloads the table; shows "Pro Unlocked" + checkmark (non-selectable) once `EntitlementService.shared.isUnlockedSync`. Accessibility identifier: `upgradeToProCell`
  - **Lock Mode**: No Lock / Password / Password+Biometric / Re-encrypt Everything (only when lockMode != .none and unencrypted files exist)
  - **Password**: Change Password (hidden if lockMode == .none)
  - **Storage** (was "Trash"): Recently Deleted
- Changing to `.none` confirms then runs a `.decrypt` migration; changing to a password mode when no password exists prompts for one then runs an `.encrypt` migration; switching between the two password modes just sets `lockMode`
- `hasUnencryptedFiles` is computed on a background queue (`FileSystem.shared.filesToMigrate(toEncrypted: true, in: .root)`) at load and after each migration; "Re-encrypt Everything" runs an `.encrypt` migration
- `promptChangePassword`: verifies current password, then calls `AuthService.shared.changePassword(to: new)` — re-wraps the existing master key under the new password
- DEBUG: `testSetHasUnencryptedFiles(_:)`, `testTableView`

---

## SetupWizard.swift
First-run onboarding: choose lock mode, set password.

**SetupWizardViewController: UIViewController, ErrorPresenting**
- Three selectable option buttons (No Lock / Password / Password+Biometric, biometric disabled if unavailable) + Continue
- Choosing a password mode prompts for password/confirmation, then calls `CryptoService.shared.createMasterKey(wrappedBy: password)` and sets `authService.lockMode`
- On completion sets `PreferencesService.shared.hasCompletedSetup = true` and dismisses
- Accessibility identifier: `continueButton`

---

## TextEditor.swift
Simple RTF editor for `.rtf` vault items.

**TextEditorViewController: UIViewController, ErrorPresenting**
- `init(item: VaultItem)`
- Loads/saves via `FileSystem.shared.open`/`.write(data:to:)`, RTF-encoded `NSAttributedString`
- Formatting toolbar (bold/italic/underline, font size ±, alignment) built into `textView.inputAccessoryView`
- Autosaves 1s after each keystroke (debounced `Timer`) and again on `viewWillDisappear`/dismiss

---

## AppDelegate.swift / SceneDelegate.swift / Info.plist
App entry points and lifecycle wiring — thin, mostly delegates to the services above.

**AppDelegate**
- `didFinishLaunchingWithOptions`: when launched with `--uitesting` CLI arg, resets state for UI tests — clears setup flag, lock mode, password, trash, wipes crypto key, deletes everything in vault root, disables animations, and optionally seeds one file from `UITEST_SEED_FILE_NAME` env var (plaintext, content `"uitest content"`)
- Standard `UISceneSession` boilerplate (no custom logic)

**SceneDelegate**
- `window: UIWindow?`
- `scene(_:willConnectTo:options:)` — builds root nav (`FileBrowserViewController(directory: .root)` in a `UINavigationController`, large titles); presents `SetupWizardViewController` if `!hasCompletedSetup`, else calls `AuthService.shared.handleInitialLaunch(in:)`; also runs `FileSystem.shared.cleanupExpiredTrashItems(for:)` (now takes a root) and `.cleanupTempFiles()` on launch
- `sceneDidBecomeActive` → `AuthService.shared.handleForeground(in:)`
- `sceneWillResignActive` → `AuthService.shared.handleBackground(in:)`
- `setupMigrationResumeObserver()` (called at the start of `willConnectTo`) / `resumePendingMigrationIfNeeded()` — observes `AuthService.vaultUnlockedNotification` and, if `PreferencesService.pendingMigrationType` is set (an interrupted migration), re-presents `MigrationViewController` to resume it

**Info.plist**
- `NSPhotoLibraryUsageDescription` set (photo import + delete-after-import). There's also a stray `NSPhotoLibraryDescription` key — not a real Info.plist key, has no effect.
- Single-scene app (`UIApplicationSupportsMultipleScenes = false`), `SceneDelegate` as the scene delegate class.

---

## EntitlementService.swift
StoreKit 2 one-time "Unlock Pro" purchase and entitlement state. Entitlement syncs across devices via Apple ID.

**Types:** `enum EntitlementError: purchaseFailed, productUnavailable, purchasePending, verificationFailed` (LocalizedError)

**EntitlementService (singleton `.shared`, `@MainActor`, `ObservableObject`)**
- `static let unlockProductID = "nej.KoalaTVault.unlockpro"`
- `static let freeFileLimit = 100` — file cap for free tier
- `@Published private(set) isUnlocked: Bool` — main-actor source of truth
- `nonisolated isUnlockedSync: Bool` — lock-protected snapshot of `isUnlocked` for off-main callers (e.g. FileSystem's background import queue)
- `purchaseUnlock(confirmIn: UIScene? = nil) async throws` — uses `purchase(confirmIn:)` on iOS 17+ when a scene is given; `.userCancelled` returns silently, `.pending` throws `.purchasePending`
- `restorePurchases() async throws` — `AppStore.sync()` then refresh
- `refreshEntitlementStatus() async` — scans `Transaction.currentEntitlements` for the unlock product
- Private: `listenForTransactionUpdates()` — detached task on `Transaction.updates` (other devices, Ask-to-Buy), started in `init`; `init` also kicks off an initial refresh
- DEBUG: `static testForcedUnlocked: Bool?` — overrides `isUnlockedSync` only (not `isUnlocked`)

---

## PaywallViewController.swift
Modal "Unlock Pro" upsell screen.

**PaywallViewController: UIViewController, ErrorPresenting**
- `onUnlock: (() -> Void)?` — called after successful purchase/restore, before dismissal
- Layout: title, description ("Store more than \(freeFileLimit) files."), price (loaded via `Product.products` → `displayPrice`), Unlock button, Restore Purchases button, spinner, close (X) button top-right
- Unlock → `EntitlementService.shared.purchaseUnlock(confirmIn: view.window?.windowScene)`; Restore → `restorePurchases()`, shows "No previous purchase found to restore." if still locked
- Buttons disabled while a request is in flight
- Accessibility identifiers: `paywallUnlockButton`, `restoreButton`

---

## Cross-file dependency notes
- **CryptoService** is the crypto root; **FileSystem** and **AuthService** both depend on it; nothing depends on FileSystem/AuthService for crypto.
- **VaultItem/VaultDirectory** (defined in FileSystem.swift) are the shared currency passed through nearly every view controller.
- View-controller layer now fully accounted for: `FileBrowserViewController` (grid/home) → `FileViewerViewController` (media paging) → `FilePageViewController` (single page) → `TextEditorViewController`/`QLPreviewController`. Settings: `SecuritySettingsViewController` → `MigrationViewController` / `RecentlyDeletedViewController`. Onboarding/lock: `SetupWizardViewController`, `LockScreenViewController`.
- App entry points (AppDelegate/SceneDelegate/Info.plist) covered above.
- **Pro/monetization layer:** `EntitlementService` is standalone (StoreKit only, no app-service deps). `FileSystem` enforces the free-tier limit (`importItems`, `checkImportAllowed`) via `isUnlockedSync`. `PaywallViewController` is presented from `SecuritySettingsViewController` (Pro row) and from `ImportService` (when the file limit is hit, for both file and photo imports).

**Open observations (not yet fixed):**
1. FileSystem.swift — `restoreFromTrash` and `permanentlyDelete` look up the trash-map entry by `originalName`. If two trashed items share a name, the wrong entry can be used (restores to the wrong location/mapping, or leaves an orphaned map entry). Looking up by `item.diskURL.lastPathComponent` (the trash UUID key) would fix it.
2. FileSystem.swift — the `.fileLimitReached` message hardcodes "100" instead of using `EntitlementService.freeFileLimit`.
3. SecuritySettings.swift — the Pro row reads `isUnlockedSync` only at render time and doesn't observe `EntitlementService.$isUnlocked`, so a purchase synced from another device while the screen is open won't show until it reloads.
4. ImportService.swift — in `picker(_:didFinishPicking:)`, the paywall is presented right after `dismiss(animated: true)` starts on the photo picker. UIKit usually rejects a presentation while a dismissal is animating, so the paywall may never appear when the limit is hit. Presenting it from the dismiss completion handler would fix this.
5. ImportService.swift — the photo-import `checkImportAllowed` catch treats any error as the file limit; it could match `FileSystemError.fileLimitReached` specifically. (Harmless today, since that's the only error it throws.)
6. ImportService.swift — both branches of the authorization `guard` in `presentPhotoPicker` do the same thing (dead code).

**Issues found and fixed during initial review** (all resolved, listed for history — no outstanding action needed):
1. SetupWizard.swift — `createMasterKey` used a hardcoded literal instead of the typed password
2. SecuritySettings.swift — `promptChangePassword` used a hardcoded literal and called `createPassword` (new random key) instead of `changePassword(to:)` (re-wrap existing key)
3. SceneDelegate.swift — `setupMigrationResumeObserver()` was defined but never called
4. SecuritySettings.swift — "Re-encrypt Everything" ran a `.decrypt` migration instead of `.encrypt`
5. FileSystem.swift — `rename()` had no name-collision resolution for encrypted items
6. FileSystem.swift — `move()` had no name-collision resolution on original display name for encrypted items
7. CryptoService.swift — stray debug `print` in `wipeKey()`
