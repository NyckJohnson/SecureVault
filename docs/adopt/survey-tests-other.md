# Survey: tests (auth, migration, import/export, preferences, entitlements, settings, media) and UI tests

STATUS: done
PASS: tests

Read only, not run. Note: the inventory lists unit tests only; the UI test target `KoalaTVaultUITests` (648 lines) also
exists and is covered here.

## Common

- All XCTest except `KoalaTVaultTests.swift` (Swift Testing, empty).
- Real Keychain item "com.KoalaTVault"; setUp/tearDown call `removePassword`/`wipeMasterKeyBlob`. Leaks break later
  `createMasterKey`; would delete a real vault's blob on the same simulator (guess).
- Shared singletons: `AuthService`, `CryptoService`, `PreferencesService` (real UserDefaults, never restored),
  `EntitlementService`, `ThumbnailService`. **Test plan enables Thread Sanitizer.** Serial execution needed (no
  parallelization set). Fixed temp names (`tmp/test.txt`, `file1.txt`, `overflow.txt`).
- Order dependence in auth, migration and media classes. Unit tests are app-hosted (`connectedScenes.first`, real
  `EntitlementService.shared`).

## Unit tests per file

1. **AuthServiceTests.swift** (318, 3 classes) — auth/key lifecycle.
   - `AuthServiceTests` (real Keychain; resets `isLocked`, `hasAuthenticated`, `lockMode`, `removePassword`, `wipeKey`):
     create→verify; wrong → `AuthError.wrongPassword`; `hasPassword` true/false; verify loads the key; `changePassword`
     new works, old fails; no blob → `CryptoError.noMasterKeyBlob` (raw); regression: data still decrypts after rewrap +
     wipe + re-verify; `handleWillResignActive(in: nil)` doesn't lock/wipe; `handleDidEnterBackground(in: nil)` locks
     only if `hasAuthenticated && lockMode != .none`, wipes the key. Three tautologies (`testIsLockedTrueWhenLocked`,
     `...FalseWhenNotLocked`, `testNoLockModeIsNone`).
   - `AuthServiceForegroundTests`: `handleForeground` `.none` sets `hasAuthenticated`, `isLocked` untouched; password →
     unchanged. `handleInitialLaunch` `.none` posts the notification, `isLocked` false; password sets `isLocked`.
     `biometricType` non-empty; `removeBiometricSecret` idempotent (vacuous `XCTAssertNoThrow`); `lockMode` delegates.
     Doesn't clean leaked blobs.
   - `MigrationFinalizationTests`: encrypt `true` sets target, `false` nothing; decrypt `true` → `.none`, blob removed,
     key wiped; `false` keeps state.
   - All scene hooks called with `in: nil`: lock screen and privacy UI never exercised.
2. **MigrationTests.swift** (125, `: VaultTestCase`) — migration. Uses production test hooks (`testFailedFileNames`,
   `testTapSkip`, `testTapRetry`, `testIsPaused`, `testStatusText`, `FileSystem.testForcedMigrationFailureFileName`).
   All succeed → `onComplete(true)`; forced failure → `["bad.txt"]`, Skip → `false`; Retry after clearing → `true`; key
   wiped → paused, "Paused — unlock to continue"; notification after re-unwrap → resumes, `true`. **Encrypt only**; no
   decrypt, pending resume, `finalizeMigration` from the VC, `viewDidAppear` double-run, trash. `asyncAfter(0.3)` +
   `wait(10)` (mildly flaky). Fresh bare `UIWindow()`.
3. **ImportServiceTests.swift** (53) — import. `FakeCameraRollDeleter`; `confirmDeleteFromCameraRoll` forwards ids;
   empty array still forwarded (pins no guard). Stale comment `promptDeleteFromCameraRoll`. No picker/paywall/limit/
   `performImport`/Photos.
4. **ExportServiceTests.swift** (103, `: VaultTestCase`) — export, but only `FileSystem.prepareForExport` and
   `cleanupTempFiles`: unencrypted returns existing URLs; encrypted decrypts with original name; no key throws; empty →
   empty; cleanup removes the file. No `ExportService` UI, camera roll, partial failure, folders.
5. **FileImportLimitTests.swift** (108, `: VaultTestCase`) — limit/import. Under limit OK; 100+1 throws; 99+1 allowed;
   unlocked bypasses; over-limit `importItems` imports nothing (still 100); unlocked beyond limit OK; subfolder files
   count. Uses `EntitlementService.testForcedUnlocked` (DEBUG, reset). No multi-file crossing, trash/hidden not
   counted, `isUnlockedSync` seeding.
6. **PreferencesServiceTests.swift** (84, real UserDefaults) — preferences. `hasCompletedSetup` default/set; `lockMode`
   default `.none`, set each; pending type/target round trip incl. nil. "Persists" tests read the same singleton (prove
   nothing). Pending keys reset only in their tests. No unknown raw values, sort keys, `entitlement.isUnlocked`.
