# Survey: screens (setup, lock, settings, migration, paywall, startup)

STATUS: done
PASS: screens

Files: `AppDelegate.swift`, `SceneDelegate.swift`, `View/LockScreen.swift`, `View/SetupWizard.swift`,
`View/SecuritySettings.swift`, `View/Migration.swift`, `View/PaywallViewController.swift`. AuthService, FileSystem and
PreferencesService read only at the lifecycle/migration methods named. AuthService key/Keychain internals are left to the
services pass.

## API-Memo is stale on several points

- SceneDelegate no longer runs `cleanupExpiredTrashItems` or `resumePendingMigrationIfNeeded`, and doesn't use
  `presentationChain`/`topmostPresented`; it has its own `handleVaultUnlocked` (SceneDelegate.swift:73-87).
- AuthService now has `enableBiometrics()` (exports the master key; AuthService.swift:71) and `storeBiometricMasterKey`.
  The memo's plaintext-password-in-Keychain design is gone.
- Services pass to check: LockScreen comment (LockScreen.swift:145-148) mentions a `.biometryCurrentSet` item; memo obs
  #10 says there is no access control.

## Startup

- AppDelegate.swift:13-55, cold launch:
  - `--uitesting` launch arg (DEBUG only) resets state: `hasCompletedSetup=false`, `lockMode=.none`, `removePassword()`,
    empties trash, wipes key, deletes everything in the vault root. Then seeds `UITEST_SEED_FILE_NAME` (one file),
    `UITEST_SEED_FILE_COUNT` (N files `uitest-seed-i.txt`), `UITEST_PASSWORD` (creates password, `lockMode=.password`,
    `hasAuthenticated=true`, `hasCompletedSetup=true`).
  - The stack rules name the clean-state option `-uiTesting`; this app uses `--uitesting`, and **existing UI tests pass
    it** (`VaultUITestCase.swift:25`, `AdditionalUITests.swift:204`).
  - A `Task { @MainActor }` warms `EntitlementService.shared`. Standard "Default Configuration" scene.
- SceneDelegate `willConnectTo` (:16-39):
  1. Registers the vault-unlocked observer.
  2. Always builds `UINavigationController(FileBrowserViewController(.root))` (large titles) as root.
  3. `!hasCompletedSetup` → present `SetupWizardViewController` full-screen, unanimated; `handleInitialLaunch` not called.
  4. Else `AuthService.handleInitialLaunch(window)` (AuthService.swift:251): `.none` posts `vaultUnlockedNotification`;
     password modes set `isLocked = true` and present `LockScreenViewController` full-screen, unanimated.
  5. Then `cleanupTempFiles()` and `sweepOrphanedEncryptedFiles(.root)`. The sweep bails without deleting when the key
     isn't loaded (FileSystem.swift:737-739).
- State by case:
  - No setup: wizard.
  - Setup done, `.none`: browser + unlock handler (resumes any pending migration).
  - Password/biometric: lock screen; `didAuthenticate` dismisses it, hides privacy view, reloads browser, posts notification.
  - Migration interrupted: `PreferencesService.pendingMigrationType` set (+ `pendingMigrationTargetLockMode`). After
    unlock, `handleVaultUnlocked` presents `MigrationViewController` from the topmost VC unless one is in the stack;
    completion calls `finalizeMigration`.
- `sceneDidBecomeActive` → `handleForeground`: `.none` sets `hasAuthenticated = true` and hides privacy screen (that's
  how it becomes true on a fresh install); `isLocked` → show lock screen; else hide privacy screen.
- `sceneWillResignActive` → `handleWillResignActive`: privacy view (tag 999, window subview) only if
  `hasAuthenticated && lockMode != .none`. Does not lock.
- `sceneDidEnterBackground` → `handleDidEnterBackground`, same guard: `isLocked = true`, `wipeKey()`,
  `cleanupTempFiles()`, `ThumbnailService.clearCache()`.
- `sceneDidDisconnect` removes the observer. Single scene; root assumed a nav controller.

## LockScreenViewController (`View/LockScreen.swift`, UIKit)

- Reached: cold launch or foreground when locked; presented by AuthService on the topmost VC, full-screen, unanimated.
- Shows: lock icon, "KoalaTVault Locked", secure field "Enter password", Unlock, red error label (hidden), "Use Face
  ID/Touch ID" (only if `lockMode == .passwordAndBiometrics && biometricsAvailable`, evaluated once in `setupUI`).
- `viewDidAppear` (:31-44): non-biometric → focus field; biometric → `attemptUnlock()` if scene `.foregroundActive`,
  else waits for `UIScene.didActivateNotification`. Field never auto-focused in biometric mode;
  `biometricsAvailable` not checked before the auto-attempt.
