# Survey: services

STATUS: done
PASS: services

Files: `Model/AuthService.swift`, `Model/EntitlementService.swift`, `Model/ImportService.swift`,
`Model/ExportService.swift`, `Model/ThumbnailService.swift`, plus `.storekit`/Info.plist/pbxproj for confirmation.

## 0. Cross-cutting

- All five are singletons (`static let shared`; `ImportService.init` internal): AuthService.swift:20,
  EntitlementService.swift:26, ImportService.swift:12, ExportService.swift:44, ThumbnailService.swift:21.
- Only network use: StoreKit. **No `.entitlements` file.** The only `.storekit` is `KoalaTVaultTests/premiumTesting.storekit`
  (`nej.KoalaTVault.unlockpro`, NonConsumable, :28-30). Info.plist is partial, merged with build settings
  (`GENERATE_INFOPLIST_FILE=YES` + `INFOPLIST_FILE=KoalaTVault/Info.plist`, pbxproj:413-420).
- Obs #6/#7: Info.plist has typo `NSFaceIDUsageDscription` (:7) and `NSPhotoLibraryUsageDescription` with literal quotes;
  build settings supply `INFOPLIST_KEY_NSFaceIDUsageDescription`, `...PhotoLibraryUsageDescription`,
  `...PhotoLibraryAddUsageDescription` (pbxproj:418-420; one configuration checked). Likely resolved; plist typo is a
  harmless leftover. Add description also has literal quotes (pbxproj:419).
- **UI inside services** (must move to screens): AuthService presents the privacy screen (tag 999), the lock screen,
  dismisses controllers, calls `FileBrowserViewController.reloadAfterAuth()`, references
  `MigrationViewController.MigrationType`. ImportService presents an action sheet, document pickers, PHPicker, the paywall,
  alerts, `ProgressOverlay`. ExportService presents an action sheet, document picker, alerts, `ProgressOverlay`.
  EntitlementService: only a `UIScene` parameter. ThumbnailService: no UI (`UIScreen.main.scale`, `UIGraphicsImageRenderer`).

## 1. AuthService (not actor-isolated; mixes `nonisolated`)

- Public: `lockMode` (pass-through to `PreferencesService`), `createPassword`, `changePassword(to:)`, `verifyPassword`,
  `hasPassword()`, `removePassword()`, `enableBiometrics()`, `removeBiometricSecret()`, `biometricsAvailable`,
  `biometricType`, `authenticateWithBiometrics(completion:)`, `finalizeMigration(type:targetLockMode:completedFully:)`,
  `isLocked`, `hasAuthenticated` (plain vars, main), `vaultUnlockedNotification`, scene hooks
  `handleWillResignActive`, `handleDidEnterBackground`, `handleForeground`, `handleInitialLaunch`, `didAuthenticate(in:)`.
- Threading: password methods `nonisolated`, called on `DispatchQueue.global(.userInitiated)` under an overlay.
  `authenticateWithBiometrics` reads the Keychain on a global queue, calls back on main.
- State: `isLocked`, `hasAuthenticated`, logger, constants (service "com.KoalaTVault", account
  "com.KoalaTVault.biometricMasterKey", legacy account "com.KoalaTVault.password"). Key in `CryptoService`; blob in Keychain.

### Key-lifecycle transitions

- **createPassword** (:38) → `CryptoService.createMasterKey`: `hasMasterKeyBlob` check → random 256-bit key →
  `storeWrappedMasterKey` (update/add) → set in-memory key. Blob exists → `CryptoError.masterKeyAlreadyExists` (not
  mapped to `AuthError`). Store failure: no blob, no key. Never replaces a blob (except the check/store race). Key stays
  loaded; `lockMode` untouched (caller sets it and calls `enableBiometrics`).
- **verifyPassword** (:48) → `unwrapMasterKey` loads the key (replacing any). `wrongPassword` → `AuthError.wrongPassword`;
  `noMasterKeyBlob`, `decryptionFailed`, `keychain(status)` rethrown raw. Success deletes the legacy plaintext-password
  item (account only, errors ignored). No lockout/counter.
- **changePassword(to:)** (:43) → `rewrapMasterKey` from the in-memory key. Doesn't verify the old password (Settings
  calls `verifyPassword(current)` first, SecuritySettings.swift:309-310). No key → `noKeyLoaded`. Failure leaves the old
  blob; same master key. Biometric item (raw key) unaffected. **Obs #13 STALE**: no plaintext password is stored any more.