7. **StoreKitConfigurationTests.swift** (78, `StoreKitTest`) — entitlements. `SKTestSession(contentsOf:
   premiumTesting.storekit)`, reset, clear, disable dialogs; product loads `.nonConsumable`; `buyProduct` + refresh →
   `isUnlocked`. "Starts locked" precondition may flake (UserDefaults cache). No error mapping, restore, listener,
   revocation, `isUnlockedSync`.
8. **SecuritySettingsProTests.swift** (77) — settings + entitlements. Row 0/0 "Upgrade to Pro" + disclosure when
   locked, "Pro Unlocked" + checkmark when unlocked; tap presents `PaywallViewController` only when locked. Uses
   `testTableView`; needs a connected scene.
9. **SecuritySettingsViewControllerTests.swift** (45) — settings. Lock section rows: 3 in `.none`; 3 locked without
   unencrypted files; 4 with (re-encrypt row). `testSetHasUnencryptedFiles`. Names say "Unlocked" meaning `.none`. No
   mode changes, prompts, migration paths.
10. **MediaPipelineTests.swift** (424, 3 classes) — media/viewer. `VaultResourceLoaderDelegate` `init?` succeeds for
    valid/empty/multi-chunk/unknown extension; fails for plaintext, missing, truncated header, bad magic (byte ranges
    untestable per header). `ThumbnailService`: `clearCache` no crash; corrupt/truncated → nil; cancel before decrypt
    prevents completion; second request from cache. `FileViewerViewController`: no-crash smoke tests (nil player, skip
    near ends, player replacement, play/pause). Timing-dependent cancel tests. `tearDownWithError` uses `try` on
    `wipeMasterKeyBlob`. (Lines ~60-315, 345-424 read by test name only.)
11. **KoalaTVaultTests.swift** (18, Swift Testing) — empty `example`. Dead.
12. **premiumTesting.storekit** — NonConsumable `nej.KoalaTVault.unlockpro`, "Unlock Pro", 19.99, en_US/USA. In
    `KoalaTVaultTests/`, also loaded by `PaywallUITests` via `Bundle(for:)`. The test plan sets no StoreKit configuration.

## UI tests (`KoalaTVaultUITests`, XCUITest)

- `VaultUITestCase`: launches with **`--uitesting`** + `additionalLaunchEnvironment`; `continueAfterFailure = false`;
  terminates in tearDown. `skipSetupIfNeeded` taps `continueButton` if it appears within 2s.
- App side (AppDelegate.swift:18-48, DEBUG): resets setup and lock mode, removes the password, disables animations,
  empties trash, wipes the key, **deletes everything in the real `VaultDirectory.root`**.
- Seeds: `UITEST_SEED_FILE_NAME`, `UITEST_SEED_FILE_COUNT` (unused by tests), `UITEST_PASSWORD`,
  `UITEST_FAIL_MIGRATION_FILE` (FileSystem.swift:664, :710; DEBUG-only not confirmed).
- The stack rules name the clean-state option `-uiTesting`; the app uses `--uitesting` (rename or alias in baseline).
- **KoalaTVault.xctestplan**: one configuration, no env, no StoreKit config, Thread Sanitizer on, targets
  `KoalaTVaultTests` + `KoalaTVaultUITests`, no parallelization options.

Files:
- **KoalaTVaultUITests.swift** (168): `testExample`, `testLaunchPerformance` (template, no `--uitesting`, no asserts).
  J1: wizard appears (`continueButton`); Continue with no lock → nav bar "KoalaTVault" (no password/biometric path).
  J3: `newFolderButton`, `importButton`, `selectButton`, `settingsButton` exist; create folder / cancel; select on/off;
  into folder and back. J4: import sheet options; cancel by tapping background (iPad behavior; likely fails on iPhone).
  Settings opens ("Security").
- **AdditionalUITests.swift** (253): J3 context menu (Rename, Move, Export, Delete); rename; delete + confirm; sort sheet
  (`sortButton`; "Name ↑", "Type", "Date Modified"; dismiss by tapping — same iPhone concern); New Document found by SF
  Symbol `doc.badge.plus`, Create opens editor "MyDocument.rtf"; select titles and bulk buttons; folder title, "No files
  yet", nested back twice. J6: Recently Deleted opens, empty state only. J8: "No Lock" text;
  `testMigrationFailureShowsRetrySkipOptions` launches a second `XCUIApplication` with `UITEST_SEED_FILE_NAME` +
  `UITEST_FAIL_MIGRATION_FILE`, Settings → "Password" → Set Password alert → "Some Files Failed" with Retry/Skip and
  "These files couldn't be migrated: failtest.txt" → Skip (only encrypt-migration UI test; `skipSetupIfNeeded` uses the
  base `app` handle, suspected). Unused `clearText()`; debug print.
