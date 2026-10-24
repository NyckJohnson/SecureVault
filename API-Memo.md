# SecureVault — API Surface Memo

Reference for public/internal-facing members across uploaded files (last updated 2026-10-03: CryptoService code review — SVC4 format, atomic file staging, new error cases, off-main password derivation, `verifyPassword` error mapping; closed observations \#14 and \#15, partly closed \#17, new open observations \#18–22; previously 2026-10-02: SceneDelegate code review — updated SceneDelegate entry, added UIViewController+Presentation, new open observations \#12–13; previously 2026-09-29: biometric unlock investigation — AuthService, SetupWizard, SceneDelegate, Info.plist, SecuritySettings, CryptoService notes). Private helpers omitted unless useful for context. Use this to scope future feature conversations without re-uploading everything.

## Project & Build Configuration

Source: project.pbxproj (uploaded 2026-10-02).

**Targets:** `KoalaTVault` (app), `KoalaTVaultTests` (unit), `KoalaTVaultUITests` (UI). Folders are Xcode filesystem-synchronized groups, so files are picked up automatically with no per-file membership list.

**Identity:** bundle ID `nej.KoalaTVault` (tests: `nej.KoalaTVaultTests` / `nej.KoalaTVaultUITests`), display name "Koala T Vault", version 1.2 (build 4), development region `en` (no other localizations; string catalogs enabled).

**Platform:**

- Deployment target **iOS 16.6** on all three targets. The project-level setting is 26.2 but the target-level values override it. Anything iOS 17+ (e.g. `purchase(confirmIn:)`) needs an `\\\#available` check.

- Built with Xcode 26.6 (`LastUpgradeCheck 2660`); app target created on Xcode 26.3.

- Devices: iPhone + iPad (`TARGETED\\\_DEVICE\\\_FAMILY = 1,2`). iPhone orientations: portrait + both landscapes. iPad: all four. `UIRequiresFullScreen = NO`.

- UIKit with a `LaunchScreen` storyboard; scene-based, single scene.

**Swift settings (app target):**

- `SWIFT\\\_VERSION = 5.0` (Swift 5 language mode, not Swift 6)

- `SWIFT\\\_APPROACHABLE\\\_CONCURRENCY = YES`

- `SWIFT\\\_DEFAULT\\\_ACTOR\\\_ISOLATION = MainActor`, so types are implicitly `@MainActor` unless marked `nonisolated`. This explains the `nonisolated` annotations on `CryptoService`, `CryptoError`, `FileKind`, and `MigrationType`. The test targets do not set default MainActor isolation.

- `SWIFT\\\_UPCOMING\\\_FEATURE\\\_MEMBER\\\_IMPORT\\\_VISIBILITY = YES` (each file must import the module that declares the members it uses)

- Debug defines `DEBUG`; Release uses whole-module optimization.

**Dependencies:** no Swift packages and no linked-framework entries, so the app uses system frameworks only (autolinked via `import`).

**Info.plist:** a manual `KoalaTVault/Info.plist` is merged with generated keys (`GENERATE\\\_INFOPLIST\\\_FILE = YES`). Keys set in build settings:

- `NSFaceIDUsageDescription` ("Unlocking with FaceID")

- `NSPhotoLibraryUsageDescription`

- `NSPhotoLibraryAddUsageDescription` (value contains literal quote characters)

- `ITSAppUsesNonExemptEncryption = NO`

- `CFBundleDisplayName`

**Capabilities / entitlements:** no entitlements file, Keychain sharing, app groups, or `UIBackgroundModes` configured. In-App Purchase works without an entitlement. `premiumTesting.storekit` lives in the `KoalaTVaultTests` folder for local StoreKit testing.

**Tests:** unit and UI test targets both depend on the app target. UI tests use the `--uitesting` launch argument (see AppDelegate).

## FileSystem.swift

Core file storage layer. Handles the vault directory tree, encryption-transparent CRUD, trash, and migration between encrypted/plaintext.

**Types**

- `struct VaultDirectory \\\\\\\{ name: String, diskURL: URL (internal), rootURL: URL (internal) \\\\\\\}` — `.root` static var (Documents dir, display name "KoalaTVault"). `rootURL` is carried down through every subdirectory so trash/limit logic knows which vault root an item belongs to.

- `struct VaultItem: Identifiable, Hashable, Sendable` — `id, name, isDirectory, dateModified, fileSize, deletedAt, diskURL (internal), rootURL (internal), isEncrypted (internal)`. Hash/equality by `id` only.

- `struct VaultMapping: Codable \\\\\\\{ originalName: String \\\\\\\}`

- `enum FileSystemError: LocalizedError \\\\\\\{ mappingUnreadable, fileLimitReached \\\\\\\}`

- `FileSystem.TrashEntry: Codable \\\\\\\{ originalDiskName, originalDirectoryURL, deletedAt, isEncrypted, originalName, rootURL \\\\\\\}` (DEBUG alias `TrashEntryForTesting`)

**FileSystem (singleton `.shared`)**

- `contents(of:) throws -\\\\\\\> \\\\\\\[VaultItem\\\\\\\]` — list directory; folders always first, then PreferencesService sort settings. Throws `.mappingUnreadable` if the `.vault\\\\\\\_map` exists but can't be read.

- `importItems(from:to:progress:) throws` — bulk import (files/folders), dedupes via SHA-256. **Free tier:** if `!EntitlementService.shared.isUnlockedSync`, counts existing files under `rootURL` + incoming files and throws `.fileLimitReached` if the total would exceed `EntitlementService.freeFileLimit` (all-or-nothing, checked before any copy)

- `checkImportAllowed(additionalCount:in:) throws` — same limit check; **caller must invoke before** `importFromCameraRoll`, which does not check itself

- `importFromCameraRoll(results:to:completion: (\\\\\\\[String\\\\\\\] succeededIdentifiers, Int failed))` — import from PHPickerResult; completion on main

- `open(\\\\\\\_:) throws -\\\\\\\> URL` — decrypts to temp file if needed, returns readable URL

- `write(data:to:) throws` — overwrite item contents (re-encrypts if needed)

- `prepareForExport(\\\\\\\_:progress:) throws -\\\\\\\> \\\\\\\[URL\\\\\\\]`

- `exportToCameraRoll(\\\\\\\_:completion:)`

- `createFolder(named:in:) throws -\\\\\\\> VaultDirectory`

- `move(\\\\\\\_:to:) throws`, `copy(\\\\\\\_:to:) throws`, `rename(\\\\\\\_:to:) throws`, `delete(\\\\\\\_:) throws` (→ trash) — move/copy/rename resolve name collisions against existing items in the target directory, including for encrypted items (compared by original display name via the mapping)

- **Trash is per vault root** (`.trash` folder + encrypted `.trash\\\\\\\_map` under `rootURL`):

  - `trashDirectory(for rootURL:) -\\\\\\\> VaultDirectory` (creates if missing)

  - `moveToTrash(\\\\\\\_:) throws`, `restoreFromTrash(\\\\\\\_:) throws`, `permanentlyDelete(\\\\\\\_:) throws`

  - `contentsOfTrash(for root:) throws -\\\\\\\> \\\\\\\[VaultItem\\\\\\\]` — newest first

  - `emptyTrash(for root:) throws` — deliberately best-effort; also sweeps files an unreadable map doesn't know about

  - `cleanupExpiredTrashItems(for root:)` — 30-day cutoff; never overwrites the map if it couldn't be read

- `filesToMigrate(toEncrypted:in:) throws -\\\\\\\> \\\\\\\[(item, directory)\\\\\\\]`

- `migrateVaultToEncrypted(in:progress:) throws`, `migrateFileToEncrypted(\\\\\\\_:in:) throws`

- `migrateVaultToDecrypted(in:progress:) throws`, `migrateFileToDecrypted(\\\\\\\_:in:) throws`

- `cleanupTempFiles()`

- DEBUG-only: `testForcedMigrationFailureFileName` (also `UITEST\\\\\\\_FAIL\\\\\\\_MIGRATION\\\\\\\_FILE` env var), `diagnoseDiskState()`, `testTrashMap(for:)`/`saveTestTrashMap(\\\\\\\_:for:)`, `testMapping(in:)`

- `Notification.Name.fileRestored`

Uses `CryptoService`, `PreferencesService`, `EntitlementService`. Encrypted files stored under random UUID names with a `.vault\\\\\\\_map` JSON mapping UUID→original name (itself encrypted if a key is loaded). Map loading: missing file = empty; unreadable file = throw `.mappingUnreadable` (never treated as empty, so a later save can't wipe real data). No key loaded → falls back to reading a legacy plaintext map.

## AuthService.swift

App lock/auth flow: password + biometrics, lock screen, privacy screen, lifecycle hooks.

**Types:** `enum AuthError: wrongPassword, keychainError`

**AuthService (singleton `.shared`)**

- `lockMode: LockMode` (proxies PreferencesService)

- `createPassword(\\\\\\\_:) throws` — stores the plaintext password in Keychain (`com.KoalaTVault.password`) **then** creates a new master key wrapped by it. **This is the only correct way to set a first password** — calling `CryptoService.createMasterKey` directly skips the Keychain copy and breaks biometric unlock.

- `changePassword(to:) throws` — stores new plaintext password, re-wraps the existing master key

- `verifyPassword(\\\\\\\_:) throws` — unwraps the master key; on success also re-stores the plaintext password (`try? storePlaintextPassword`) so the biometric path self-heals if the Keychain copy is stale/missing. Maps only `CryptoError.wrongPassword` to `AuthError.wrongPassword`; any other failure (`.noMasterKeyBlob`, `.decryptionFailed`, `.keychain(OSStatus)`) propagates as the `CryptoError`, so callers must not treat every throw as a wrong password. Runs a 600k-round PBKDF2 derivation, so call it off the main thread.

- `hasPassword() -\\\\\\\> Bool` (= master key blob exists), `removePassword()` (deletes Keychain password + master key blob)

- `finalizeMigration(type:targetLockMode:completedFully:)` — called after MigrationViewController completes

- `biometricsAvailable: Bool`, `biometricType: String` ("Face ID" / "Touch ID" / "Biometrics")

- `authenticateWithBiometrics(completion: (Bool, Error?) -\\\\\\\> Void)` — `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`, then reads the plaintext password from Keychain and calls `unwrapMasterKey(with:)`. Biometrics only gates access to the stored password; the Keychain item itself has no access control. Returns `AuthError.keychainError` if the password is missing or doesn't unwrap the key. Completion on main.

- `isLocked: Bool`, `hasAuthenticated: Bool` (public state vars)

- `static let vaultUnlockedNotification: Notification.Name`

- Scene lifecycle entry points:

  - `handleWillResignActive(in:)` — only shows the privacy screen (any interruption — Control Center, alerts, StoreKit sheet, the biometric prompt itself — fires this; must not lock)

  - `handleDidEnterBackground(in:)` — real lock: `isLocked = true`, wipes key, cleans temp files, clears thumbnail cache

  - `handleForeground(in:)` — `.none` → hides privacy screen; locked → `showLockScreen`; otherwise hides privacy screen

  - `handleInitialLaunch(in:)` — `.none` → posts unlocked notification; else locks and presents lock screen

- `didAuthenticate(in:)` — call after successful unlock; dismisses only the lock screen (so an in-progress MigrationViewController underneath survives), then hides privacy screen, reloads browser, posts notification

- Private: privacy screen is a tagged (999) `UIView` added directly to the window; `reloadFileBrowser` assumes root is `UINavigationController` → `FileBrowserViewController`

Depends on `CryptoService`, `PreferencesService`, `FileSystem.cleanupTempFiles()`, `ThumbnailService.clearCache()`, `LockScreenViewController`, `FileBrowserViewController`, `MigrationViewController`.

## CryptoService.swift

AES-GCM encryption, key derivation/wrapping, chunked streaming file format.

**Types:** `nonisolated enum CryptoError: Error, Equatable \{ noKeyLoaded, noMasterKeyBlob, wrongPassword, encryptionFailed, decryptionFailed, keychain(OSStatus) \}` (LocalizedError). `.noKeyLoaded` = no key in memory; `.noMasterKeyBlob` = no password set up (no blob in Keychain); `.decryptionFailed` also covers any CryptoKit error from the decrypt paths, which are wrapped so callers only ever see `CryptoError`.

**CryptoService (singleton `.shared`, `nonisolated`, `@unchecked Sendable`)**

- `isKeyLoaded: Bool`

- `wipeKey()` — clears in-memory symmetric key

- `createMasterKey(wrappedBy:) throws` — new random master key, wraps w/ password. **Low-level; app code should call `AuthService.createPassword` instead.**

- `unwrapMasterKey(with:) throws` — loads master key into memory from password. Throws `.noMasterKeyBlob` (no password set), `.wrongPassword` (GCM authentication failure), `.decryptionFailed` (corrupt/unsupported blob), or `.keychain(status)`

- `rewrapMasterKey(with:) throws` — requires key already in memory

- `hasMasterKeyBlob() throws -\> Bool`, `wipeMasterKeyBlob() throws` — throw `.keychain(OSStatus)` on Keychain errors (a missing item is not an error)

- `encrypt(data:) throws -\\\\\\\> Data`, `decrypt(data:) throws -\\\\\\\> Data` — single-shot, requires loaded key; bad ciphertext surfaces as `.decryptionFailed`

- `encryptFile(at:to:) throws`, `decryptFile(at:to:) throws` — chunked streaming (1MB chunks, custom "SVC4" format: 32-byte header of magic, chunkSize, totalSize and a random 16-byte fileID, then length-prefixed AES-GCM chunks; each chunk's AAD is the full header plus the chunk index, so reordering, truncation and header swaps fail authentication). **Atomic writes:** both functions write to a staging file (`.itemReplacementDirectory` on the destination's volume) and move it into place only after the size check passes (`replaceItemAt` if the destination exists, `moveItem` otherwise). A failure never touches an existing destination, and `destination == source` is safe. SVC3 files are rejected by `parseHeader` with no legacy reader (see open observation \#22)

- `streamInfo(for:) throws -\\\\\\\> (totalSize: Int, chunkSize: Int)` — header-only read

- `decryptChunk(at:from:chunkSize:totalSize:) throws -\\\\\\\> Data` — random access single-chunk decrypt (for streaming playback); validates the file header against the caller-supplied `chunkSize`/`totalSize` before doing any offset math

Password-derived wrapping key: PBKDF2-HMAC-SHA256, 600k iterations (~0.3–0.8 s per derivation, so run it off the main thread). The wrapped master key is a single Keychain generic-password item (service `com.KoalaTVault`, account `com.KoalaTVault.masterKeyBlob`, `kSecAttrAccessibleWhenUnlocked`, not ThisDeviceOnly so it survives backup/restore) with layout `version(1) | iterations(4, LE) | salt(32) | AES-GCM combined`; the first 37 bytes are authenticated as AAD. The iteration count is read from the blob on unwrap (bounded 100k–10M), so it can be raised later without breaking existing blobs. Writes use `SecItemUpdate` first, so a failed rewrap leaves the old blob intact. There is no separate salt item. **Keychain items survive app deletion** while UserDefaults does not — a reinstall reruns the setup wizard against a Keychain that may still hold the old blob/password.

## ErrorPresenting.swift

`protocol ErrorPresenting: UIViewController` with default implementations:

- `showError(\\\\\\\_ error: Error)`, `showError(\\\\\\\_ message: String)`, `showSuccess(\\\\\\\_ message: String)`

Conform any UIViewController to get one-line alert presentation.

## UIViewController+Presentation.swift

`extension UIViewController` — helpers for walking a presentation stack. Stateless, no dependencies beyond UIKit.

- `var presentationChain: \\\[UIViewController\\\]` — `self` followed by each controller presented on top of it (via `presentedViewController`), in order. Use to check whether a given controller type is anywhere in the stack (e.g. `root.presentationChain.contains \\\{ $0 is MigrationViewController \\\}`).

- `var topmostPresented: UIViewController` — last element of `presentationChain`; `self` if nothing is presented. Use as the presenter for new modals.

Used by `SceneDelegate.resumePendingMigrationIfNeeded()`. `AuthService` still hand-rolls the same loop (see open observation \#13).

## ExportService.swift

UI flow for exporting vault items out of the app.

**ExportService (singleton `.shared`)**

- `export(\\\\\\\_ item:from:sourceView:barButtonItem:)` — single item convenience

- `exportMultiple(\\\\\\\_:from:sourceView:barButtonItem:)` — action sheet: "Save to Files" / "Save to Camera Roll" (if media present) / Cancel

Delegates actual file work to `FileSystem.shared.prepareForExport` / `.exportToCameraRoll`.

## FileKind.swift

`nonisolated enum FileKind: image, video, audio, pdf, word, spreadsheet, presentation, archive, text, other`

- `init(extension: String)` — maps file extension (lowercased) to kind. Note: `.avi` deliberately unsupported (commented).

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

**Protocol:** `CameraRollDeleting \\\\\\\{ deleteAssets(withIdentifiers:) \\\\\\\}` **Struct:** `PhotoLibraryCameraRollDeleter: CameraRollDeleting`

Delegates actual copy/encrypt work to `FileSystem.shared.importItems` / `.importFromCameraRoll`.

## PreferencesService.swift

UserDefaults-backed settings.

**Types:**

- `enum LockMode: String \\\\\\\{ none, password, passwordAndBiometrics \\\\\\\}`

- `enum SortOption: String, CaseIterable \\\\\\\{ name, type, dateModified \\\\\\\}` — has `displayName`

- `enum SortDirection: String \\\\\\\{ ascending, descending \\\\\\\}`

**PreferencesService (singleton `.shared`)**

- `hasCompletedSetup: Bool`

- `lockMode: LockMode`

- `pendingMigrationType: MigrationViewController.MigrationType?`

- `pendingMigrationTargetLockMode: LockMode?` — only meaningful when pendingMigrationType == .encrypt

- `sortOption: SortOption`, `sortDirection: SortDirection`

## ThumbnailService.swift

Thumbnail generation/caching for files and folders (incl. encrypted files and video).

**ThumbnailService (singleton `.shared`)**

- `thumbnail(for:size:completion:) -\\\\\\\> QLThumbnailGenerator.Request?` — returns nil if served from cache/async path; caller can cancel via returned request

- `cancelThumbnail(for:)`

- `clearCache()`, `clearCache(for:)`

Internals: decrypts encrypted files off a semaphore-limited (2 concurrent) queue before generating QuickLook thumbnails; videos use `VaultResourceLoaderDelegate` + AVAssetImageGenerator; folder thumbnails compose a folder icon with an inset preview of first media child (`FileIconProvider` dependency).

## VaultResourceLoaderDelegate.swift

`final class VaultResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate`

- `init?(encryptedURL:fileExtension:)` — fails if `CryptoService.streamInfo` can't read header

- Implements `AVAssetResourceLoaderDelegate` methods to serve byte-range requests by decrypting only the needed chunks via `CryptoService.decryptChunk`, enabling scrubbing/streaming playback of encrypted video without full decryption.

## FileBrowser.swift

Main grid view — the app's home screen and every subdirectory. Handles browsing, select mode, bulk actions, drag & drop, context menus.

**FileBrowserViewController: UIViewController, ErrorPresenting**

- `init(directory: VaultDirectory)`

- `reloadAfterAuth()` — called by AuthService after unlock

- Sections wired via `UICollectionViewDiffableDataSource\\\\\\\<Int, VaultItem\\\\\\\>`

- Nav bar (normal mode): Settings (root only) / New Folder, New Document (.rtf), Import, Sort, Select

- Nav bar (select mode): Cancel / Delete, Move, Export, Copy (bulk)

- Tapping a directory pushes another `FileBrowserViewController`; tapping `.rtf` opens `TextEditorViewController`; tapping other files opens `FileViewerViewController` (paged, non-directory siblings only)

- Context menu per item: Export, Move (via `FolderPickerViewController`), Copy, Rename, Delete

- Conforms to `UICollectionViewDragDelegate`/`DropDelegate` (drag files onto folders to move) and `FolderPickerDelegate`

- Listens for `.fileRestored` notification to refresh

- DEBUG: logs temp-file stats and calls `FileSystem.shared.diagnoseDiskState()` in `viewDidAppear`

All file ops delegate to `FileSystem.shared`; import to `ImportService.shared`; export to `ExportService.shared`.

## FileViewer.swift

Full-screen paged media viewer (photos/video/other) with custom video transport controls.

**FileViewerViewController: UIViewController**

- `init(items: \\\\\\\[VaultItem\\\\\\\], startingAt: Int)`

- `player: AVPlayer?` — public var; set by `FilePageViewController` when a video page loads. `didSet` wires/removes the time observer.

- `updatePlayPauseButton(isPlaying:)` — called externally by `FilePageViewController`

- Hosts a `UIPageViewController` of `FilePageViewController` pages (swipe between items)

- Custom transport bar: play/pause, skip ±10s, scrubber w/ buffer indicator, spinner, auto-hide after 3s of playback

- Nav bar: close (X) and export (delegates to `ExportService.shared.export`)

- Conforms to `UIPageViewControllerDataSource`/`Delegate`

## FilePage.swift

One page inside `FileViewerViewController` — renders a single item (image/video/QuickLook/rtf).

**FilePageViewController: UIViewController**

- `init(item: VaultItem, viewer: FileViewerViewController)`

- Image: zoomable `UIScrollView` + double-tap-to-zoom

- Video: builds `AVPlayer`, streams via `VaultResourceLoaderDelegate` if encrypted (custom `vault-stream://` scheme), else opens decrypted temp file directly

- `.rtf`: presents `TextEditorViewController` full-screen instead of rendering inline

- Everything else: `QLPreviewController` (data source only, `numberOfPreviewItems`/`previewController(\\\\\\\_:previewItemAt:)`)

- Pauses `viewer.player` on `viewDidDisappear`

## FileCell.swift

`final class FileCell: UICollectionViewCell` — grid cell used by `FileBrowserViewController`.

- `static let reuseID`

- `configure(with item: VaultItem, gridMode: Bool)` — sets icon (via `FileIconProvider`), name, size, kicks off async thumbnail load via `ThumbnailService`

- `setSelected(\\\\\\\_:inSelectMode:)` — checkmark overlay + dim for select mode

- Cancels/clears thumbnail request in `prepareForReuse`

## FileIconProvider.swift

`enum FileIconProvider` — stateless icon/color lookup, no instances.

- `static let hasCustomFolderAsset: Bool`

- `static func folderImage(pointSize:) -\\\\\\\> UIImage?` — custom asset (`nej\\\\\\\_FolderIconB`) if bundled, else SF Symbol `folder.fill`

- `static func icon(for item: VaultItem) -\\\\\\\> UIImage?` — SF Symbol per `FileKind`

- `static func iconColor(for item: VaultItem) -\\\\\\\> UIColor` — tint per `FileKind` (folders yellow unless custom asset, which is untinted/`.clear`)

Used by `FileCell`, `ThumbnailService` (folder composition), `RecentlyDeletedViewController`, `FolderPickerViewController` (folder icon only, hardcoded).

## FolderPicker.swift

Modal folder-navigation picker used for Move operations.

**Protocol:** `FolderPickerDelegate \\\\\\\{ folderPicker(\\\\\\\_:didSelectFolder:) \\\\\\\}`

**FolderPickerViewController: UIViewController**

- `init(rootDirectory: VaultDirectory, currentDirectory: VaultDirectory)`

- `delegate: FolderPickerDelegate?`

- Table of subfolders only; drilling in pushes a new picker instance; "Move Here" confirms `currentDirectory`; "Cancel" dismisses

- Has leftover `print()` debug statements in init/viewDidLoad

## LockScreen.swift

Password/biometric entry screen shown by `AuthService`.

**LockScreenViewController: UIViewController**

- Password field + Unlock button; biometric button ("Use Face ID/Touch ID") shown only when `lockMode == .passwordAndBiometrics` and biometrics available

- Auto-attempts biometric unlock in `viewDidAppear` if lock mode requires it, else focuses the password field

- `isAuthenticating` guard prevents overlapping attempts; password verification runs on a background queue. `AuthError.wrongPassword` shows "Incorrect password"; any other error (`CryptoError.keychain`, `.noMasterKeyBlob`, `.decryptionFailed`) shows its `localizedDescription`

- On success calls `AuthService.shared.didAuthenticate(in:)`

- Maps `LAError` cases to user-facing messages (userCancel/userFallback/systemCancel are silent); non-`LAError` failures (e.g. `AuthError.keychainError`) show the generic "Biometric authentication failed"

- Accessibility identifiers: `passwordField`, `unlockButton` (UI test hooks)

- Conforms to `UITextFieldDelegate` (Return key submits)

## Migration.swift

Full-screen progress UI that drives bulk encrypt/decrypt of the vault, resumable across lock/background.

**MigrationViewController: UIViewController, ErrorPresenting**

- `nonisolated enum MigrationType: String \\\\\\\{ encrypt, decrypt \\\\\\\}`

- `init(type:directory: .root, targetLockMode:, onComplete: (\\\\\\\_ completedFully: Bool) -\\\\\\\> Void)`

- Persists `PreferencesService.pendingMigrationType`/`pendingMigrationTargetLockMode` at start, clears on full success — allows resuming after relaunch

- Pauses itself if the crypto key becomes unavailable mid-run (e.g. backgrounded/locked) and listens for `AuthService.vaultUnlockedNotification` to resume

- On per-file failure: collects failures, then shows Retry/Skip alert at the end rather than aborting

- Uses a `UIBackgroundTaskIdentifier` to get extra time when backgrounded

- Calls back via `onComplete(completedFully: Bool)` — caller (typically `SecuritySettingsViewController`) is responsible for calling `AuthService.shared.finalizeMigration(...)` in that callback

- DEBUG: `testFailedFileNames`, `testIsPaused`, `testStatusText`, `testTapRetry()`, `testTapSkip()`

Drives `FileSystem.shared.filesToMigrate/migrateFileToEncrypted/migrateFileToDecrypted`.

## ProgressOverlay.swift

Reusable blocking progress HUD.

**ProgressOverlay: UIView**

- `static func show(in viewController:, title:, cancellable: Bool = false, onCancel: (() -\\\\\\\> Void)? = nil) -\\\\\\\> ProgressOverlay` — adds itself to the VC's view and returns the instance

- `update(progress: Float, status: String)` — thread-safe (hops to main)

- `dismiss()` — fades out and removes itself (thread-safe)

Used by `ExportService` and `ImportService` during long-running file operations, and by `SecuritySettings` / `SetupWizard` while password derivation runs off the main thread.

## RecentlyDeleted.swift

Trash UI.

**RecentlyDeletedViewController: UIViewController, ErrorPresenting**

- Lists `FileSystem.shared.contentsOfTrash(for:)`; shows days-until-permanent-deletion (30-day window) per item

- Nav bar "Empty Trash" (disabled when empty) → confirms → `FileSystem.shared.emptyTrash(for:)`

- (Signatures updated to FileSystem's per-root trash API; this file hasn't been re-uploaded since, so details may be stale.)

- Row tap → action sheet: Restore (`restoreFromTrash`, posts `.fileRestored`) or Delete Permanently (`permanentlyDelete`)

## SecuritySettings.swift

Security/lock settings screen — lock mode picker, password change, trash entry point.

**SecuritySettingsViewController: UIViewController, ErrorPresenting**

- Sections (in order): Pro, Lock Mode, Password, Storage

  - **Pro** (no header): "Upgrade to Pro" (disclosure) → presents `PaywallViewController` as `.formSheet`, `onUnlock` reloads the table; shows "Pro Unlocked" + checkmark (non-selectable) once `EntitlementService.shared.isUnlockedSync`. Also observes `EntitlementService.$isUnlocked` (Combine, `dropFirst` + `removeDuplicates`) and reloads the Pro section when it changes. Accessibility identifier: `upgradeToProCell`

  - **Lock Mode**: No Lock / Password / Password+Biometric (dimmed and non-selectable if biometrics unavailable) / Re-encrypt Everything (only when lockMode != .none and unencrypted files exist)

  - **Password**: Change Password (hidden if lockMode == .none)

  - **Storage**: Recently Deleted

- Changing to `.none` confirms then runs a `.decrypt` migration; changing to a password mode when no password exists prompts for one then runs an `.encrypt` migration (`promptSetPassword(for:completion:)` runs `AuthService.createPassword` on a background queue under a `ProgressOverlay`; `completion()`, which starts the migration, fires on main afterwards; errors go through `showError(error)`); switching between the two password modes just sets `lockMode`

- `hasUnencryptedFiles` is computed on a background queue (`FileSystem.shared.filesToMigrate(toEncrypted: true, in: .root)`) at load and after each migration; "Re-encrypt Everything" runs an `.encrypt` migration

- `promptChangePassword`: validates empty/mismatch on main, then on a background queue under a `ProgressOverlay` runs `verifyPassword(current)` followed by `AuthService.shared.changePassword(to: new)` (re-wraps the existing master key; two derivations, ~0.6–1.6 s). `AuthError.wrongPassword` → "Current password is incorrect"; other errors show their own message

- DEBUG: `testSetHasUnencryptedFiles(\\\\\\\_:)`, `testTableView`

## SetupWizard.swift

First-run onboarding: choose lock mode, set password.

**SetupWizardViewController: UIViewController, ErrorPresenting**

- Three selectable option buttons (No Lock / Password / Password+Biometric, biometric disabled if unavailable) + Continue; default selection is No Lock

- Choosing a password mode prompts for password/confirmation, then calls `authService.createPassword(password)` (stores Keychain password + creates master key) on a background queue under a `ProgressOverlay`; `authService.lockMode` and `completeSetup()` run on main afterwards, and errors go through `showError(error)`

- On completion sets `PreferencesService.shared.hasCompletedSetup = true` and dismisses

- Accessibility identifier: `continueButton`

## TextEditor.swift

Simple RTF editor for `.rtf` vault items.

**TextEditorViewController: UIViewController, ErrorPresenting**

- `init(item: VaultItem)`

- Loads/saves via `FileSystem.shared.open`/`.write(data:to:)`, RTF-encoded `NSAttributedString`

- Formatting toolbar (bold/italic/underline, font size ±, alignment) built into `textView.inputAccessoryView`

- Autosaves 1s after each keystroke (debounced `Timer`) and again on `viewWillDisappear`/dismiss

## AppDelegate.swift / SceneDelegate.swift / Info.plist

App entry points and lifecycle wiring — thin, mostly delegates to the services above.

**AppDelegate**

- `didFinishLaunchingWithOptions`: when launched with `--uitesting` CLI arg, resets state for UI tests — clears setup flag, lock mode, password (`removePassword()`), trash, wipes crypto key, deletes everything in vault root, disables animations, and optionally seeds one file from `UITEST\\\\\\\_SEED\\\\\\\_FILE\\\\\\\_NAME` env var (plaintext, content `"uitest content"`). **Running UI tests on a physical device wipes its Keychain password.**

- Standard `UISceneSession` boilerplate (no custom logic)

**SceneDelegate**

- `window: UIWindow?`

- `scene(\\\\\\\_:willConnectTo:options:)` — calls `setupVaultUnlockObserver()` first, builds root nav (`FileBrowserViewController(directory: .root)` in a `UINavigationController`, large titles); presents `SetupWizardViewController` if `!hasCompletedSetup`, else calls `AuthService.shared.handleInitialLaunch(in:)` (lock screen is presented here, before the scene is active — see open observation \#9, to be fixed on the LockScreen side); also runs `FileSystem.shared.cleanupTempFiles()` on launch (doesn't need the key). Expired-trash cleanup no longer runs here — it needs the key to read the encrypted `.trash\\\\\\\_map`, so it moved to the vault-unlock handler

- `sceneDidBecomeActive` → `AuthService.shared.handleForeground(in:)`

- `sceneWillResignActive` → `AuthService.shared.handleWillResignActive(in:)` (privacy screen only)

- `sceneDidEnterBackground` → `AuthService.shared.handleDidEnterBackground(in:)` (actual lock)

- `sceneDidDisconnect` → removes the vault-unlock observer (token kept in a private `vaultUnlockObserver` property; `setupVaultUnlockObserver()` guards against double registration)

- `setupVaultUnlockObserver()` — observes `AuthService.vaultUnlockedNotification` (main queue) and calls `handleVaultUnlocked()`

- `handleVaultUnlocked()` — runs `FileSystem.shared.cleanupExpiredTrashItems(for: .root)` only when no migration is pending (avoids mutating `.trash`/`.trash\\\\\\\_map` while a migration rewrites the vault; currently runs on the main thread), then `resumePendingMigrationIfNeeded()`

- `resumePendingMigrationIfNeeded()` — if `PreferencesService.pendingMigrationType` is set (an interrupted migration) and no `MigrationViewController` is anywhere in the presentation stack (`presentationChain`), presents one from `topmostPresented` to resume it (`MigrationViewController` sets `.fullScreen` itself)

**Info.plist** (as uploaded 2026-09-29)

- Contains only `NSPhotoLibraryDescription` (misnamed — not a real key; value also has literal quote marks) and the scene manifest. No `NSPhotoLibraryUsageDescription` or `NSFaceIDUsageDescription` in the file — may be supplied via generated Info.plist build settings (`INFOPLIST\\\\\\\_KEY\\\\\\\_\\\\\\\*`); unverified.

- Single-scene app (`UIApplicationSupportsMultipleScenes = false`), `SceneDelegate` as the scene delegate class.

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

## PaywallViewController.swift

Modal "Unlock Pro" upsell screen.

**PaywallViewController: UIViewController, ErrorPresenting**

- `onUnlock: (() -\\\\\\\> Void)?` — called after successful purchase/restore, before dismissal

- Layout: title, description ("Store more than (freeFileLimit) files."), price (loaded via `Product.products` → `displayPrice`), Unlock button, Restore Purchases button, spinner, close (X) button top-right

- Unlock → `EntitlementService.shared.purchaseUnlock(confirmIn: view.window?.windowScene)`; Restore → `restorePurchases()`, shows "No previous purchase found to restore." if still locked

- Buttons disabled while a request is in flight

- Accessibility identifiers: `paywallUnlockButton`, `restoreButton`

## Cross-file dependency notes

- **CryptoService** is the crypto root; **FileSystem** and **AuthService** both depend on it; nothing depends on FileSystem/AuthService for crypto.

- **Password ownership:** `AuthService` owns the plaintext Keychain password used by biometric unlock; `CryptoService` owns the wrapped master key blob (salt and iteration count live inside it). The two must stay in sync — always go through `AuthService.createPassword` / `changePassword` / `removePassword`, never `CryptoService.createMasterKey` directly from UI code.

- **VaultItem/VaultDirectory** (defined in FileSystem.swift) are the shared currency passed through nearly every view controller.

- View-controller layer: `FileBrowserViewController` (grid/home) → `FileViewerViewController` (media paging) → `FilePageViewController` (single page) → `TextEditorViewController`/`QLPreviewController`. Settings: `SecuritySettingsViewController` → `MigrationViewController` / `RecentlyDeletedViewController`. Onboarding/lock: `SetupWizardViewController`, `LockScreenViewController`.

- **Pro/monetization layer:** `EntitlementService` is standalone (StoreKit only, no app-service deps). `FileSystem` enforces the free-tier limit (`importItems`, `checkImportAllowed`) via `isUnlockedSync`. `PaywallViewController` is presented from `SecuritySettingsViewController` (Pro row) and from `ImportService` (when the file limit is hit, for both file and photo imports).

**Open observations (not yet addressed):**

1. FileSystem.swift — `restoreFromTrash` and `permanentlyDelete` look up the trash-map entry by `originalName`. If two trashed items share a name, the wrong entry can be used (restores to the wrong location/mapping, or leaves an orphaned map entry). Looking up by `item.diskURL.lastPathComponent` (the trash UUID key) would fix it.

2. FileSystem.swift — the `.fileLimitReached` message hardcodes "100" instead of using `EntitlementService.freeFileLimit`.

3. ImportService.swift — in `picker(\\\\\\\_:didFinishPicking:)`, the paywall is presented right after `dismiss(animated: true)` starts on the photo picker. UIKit usually rejects a presentation while a dismissal is animating, so the paywall may never appear when the limit is hit. Presenting it from the dismiss completion handler would fix this.

4. ImportService.swift — the photo-import `checkImportAllowed` catch treats any error as the file limit; it could match `FileSystemError.fileLimitReached` specifically. (Harmless today, since that's the only error it throws.)

5. ImportService.swift — both branches of the authorization `guard` in `presentPhotoPicker` do the same thing (dead code).

6. Info.plist — `NSFaceIDUsageDescription` not in the file. Without it iOS blocks Face ID (Touch ID unaffected). Verify whether it's in build settings (`INFOPLIST\\\\\\\_KEY\\\\\\\_NSFaceIDUsageDescription`); add it if not.

7. Info.plist — `NSPhotoLibraryDescription` should be `NSPhotoLibraryUsageDescription`, and its value contains literal quote marks. Verify against build settings as above.

8. AuthService.swift — privacy screen can get stuck over the lock screen. After a background → foreground cycle with a failed/cancelled biometric prompt, `handleForeground` calls `showLockScreen`, which early-returns because the lock screen is already on top, so the privacy view (added directly to the window, above presented VCs) is never removed and the password field is hidden. Fix: in `showLockScreen`, call `hidePrivacyScreen` in the early-return path and in the `present` completion.

9. LockScreen.swift — on cold launch the lock screen is presented in `willConnectTo`, so the automatic biometric attempt in `viewDidAppear` can fire before the scene is active; iOS cancels it with `.systemCancel`, which is silenced, so nothing appears to happen. Fix: only auto-attempt when `windowScene?.activationState == .foregroundActive`, otherwise wait for `UIScene.didActivateNotification`.

10. Security (design) — the plaintext password used for biometric unlock is a Keychain item with no access control; `LAContext.evaluatePolicy` is the only gate and can be bypassed on a compromised device. Consider storing it (or the master key) with `SecAccessControl` `.biometryCurrentSet` + `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`.

11. AuthService.swift — `didAuthenticate(in:)` edge case when no lock screen is presented (`topVC === root`, e.g. a stray/duplicate call). `dismisser` falls back to `root`, and `root.dismiss(animated:)` with nothing presented is a no-op, so the completion handler (hide privacy screen, reload browser, post `vaultUnlockedNotification`) is not guaranteed to run. Fix: add `guard topVC !== root else \\\{ ... \\\}` after the `while` loop that performs those three steps directly and returns (extract into a private `finishUnlock(in:)` helper shared with the dismiss completion). Minor: the dismiss completion captures `self` strongly; use `\\\[weak self\\\]`.

12. AuthService.swift — `didAuthenticate(in:)` (and possibly other places that walk to the top presented controller, e.g. `showLockScreen`) hand-roll a `while let presented = topVC.presentedViewController` loop. `UIViewController+Presentation.swift` (added during the SceneDelegate review) provides `presentationChain: \\\[UIViewController\\\]` and `topmostPresented: UIViewController`; AuthService should adopt them (`root.topmostPresented`) instead of duplicating the loop.

13. AuthService.swift — `changePassword(to:)` stores the new plaintext password in Keychain *before* calling `CryptoService.rewrapMasterKey`. If the rewrap throws, the master-key blob is still wrapped by the old password but the Keychain copy is the new one, so biometric unlock fails (`.keychainError`) until the next successful manual unlock re-syncs it via `verifyPassword`. Fix: rewrap first, then store the plaintext password. (CryptoService side is now safe: `storeWrappedMasterKey` uses `SecItemUpdate`, so a failed rewrap leaves the old blob intact.)

14. **Resolved 2026-10-03.** `CryptoService.encryptFile`/`decryptFile` now write to a staging file in an `.itemReplacementDirectory` on the destination's volume and commit with `replaceItemAt` (or `moveItem`) only after the size check passes. A failure never truncates or deletes an existing destination, and source == destination is safe. No `FileSystem` changes needed.

15. **Resolved 2026-10-03.** `createPassword`, `verifyPassword`, and `changePassword` now run off the main thread under a `ProgressOverlay` in `SetupWizard.promptSetPassword`, `SecuritySettings.promptSetPassword(for:completion:)`, and `SecuritySettings.promptChangePassword` (`LockScreen` already did). Empty/mismatch validation runs on main before the background work.

16. Backup/restore design — master-key blob is \`kSecAttrAccessibleWhenUnlocked\` (not ThisDeviceOnly) so the vault survives iCloud/encrypted-local backup restore. Requirements: vault files must not be \`isExcludedFromBackup\` (verify in FileSystem.swift); AuthService plaintext password item should be ThisDeviceOnly (re-created on first manual unlock via \`verifyPassword\`). Unencrypted local backups omit the Keychain, so the vault won't restore from those.

17. **Partly resolved 2026-10-03.** `verifyPassword()` now maps only `CryptoError.wrongPassword` to `AuthError.wrongPassword` and rethrows everything else; `LockScreen` and `promptChangePassword` show the underlying error's message for non-wrong-password failures. Still to verify in AuthService.swift: `hasMasterKeyBlob()` and `wipeMasterKeyBlob()` now throw, so `hasPassword()` should be `(try? ...) ?? true` (fail toward the lock screen, never toward setup, which would overwrite the blob) and `removePassword()` should `try` and throw.

18. LockScreen.swift / AuthService.swift — `.noMasterKeyBlob` dead end. If a password lock mode is saved in preferences but the Keychain has no blob (reinstall wiping UserDefaults is the reverse case; a cleared Keychain is this one), the lock screen shows "No password has been set up." with no way forward. Decide whether it should offer a reset/recovery path (which would necessarily abandon any encrypted files).

19. VaultResourceLoaderDelegate.swift — in the `decryptChunk` loop, `guard !loadingRequest.isCancelled else \{ return \}` inside the `autoreleasepool` closure only exits the closure, not the `for` loop. Harmless (remaining iterations return immediately), but not an early exit. Optional: set a `cancelled` flag in the closure and `break` after the pool.

20. FileSystem.swift — `isDuplicate` (encrypted branch) decrypts the whole existing file to hash it whenever a name matches. Optional speedup: compare `CryptoService.streamInfo(for:).totalSize` with the source file size first and return `false` on mismatch. All current failure paths return `false` ("not a duplicate"), which fails safe to a redundant copy, never dropped data.