- **removePassword** (:61): `wipeMasterKeyBlob()` throws on anything but success/not-found **before**
  `removeBiometricSecret` and the legacy delete. Failure leaves blob + biometric item. Doesn't wipe the in-memory key or
  touch `lockMode`. Callers: `finalizeMigration(.decrypt)`, DEBUG `--uitesting` reset (AppDelegate.swift:21, `try?`).
- **enableBiometrics** (:71): `exportMasterKeyData()` (`noKeyLoaded` if none) → copy zeroed by `memset_s` in `defer` →
  `storeBiometricMasterKey`: build `SecAccessControl` → `SecItemDelete` old → `SecItemAdd`.
  - **Obs #10 RESOLVED differently**: the item holds the **raw master key**: genericPassword, service "com.KoalaTVault",
    account "com.KoalaTVault.biometricMasterKey", 32 bytes, access control
    `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`, no access group, not synchronizable, no
    `kSecUseDataProtectionKeychain`.
  - Delete-then-add not atomic: a failed add leaves no biometric item (blob and key untouched; next password login
    re-creates it). Failures → `AuthError.keychainError`.
  - `.biometryCurrentSet`: enrolment changes invalidate the item; LockScreen re-saves after each password login in
    biometric mode (`try?`, LockScreen.swift:150).
- **removeBiometricSecret** (:78): `SecItemDelete`, errors ignored.
- **authenticateWithBiometrics** (:172): fresh `LAContext`, no `evaluatePolicy`; `SecItemCopyMatching` is the only gate
  (triggers the prompt). Success → `CryptoService.loadMasterKey(from:)` (replaces key, checks length; Data not zeroed).
  All failures → `AuthError.keychainError`, except `errSecUserCanceled` → nil. So LockScreen's LAError branches
  (lockout etc.) **never run**: dead code, generic message only. Doesn't check `lockMode`.
- **wipeKey on background** (`handleDidEnterBackground`, :230): guard `hasAuthenticated && lockMode != .none` →
  `isLocked = true`, `CryptoService.wipeKey()`, `FileSystem.cleanupTempFiles()`, `ThumbnailService.clearCache()`. Lock
  screen shown by `handleForeground`. Blob/biometric item remain. Pauses migration (Migration.swift:126); in-flight file
  ops finish (key copied at start). `handleWillResignActive` only adds the privacy view.
- **finalizeMigration** (:127): `guard completedFully` else nothing. `.encrypt`: `lockMode = target` if non-nil.
  `.decrypt`: (1) `lockMode = .none` → (2) `removePassword()` (errors only logged) → (3) `wipeKey()`; target unused. If
  `removePassword` fails or the app is killed between 1 and 2: `lockMode == .none`, key wiped, blob + biometric item
  remain, files decrypted, `hasPassword()` true (orphan-blob state). **Trash not migrated → trashed encrypted items left
  under a key whose blob is deleted (confirmed stranded-files path).** Callers: SceneDelegate.swift:84,
  SecuritySettings.swift:193, 210, 225.
- **hasPassword** (:57): `(try? hasMasterKeyBlob()) ?? true` (fails toward "has a password"). **Obs #17 confirmed
  resolved.**