- **PaywallUITests.swift** (151, `StoreKitTest`, `UITEST_PASSWORD=uitestPassword123`): J2 unlock via `passwordField`,
  `unlockButton`. J9: purchase doesn't trigger the lock screen (regression), paywall dismisses, "Pro Unlocked"
  (`upgradeToProCell`, `paywallUnlockButton`); restore with none → "No previous purchase found to restore." (`restoreButton`);
  restore with a purchase unlocks; Pro row flips live on external purchase. Session created after launch (timing-sensitive, guess).
- **KoalaTVaultUITestsLaunchTests.swift** (35): template screenshot launch without `--uitesting`, all configurations.
- Identifiers used: `continueButton`, `newFolderButton`, `importButton`, `selectButton`, `settingsButton`, `sortButton`,
  `passwordField`, `unlockButton`, `upgradeToProCell`, `paywallUnlockButton`, `restoreButton`. Everything else by
  label/title text.

## Journey coverage (UI)

J1 no-lock only · J2 password unlock only (no wrong password, biometrics, relock, `noMasterKeyBlob`) · J3 well covered ·
J4 sheet options only · J5 **none** · J6 empty state only · J7 menu item only · J8 one encrypt-failure/Skip path · J9 good.

## Key lifecycle: covered vs not

- Covered (unit): create; verify right/wrong/no blob; rewrap keeps file access; background wipe (`in: nil`);
  `finalizeMigration` encrypt/decrypt × success/false; remove → `hasPassword` false.
- Not covered: `createPassword` with an existing blob via AuthService; all biometric paths (`enableBiometrics`,
  `authenticateWithBiometrics`, item attributes, delete-then-add, user cancel); `removePassword` failure (orphan blob);
  decrypt-finalize partial failure and kill window; stranded trash; reverse case (UserDefaults lost); `hasPassword`
  fail-toward-true; wizard partial failure; `didAuthenticate`/`showLockScreen`/privacy view; `hasAuthenticated` after
  setup (masked by `UITEST_PASSWORD`); pending-migration resume; `startMigration` double-run; key wiped mid-file; lockout
  (none exists).

## Obsolete, duplicated, tautological, behavior-pinning

- Dead: `KoalaTVaultTests.swift` `example`; UI `testExample`, `testLaunchPerformance`, `KoalaTVaultUITestsLaunchTests`;
  `clearText()`; stale comment in ImportServiceTests.
- Tautological: three AuthServiceTests property tests; PreferencesServiceTests "Persists"/"CanBeSet";
  `removeBiometricSecret` NoThrow.
- Duplicated: `testHasPasswordReturnsTrueAfterSet` ≈ `testSetAndVerifyPassword`; repeated UI folder-creation steps.
- Pins oddities: empty-identifiers delete; raw `CryptoError.noMasterKeyBlob`; decrypt-finalize ordering (not failure);
  Skip returns `false` leaving state; Skip simply dismisses; subfolder files count toward the limit; in-memory
  thumbnail cache keyed by item id.

## Suspected issues

- AppDelegate.swift:18-48 — `--uitesting` deletes the real Documents vault and blob; unit tests also wipe the real blob.
- AuthServiceTests.swift:117-131, 162-178 — foreground classes don't remove leaked blobs.
- AuthServiceTests background tests — `in: nil` hides the lock UI and the `hasAuthenticated`-after-setup issue.
- PaywallUITests.swift:24-34 — StoreKit session created after launch.
- KoalaTVaultUITests.swift:71-75 and `AdditionalUITests.testSortSheetDismissesOnCancel` — tap-to-dismiss action sheets
  (iPad only; likely fails on iPhone).
- KoalaTVaultUITests.swift:14-26, LaunchTests — run without `--uitesting` against real state.
- `AdditionalUITests.testMigrationFailureShowsRetrySkipOptions` — second app launch; helper uses the base handle (guess).
- Test plan has no StoreKit configuration.
- StoreKitConfigurationTests.swift:53-62 — "starts locked" may flake.
- PreferencesServiceTests — mutates real UserDefaults without restoring.
- MediaPipelineTests `FileViewerViewControllerTests` — smoke only.
- MigrationTests — fixed sleeps.
- Thread Sanitizer + AuthService plain vars.
- Production test hooks (`testFailedFileNames`, `testTapSkip`, `testTapRetry`, `testIsPaused`, `testStatusText`,
  `testTableView`, `testSetHasUnencryptedFiles`, `testForcedUnlocked`, `testForcedMigrationFailureFileName`) plus env
  `UITEST_FAIL_MIGRATION_FILE` (DEBUG-only not confirmed).

NOT READ: nothing skipped (MediaPipelineTests partly by test name).