- Unlock/Return with non-empty password → `attemptUnlock(with:)`; empty ignored. Biometric button → `attemptUnlock()`.
- Password path: `isAuthenticating`; global queue `verifyPassword`; biometric mode then `try? enableBiometrics()`
  (refreshes the biometric copy); success → `didAuthenticate(in: view.window)`. `AuthError.wrongPassword` → "Incorrect
  password"; other → `localizedDescription`. `showError` clears field, shows label (never hidden again). No lockout,
  throttle, wipe; no spinner during 600k-round PBKDF2; button stays enabled.
- Biometric path: `authenticateWithBiometrics`, main completion. Success → `didAuthenticate`; nil error,
  `.userCancel`, `.userFallback`, `.systemCancel` silent; `.biometryNotEnrolled`, `.biometryLockout`, `.passcodeNotSet`
  own messages; other errors → "Biometric authentication failed".
- Identifiers: `passwordField`, `unlockButton`.
- View model: unlock state machine, LAError mapping, post-login biometric refresh.
- AuthService members: `lockMode`, `biometricType`, `biometricsAvailable`, `verifyPassword`, `enableBiometrics`,
  `authenticateWithBiometrics`, `didAuthenticate`.

## SetupWizardViewController (`View/SetupWizard.swift`, UIKit)

- Reached only when `!hasCompletedSetup`; full-screen over the nav.
- Shows "Welcome to Koala T Vault", subtitle, three cards (No Lock, Password, "Password + <biometricType>"; biometric
  card `isEnabled = biometricsAvailable`, no visual cue), blue Continue. "No Lock" default; selected card blue border.
- Continue: None → `lockMode = .none`, `completeSetup`. Password modes → "Set Password" alert (password + confirm,
  Cancel/Set). No minimum strength. Empty → "Password cannot be empty"; mismatch → "Passwords do not match"; alert closed,
  retype.
- Set success: `ProgressOverlay` "Setting password…"; off main `createPassword(password)` (+ `enableBiometrics()` in
  biometric mode); on main `lockMode = selected`, `completeSetup`. Failure → `showError`, wizard stays, `lockMode` unchanged.
- `completeSetup`: `hasCompletedSetup = true`, dismiss animated. No migration (vault assumed empty); no unlocked
  notification; `hasAuthenticated` already true from first `handleForeground`. No Back/skip.
- Identifier: `continueButton` only.
- View model: mode selection, validation, create-then-biometrics sequence with failure state.

## SecuritySettingsViewController (`View/SecuritySettings.swift`, UIKit insetGrouped)

- Reached: `FileBrowserViewController.openSettings` → nav, `.formSheet` (FileBrowser.swift:190-194). Title "Security".
- Sections:
  - Pro: one row (`upgradeToProCell`): "Upgrade to Pro" → `PaywallViewController` `.formSheet`; or "Pro Unlocked" with
    checkmark when `EntitlementService.isUnlockedSync`. Combine on `EntitlementService.$isUnlocked` (dropFirst,
    removeDuplicates) reloads the section.
  - Lock Mode: No Lock, Password, Password + Face ID (grey if unavailable), "Re-encrypt Everything" (only if
    `lockMode != .none && hasUnencryptedFiles`, computed off-main for `.root` at load and after each migration).
  - Password (hidden in `.none`): "Change Password".
  - Storage: "Recently Deleted" → push `RecentlyDeletedViewController`.
- Actions:
  - **No Lock**: always "Remove Lock?" (even when already `.none`) → `MigrationViewController(.decrypt, targetLockMode:
    .none)`; completion `finalizeMigration`: only if `completedFully`, `lockMode = .none`, `removePassword()`,
    `wipeKey()`. Then refresh unencrypted state.
  - **Password / +Biometric, no password yet** (`hasPassword()` false): `promptSetPassword` → `createPassword` off-main
    under overlay → main: `try? enableBiometrics()` (biometric mode) → `lockMode = mode` → `.encrypt` migration with target.
  - **Password / +Biometric, password exists**: biometric → `enableBiometrics()` (error shown, return); password →
    `removeBiometricSecret()`; then `lockMode = mode`, reload. No migration, no re-auth. Main thread. Biometric row
    silent if unavailable.
  - **Re-encrypt Everything**: `.encrypt` migration, no target; completion `finalizeMigration(.encrypt, currentLockMode, …)`.
  - **Change Password**: current/new/confirm alert; empty and mismatch on main; off-main under overlay
    `verifyPassword(current)` then `changePassword(to:)`. Wrong → "Current password is incorrect"; success "Password
    changed successfully". Two PBKDF2 derivations.
  - Pro row → paywall; `onUnlock` → reload.