- **noMasterKeyBlob (obs #18) CONFIRMED**: rethrown, shown as `localizedDescription` (LockScreen.swift:~158), no reset
  path. Biometric unlock still works if the biometric item exists.
- **Reverse case** (UserDefaults lost, Keychain blob survives, e.g. reinstall — guess): wizard runs; choosing a password
  → `masterKeyAlreadyExists` shown raw, stuck in the wizard (no data lost); "none" works. Later Settings → password sees
  `hasPassword()==true`, skips `createPassword` and migration, flips `lockMode` with no key and plaintext files (inferred).

### Can any path lose or replace the key, or strand files?

- Replace: none (only the check/store race).
- Key loss: only by blob deletion in `removePassword` (after a full decrypt migration, or the DEBUG reset).
- Stranded files: (1) trash after a decrypt migration; (2) `completedFully` computation lives in Migration.swift (not
  verified here); (3) orphan-blob state after a partial `removePassword` leaves files plaintext (safe).
- Setup wizard (SetupWizard.swift:218-232): `enableBiometrics` failure after `createPassword` → blob + loaded key,
  wizard shows an error, `lockMode` not set; retry → `masterKeyAlreadyExists`; "none" → orphan blob.
- `hasAuthenticated` after setup (suspected): set only in `didAuthenticate` and `handleForeground` in `.none` (:240). If
  the scene hook runs at cold launch (guess: yes) it's already true; journey test to confirm the vault locks on background
  after setting a password.
- First lock enable from Settings (SecuritySettings.swift:216-229): `createPassword` → `try? enableBiometrics()` →
  `lockMode = mode` → encrypt migration; a kill midway resumes via `pendingMigrationType` after unlock. Key safe.
- Lock-mode switch with a blob (:229-241): `enableBiometrics()` (shown on failure) or `removeBiometricSecret()`, then
  `lockMode`.

### Privacy and lock screens (UI in the service)

- `handleForeground` (:238): `.none` → `hasAuthenticated = true`, hide privacy; `isLocked` → show lock screen; else hide privacy.
- `handleInitialLaunch` (:251): `.none` → post `vaultUnlockedNotification`; else `isLocked = true`, show lock screen.
- `showLockScreen` (:311): presents on topmost, full-screen, unanimated; already on top → hide privacy, return
  (:319-321). **Obs #8 FIXED.** LockScreen waits for `.foregroundActive` (**obs #9 FIXED**).
- `didAuthenticate` (:264): `isLocked = false`, `hasAuthenticated = true`; hand-rolled topmost loop (:269); dismiss via
  `topVC.presentingViewController ?? root` (:274); then hide privacy, `reloadFileBrowser` (assumes nav root with browser
  first), post notification. **Obs #11 confirmed** structurally (nothing presented → `root.dismiss` no-op; completion
  may not run — unverified); strong `self`. **Obs #12 confirmed** (loops :269, :315).
- `SceneDelegate.handleVaultUnlocked` is the only observer.

## 2. EntitlementService (@MainActor, ObservableObject)

- `unlockProductID = "nej.KoalaTVault.unlockpro"`, `freeFileLimit = 100` (`nonisolated static`).
- `@Published private(set) isUnlocked`; `didSet` → `updateSyncCache` writes static `OSAllocatedUnfairLock<Bool>`
  `syncCache` and `UserDefaults["entitlement.isUnlocked"]`.
- `isUnlockedSync` `nonisolated static`, thread-safe. DEBUG `testForcedUnlocked: Bool?` overrides.
- `init` seeds `syncCache` (not `isUnlocked`) from UserDefaults; `isUnlocked` starts false until the refresh.
- Startup: `init` starts the transaction listener and `Task { refreshEntitlementStatus }`; AppDelegate touches `shared`.
- `purchaseUnlock(confirmIn:)`: no product → `productUnavailable`; iOS 17+ with scene → `purchase(confirmIn:)`, else
  `purchase()`. `.success` → `checkVerified` (unverified → `verificationFailed`, not finished) → `finish()` →
  `isUnlocked = true`. `.userCancelled` silent. `.pending` → `purchasePending`. Default → `purchaseFailed`.
- `restorePurchases()`: `AppStore.sync()` → refresh.
- `refreshEntitlementStatus()`: first verified `currentEntitlements` entry for the product → true; none → false
  (revocation works).
- Listener: `Task.detached` over `Transaction.updates`, weak self; verified → `finish()` → refresh; unverified skipped
  and unfinished.
- Callers read `isUnlockedSync` off main in `FileSystem.importItems` (:135) and `checkImportAllowed` (:238).

## 3. ImportService (NSObject, no isolation; picker delegates)

- State: injectable `cameraRollDeleter: CameraRollDeleting` (default `PhotoLibraryCameraRollDeleter`), weak
  `presentingViewController`, `targetDirectory`, `completion`. Singleton with per-call state (concurrent imports would clash; guess).
- `promptImport(into:from:barButtonItem:completion:)`: action sheet "Choose Files", "Choose Folder", "Choose Photos", "Cancel".

### Files and Folder

- `UIDocumentPickerViewController(forOpeningContentTypes: [.item]` / `[.folder])`, multiple selection.
- `performImport(from:)` (:90): overlay "Importing..." → `FileSystem.importItems` on a global queue → progress throttled
  to 0.1s → dismiss overlay → `completion?()` → errors: `fileLimitReached` → paywall `.formSheet`; other →
  `(viewController as? ErrorPresenting)?.showError`.
- Limit inside `importItems`, **before any file**: `existing + total > 100` → `fileLimitReached`, nothing imported.
  `total` counts files recursively; duplicates count.
- Mid-import failure: earlier files stay (no rollback); completion still runs.
- Obs #3: Photos path STALE (paywall presented in the dismiss completion, :143-147). Files path: paywall right after
  `overlay.dismiss()` (:109-117); picker already gone, probably fine (unverified).

### Photos

- `presentPhotoPicker`: `requestAuthorization(.readWrite)`, then always presents (**obs #5 confirmed**, identical
  branches :70-75). Denied/limited → nil `assetIdentifier` → nothing offered for deletion.
- `PHPickerConfiguration(photoLibrary: .shared())`, `selectionLimit = 0`, images + videos.
- `picker(_:didFinishPicking:)` (:135):
  - **Cancel (empty results) returns without dismissing the picker** (suspected; PHPicker doesn't self-dismiss).
  - `checkImportAllowed(additionalCount: results.count, in:)`: `fileLimitReached` → dismiss → paywall in completion.
    Other errors → `showError` with the picker still up. **Obs #4 STALE** for the limit case.
  - Success: dismiss → overlay "Importing Photos..." (never updated) → `FileSystem.importFromCameraRoll` → completion on
    main `(succeededIdentifiers, failed)`. `failed > 0` → alert "N imported, M failed", OK → delete offer; else delete
    offer immediately.
- `confirmDeleteFromCameraRoll` (misnamed): no in-app confirmation; `cameraRollDeleter.deleteAssets` directly; iOS
  system dialog is the only confirmation. `PhotoLibraryCameraRollDeleter`: fetch, bail if empty, `performChanges` with no
  error handling. Skipped duplicates are offered for deletion too.

## 4. ExportService (non-isolated)

- `export(_:from:sourceView:barButtonItem:)` → `exportMultiple`.
- Action sheet: "Save to Files" (always), "Save to Camera Roll" (only if some item is image/video), "Cancel".
- Save to Files: overlay "Exporting..." (not cancellable) → background `FileSystem.prepareForExport` (encrypted →
  `tmp/<UUID>/<name>`; plaintext → `item.diskURL`) → `UIDocumentPickerViewController(forExporting:asCopy: true)`.
  `ExportCleanupDelegate` (associated object) removes temp URLs on pick/cancel; leaves empty `tmp/<UUID>/` dirs. Errors →
  "Error" alert. **`prepareForExport` failure midway leaves earlier decrypted files in tmp** until the background wipe or
  next launch. Backgrounding wipes temp files still awaiting the picker (effect unverified).
- Save to Camera Roll: `Task { FileSystem.exportToCameraRoll(items) }`, no overlay; non-media silently excluded;
  `.addOnly` must be `.authorized`, else "0 saved, N failed" with no Settings pointer. Per-item temp removed by `defer`.
- Folders in a selection may go through `decryptFile` on a directory (unverified; no filter seen).

## 5. ThumbnailService (`nonisolated final class`, Sendable)

- Cache: in-memory `NSCache<NSString, UIImage>` keyed by item UUID string; no limit, **no disk cache**. `clearCache()`
  (only global call on background, AuthService.swift:235), `clearCache(for:)`.
- Concurrency: concurrent queue, `DispatchSemaphore(2)` for encrypted image/doc decrypts, locked `cancelledIDs`.
- `thumbnail(for:size:completion:)` `@MainActor`: clears the cancel flag, returns cached image, reads scale on main.
  Folder → async render. File → returns `QLThumbnailGenerator.Request?` (unencrypted path only).
- Unencrypted: `QLThumbnailGenerator.generateBestRepresentation` on `diskURL`.
- Encrypted video: `VaultResourceLoaderDelegate` (`vault-stream`) + `AVAssetImageGenerator` at ~min(5s, duration/2);
  nothing on disk; no semaphore.
- Encrypted non-video: `FileSystem.open` to temp → QuickLook → temp removed in the callback. Plaintext in tmp during
  generation. Decrypt/key-wiped failure → nil.
- Cancellation: `cancelThumbnail(for:)` only marks; checked once before decrypt; doesn't stop QL/video; completion not
  called if cancelled; flags linger.
- Folder thumbnail: first media item composed onto the folder icon, cached under the folder id (cancel uses the media
  id, so folder cancel does nothing); `contents(of:)` each time.
- Race: in-flight generations can repopulate the cache after `clearCache()` on background (memory only).
- Note: since `VaultItem.id` is regenerated per listing (survey-data §1), the cache key changes on every reload.

## 6. Journeys (service side)

- **J1**: `.none` → `lockMode = .none`, `hasCompletedSetup = true`. Password: `createPassword` (+ biometrics) in the
  background, `lockMode` on success. Partial failure → `masterKeyAlreadyExists` on retry. No migration.
- **J2**: password → `verifyPassword` → biometric refresh (`try?`) → `didAuthenticate`; "Incorrect password", no lockout.
  `noMasterKeyBlob` dead end. Biometric: Keychain-gated read, generic failure message. Background wipes the key; lock
  screen on foreground.
- **J4**: Files/Folders limit checked up front (all or nothing); Photos limit in the picker delegate; trash/hidden files
  not counted.
- **J7**: §4.
- **J8**: encrypt: `createPassword`, biometrics, `lockMode` first, migration, `finalizeMigration` re-sets the target.
  Decrypt: migration, then on full completion `lockMode = .none`, blob removed, key wiped. Resume via
  `pendingMigrationType` after unlock. Background wipe pauses migration.
- **J9**: product id confirmed in the test `.storekit` (NonConsumable); limit 100.

## 7. API-Memo observations

- #3 partly stale · #4 stale · #5 confirmed · #10 resolved (raw key, `.biometryCurrentSet`, ThisDeviceOnly) · #11
  confirmed · #12 confirmed · #13 stale · #16 confirmed (biometric item ThisDeviceOnly; blob `WhenUnlocked`) · #17
  confirmed resolved · #18 confirmed.

## Suspected issues

- AuthService.swift:61-65 — `removePassword` throws after the blob delete fails, before removing the biometric item →
  orphan-blob state with `lockMode == .none`.
- AuthService.swift:132-147 + SecuritySettings.swift:216 — after the orphan-blob state, enabling a lock skips
  `createPassword` and migration: `lockMode` set, no key, plaintext files (inferred).
- AuthService.swift:127-147 — decrypt migration skips the trash: trashed encrypted items under a deleted key.
- SetupWizard.swift:218-232 + AuthService.swift:38 — partial failure leaves blob + key; retry `masterKeyAlreadyExists`.
- AuthService.swift:230-236 — background lock guarded by `hasAuthenticated` (setup paths don't set it; unverified).
- AuthService.swift:172-207 + LockScreen `handleBiometricFailure` — LAError branches unreachable; generic error only.
- AuthService.swift:99-113 — biometric delete-then-add not atomic.
- AuthService.swift:264-283 — obs #11; strong `self`.
- AuthService.swift:222-236, :251-261 — `isLocked`/`hasAuthenticated` plain vars on a non-isolated class.
- ImportService.swift:135-138 — PHPicker Cancel doesn't dismiss.
- ImportService.swift:149-151 — non-limit error alert with the picker still up.
- ImportService.swift:70-75 — dead conditional (obs #5).
- ImportService.swift:155-172 — Photos overlay never updated; skipped duplicates offered for deletion; no in-app delete
  confirmation.
- ImportService.swift:14-18 — singleton with per-call mutable state.
- ExportService.swift:73-90 + FileSystem.swift:370-381 — partial `prepareForExport` failure leaves plaintext in tmp.
- ExportService.swift:28-33 — empty `tmp/<UUID>/` dirs left.
- ExportService.swift:97-104 — no progress for camera-roll export; denial message unhelpful.
- EntitlementService.swift:62-70 — paid state seeded from UserDefaults before StoreKit (spoofable window);
  `isUnlocked`/`isUnlockedSync` disagree until refresh.
- EntitlementService.swift:110-119 — slow/failed `currentEntitlements` leaves the cached value.
- EntitlementService.swift:126-128 — unverified transactions never finished; listener finishes before refresh.
- ThumbnailService.swift:65-67, :232 — cancellation weak; folder cancel no-op; lingering flags.
- ThumbnailService.swift:203-208 — cache repopulated after background wipe.
- Info.plist:7 — typo `NSFaceIDUsageDscription` (harmless if the build setting covers all configurations).

NOT READ: Migration.swift, PaywallViewController, LockScreen (beyond cited lines), FileSystem (beyond cited functions).
Opened for cited lines only: AppDelegate, SceneDelegate, SetupWizard, SecuritySettings, LockScreen, Migration,
CryptoService, FileSystem, `project.pbxproj`.