- DEBUG hooks: `testSetHasUnencryptedFiles`, `testTableView`. Identifier: `upgradeToProCell`.
- View model: rows/enablement, mode-change decision tree (migration choice, biometrics, ordering), validation,
  `hasUnencryptedFiles`.

## MigrationViewController (`View/Migration.swift`, UIKit)

- Reached from Settings or `SceneDelegate.handleVaultUnlocked` (resume); full-screen.
- Shows title ("Encrypting Files"/"Decrypting Files"), progress bar, status ("Preparing…", "N% complete", "Paused —
  unlock to continue", "Complete"). No buttons, no cancel; only the failure alert.
- `viewDidAppear` → `startMigration()` (:66-69): persist `pendingMigrationType` (+ target), begin background task,
  `FileSystem.filesToMigrate` (`@concurrent`), `currentIndex = 0`, run loop.
- `runMigration` per file: `!CryptoService.isKeyLoaded` → pause (end bg task, paused text), return. Else
  `migrateFileToEncrypted`/`ToDecrypted` off main; per-file error → `failedFiles`, continue; progress updates.
- `finishOrShowFailures`: failures → "Some Files Failed" alert with names, Retry (failed files only, from 0) / Skip
  (`finishMigration`). `finishMigration` clears pending flags only if no failures, ends bg task, "Complete", 0.5s,
  dismiss, `onComplete(completedFully)`.
- `vaultUnlockedNotification` observer resumes only if `isPaused`. Expiration handler only ends the task.
- DEBUG hooks: `testFailedFileNames`, `testIsPaused`, `testStatusText`, `testMigrationTask`, `testTapRetry`,
  `testTapSkip`. No identifiers.
- View model: the whole migration state machine.

## PaywallViewController (`View/PaywallViewController.swift`, UIKit)

- Reached: Settings Pro row (`.formSheet`); `ImportService.swift:114,144` at the 100-file limit.
- Shows "Unlock Pro", "Store more than 100 files." (from `freeFileLimit`), price, Unlock, Restore Purchases, spinner, X.
- Price from `Product.products(for:)`; error or no product → blank price, no error UI, Unlock stays enabled.
- Unlock: loading → `EntitlementService.shared.purchaseUnlock(confirmIn: windowScene)`; success → `finishIfUnlocked`
  (`onUnlock` + dismiss only if `isUnlocked`); cancel silent; errors `showError`.
- Restore: `restorePurchases()`; unlocked → finish; else "No previous purchase found to restore."; `userCancelled`
  silent; other errors shown. X dismisses.
- Identifiers: `paywallUnlockButton`, `restoreButton`.
- View model: product/price loading, purchase/restore mapping, loading state.

## Master-key touchpoints (screens' side)

- Create: Wizard `createPassword` (background); Settings `promptSetPassword` → `createPassword` (background).
- Unlock: Lock `verifyPassword` (background) or `authenticateWithBiometrics`.
- Rewrap: Settings `verifyPassword(current)` + `changePassword(to:)`, same background block.
- Biometric copy `enableBiometrics`: Wizard (background, errors surface); Settings new password (main, `try?`);
  Settings existing password (main, errors shown); Lock after password login in biometric mode (background, `try?`).
  `removeBiometricSecret()`: Settings → `.password`, main.
- Wipe: `finalizeMigration(.decrypt)` → `removePassword()` + `wipeKey()`; background → `handleDidEnterBackground`;
  AppDelegate UI-test reset.
- Migration: loop requires `isKeyLoaded` per file, pauses when gone.
- Ordering `.none` → password in Settings: `createPassword` → biometric copy → `lockMode = mode` → migration (pending
  flag persisted only at `viewDidAppear`). A kill between `lockMode = mode` and migration start leaves plaintext files
  under a password lock (no key loss; "Re-encrypt Everything" repairs it).
- The Wizard never checks `hasPassword()` before `createPassword`.

## Journeys checked

- **J1 setup**: matches. Non-empty matching password, no strength rule. Biometric card disabled without biometrics.
  `createPassword`/`enableBiometrics` failure → alert, wizard stays. If `enableBiometrics` fails after `createPassword`
  succeeded, a blob exists but `lockMode` stays `.none`; a retry makes a new key.
- **J2 unlock**: matches. "Incorrect password", no lockout/delay/wipe. `.noMasterKeyBlob` shown with no way forward
  (memo obs #18, still true).
- **J8 change lock mode**: matches, with the oddities below. The "short background continuation" is ineffective: the
  key is wiped on background, so the loop pauses at the next file.
- **J9 paywall**: purchase and restore as described; from the Pro row and from `ImportService`.

## API-Memo observations

- #8 privacy screen stuck over lock screen: **fixed** (`showLockScreen` hides it in the early return and the present
  completion, AuthService.swift:311-328).
- #9 cold-launch biometric attempt: **fixed** on the LockScreen side (LockScreen.swift:37-43).
- #3: not checked here (ImportService).
- #6 `NSFaceIDUsageDescription`: present as a build setting; not an issue.
- #7: `NSPhotoLibraryUsageDescription` present as a build setting; plist key `NSPhotoLibraryDescription` is junk.
- #11, #12: `didAuthenticate`/`showLockScreen` still hand-roll the `while let presented` loop; #11 `didAuthenticate`
  still falls back to `root.dismiss` when no lock screen is presented. #13, #17: services pass.
- #15 off-main password work: resolved.
- #18: confirmed.

## Suspected issues

- `FileSystem.swift:604`, `SceneDelegate.swift:73-87` — **`cleanupExpiredTrashItems` has no callers**: the 30-day
  purge (journey 6) never runs.
- `Migration.swift:66-69` + `AuthService.swift:311-328` — `startMigration()` runs on every `viewDidAppear`. Dismissing
  a lock screen over the Migration VC re-runs it (reload list, `currentIndex = 0`, second Task) while the unlock
  notification (if paused) starts another `runMigration`: two loops sharing state; converted files may land in
  `failedFiles`. (Reading only; on the key path.)
- `Migration.swift:124-141` + `AuthService.swift:230-236` — key wiped at background while a file migrates off-main;
  that file fails spuriously. Background task useless.
- `Migration.swift:196-198, 164-166` — Skip with failures leaves `pendingMigrationType` set; screen re-presented after
  every unlock. Encrypt: `lockMode` already changed, `finalizeMigration` no-op. Decrypt: lock, password and key
  untouched, files partly decrypted. No cancel.
- `Migration.swift:161-176` — pending flags cleared before the 0.5s delay; `finalizeMigration` runs after. A kill in
  that window after a decrypt leaves plaintext files under a password lock with the blob present.
- `SecuritySettings.swift:216-243` — password exists but `lockMode == .none` (possible if `removePassword` failed in
  `finalizeMigration`; key wiped): choosing a password mode only sets `lockMode`, files stay plaintext; biometric
  `enableBiometrics` fails (no key).
- `SecuritySettings.swift:200-215` — "No Lock" when already `.none` still runs a decrypt + `removePassword()` +
  `wipeKey()`: an unguarded key-wipe path.
- `SecuritySettings.swift:216-229` — `try? enableBiometrics()` on main; failure swallowed, `lockMode` still set to
  biometric. Other path (:231-237) surfaces it.
- `SecuritySettings.swift:193, 210, 225` — strong `self` in completions (minor).
- `SecuritySettings.swift:239` — `removeBiometricSecret()` on main, no error handling.
- `SetupWizard.swift:220` — no `hasPassword()` check before `createPassword`: if `hasCompletedSetup` is false but a
  blob exists (UserDefaults reset, Keychain kept), a new master key overwrites the old blob; old files unrecoverable
  (memo obs #17).
- `SetupWizard.swift:206-213`, `SecuritySettings.swift:255-262` — validation closes the alert; no minimum strength (S2).
- `LockScreen.swift:33-43` — biometric mode: field not focused; availability not checked before auto-attempt.
- `LockScreen.swift:136-166` — no feedback during PBKDF2; button not disabled; error label never cleared.
- `LockScreen.swift:80-82` — biometric button visibility set once.
- `AppDelegate.swift:18-48` — `--uitesting` reset wipes real state, also on a device (DEBUG only).
- `SceneDelegate.swift:38` — `sweepOrphanedEncryptedFiles(in: .root)` on main at launch before unlock; guarded, but
  related to the `wipeOrphanedEntries` bug; services pass to confirm.
- `SceneDelegate.swift:73-87` — runs on every unlock; encrypt resume with nil target leaves `lockMode` as is.
- `SceneDelegate.swift:78, 81` — leftover comment and duplicate guard (dead code).
- `PaywallViewController.swift:83-90` — product load failure: blank price, Unlock enabled, no message.
- `PaywallViewController.swift:97-99` — cancel silent, paywall stays (likely intended).
- `PaywallViewController.swift:26` — `Task` without weak self; loading state not reset on dismiss (minor).

NOT READ: nothing skipped. AuthService key/Keychain internals deliberately left for the services pass.
