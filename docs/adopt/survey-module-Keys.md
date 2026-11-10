# Survey: module Keys (key lifecycle and lock state)

STATUS: done
PASS: module Keys

Read only; nothing run. "(verify)" = a conclusion from UIKit/Keychain semantics or interleavings that a journey or unit
test should confirm. Builds on survey-services §1 and survey-data §6-7.

## 1. Persistent pieces and combined states

| Piece | Where | Written by |
|---|---|---|
| Master-key blob (v1: 1+4+32+AES-GCM, PBKDF2 600k, 37-byte header AAD) | Keychain `com.KoalaTVault.masterKeyBlob`, WhenUnlocked, not ThisDeviceOnly | `createMasterKey` (CryptoService:61), `rewrapMasterKey` (:101, update in place, add fallback), `wipeMasterKeyBlob` (:110) |
| Biometric item (raw 32-byte key) | Keychain `com.KoalaTVault.biometricMasterKey`, biometryCurrentSet, ThisDeviceOnly | `enableBiometrics` (AuthService:71, delete then add), `removeBiometricSecret` (:78, ignores status) |
| `lockMode` | UserDefaults | AuthService:32 |
| `hasCompletedSetup` | UserDefaults | SetupWizard:242 |
| `pendingMigrationType`, `pendingMigrationTargetLockMode` | UserDefaults | `startMigration` (Migration:104-107); cleared only in `finishMigration` when `failedFiles.isEmpty` (:163-166); stale target never cleared |
| In-memory key | `OSAllocatedUnfairLock<SymmetricKey?>` | loaded by `createMasterKey`, `unwrapMasterKey`, `loadMasterKey`; wiped by `wipeKey` (background lock AuthService:233, decrypt finalize :146) |
| Files | per-directory `.vault_map` (encrypted if a key is loaded, else **plaintext**) | encrypted = UUID name in map; `contents` skips hidden, so `.trash` never seen |
| Trash | `.trash/` + `.trash_map` | same rule as maps |
| Session flags | `isLocked`, `hasAuthenticated` (AuthService:210-211) | `hasAuthenticated` never reset to false |

Intended valid states:

| # | lockMode | Blob | Bio | Key in memory | Files |
|---|---|---|---|---|---|
| S0 | none | no | no | no | plaintext |
| S1 | password | yes | no | after unlock | encrypted (mixed while migrating) |
| S2 | passwordAndBiometrics | yes | yes (same key) | after unlock | encrypted |
| S3 | S1/S2 + pending set | yes | per mode | paused if no key | mixed |

Anything else is invalid.

## 2. Transitions (B = blob, Bio, LM = lockMode, K = key, P = pending flags)

- **T1 Setup none** (SetupWizard:183-185): LM=none → `hasCompletedSetup`. Kill between: wizard again (harmless).
- **T2 Setup password/biometric** (SetupWizard:218-231): (1) B + K (`createPassword`) → (2) Bio (biometric only) →
  (3) LM=mode (main) → (4) `hasCompletedSetup`.
  - Fail/kill after 1 before 3: **INVALID** — B exists, LM=none, setup incomplete.
  - Retry: `createPassword` throws `masterKeyAlreadyExists` (CryptoService:62) forever; "none" works but orphans B; a
    later Settings none→password sees `hasPassword()` true and skips migration (T6).
  - Reinstall: Keychain survives, UserDefaults/Documents don't → same dead end (verify).
- **T3 Unlock password** (LockScreen:136-166, AuthService:48): unwrap (replaces K; wrong → `wrongPassword`) → legacy item
  deleted → biometric mode: `try? enableBiometrics` (LockScreen:149-151) → `didAuthenticate`. A failed add after the
  delete silently loses Bio; LM stays biometric; biometric button then fails generically (password still works).
- **T4 Unlock biometric** (AuthService:172-207): `SecItemCopyMatching` → `loadMasterKey` accepts any 32 bytes, **never
  checked against B**. A stale Bio item would load a wrong key and new files would go under a key B doesn't wrap. Low
  probability, unguarded.
- **T5 Background/foreground** (AuthService:222-249): resign → privacy only; background (if `hasAuthenticated` &&
  LM≠none) → `isLocked`, `wipeKey`, temp cleanup, thumbnail cache; foreground: LM none → `hasAuthenticated`; else
  `isLocked` → lock screen. Wipe on main while background work may be mid-operation (see (e)).
- **T6 none → password/biometric** (SecuritySettings:216-229), branch on `!hasPassword()` (**true on Keychain error**,
  AuthService:58): (1) B + K → (2) `try? enableBiometrics` (swallowed) → (3) LM → (4) present migration → (5) P on
  `viewDidAppear` → (6) per file: encrypted file → map → delete plaintext → (7) P cleared → finalize.
  - Kill 1-3: **INVALID** (B, LM=none). Later none→password takes the plain-switch branch (:230-243): LM set with no
    prompt, no K, no migration; plaintext under LM=password; Re-encrypt row shows but no key.
  - Kill 3-5: LM=mode, no P, plaintext; Re-encrypt row (`showsReEncryptRow`, :84) recovers manually.
  - Kill during 6: mixed, P set; relaunch → lock → unlock → resume (SceneDelegate:73-87). Valid.
  - Kill between P clear (Migration:163-166) and `onComplete`: harmless for encrypt.
- **T7 password → biometric** (SecuritySettings:231-241): `enableBiometrics` (needs K) → LM. Throw → shown, LM unchanged.
  Kill between: Bio with LM=password (harmless).
- **T8 biometric → password**: `removeBiometricSecret` → LM. Kill between: LM biometric, no Bio (generic error).
- **T9 Change password** (SecuritySettings:305-311): `verifyPassword(current)` → `rewrapMasterKey` (single update, fresh
  salt). Failure keeps the old blob/password; key unchanged; Bio valid. No invalid state. Weak: new password not
  re-verified after the write; no strength check.
- **T10 password → none** (SecuritySettings:199-215, decrypt migration, `finalizeMigration` AuthService:127-148): LM
  unchanged during migration (relaunch → lock → resume, correct). Finalize (only `completedFully`): LM=none →
  `removePassword` (B → Bio → legacy) → `wipeKey`. `wipeMasterKeyBlob` throw skips Bio/legacy; only logged (:144).
  - Kill after LM=none before B delete: LM=none with B.
  - `wipeMasterKeyBlob` throws: **INVALID** — LM=none, B and raw-key Bio remain.
  - Normal completion: see (f), (g) — trash and maps left under the wiped key.
  - Kill between P clear and `onComplete`: **INVALID** — all plaintext, LM=password, B present, no P; finalize never runs.
  - Skip with failures: finalize no-op; P stays; migration VC re-presented on every unlock.
- **T11 Re-encrypt** (SecuritySettings:191-197): encrypt migration, no target; finalize no-op.
- **T12 Pause/resume/retry/skip** (Migration:124-221): pause checked once per file; resume only if `isPaused`; Retry swaps
  list, index 0; Skip → `completedFully` false; `startMigration` on every `viewDidAppear` (:66-69).
- **T13 Cold launch** (SceneDelegate:29-38): LM≠none → lock → unlock → notification → migration VC if P. LM none →
  notification immediately (pending decrypt/encrypt can't occur here since LM is set at the right points). Launch sweep
  bails on an unreadable map (safe with no key).

## 3. Suspicions confirmed or refuted

- **(a) `startMigration` double-run: CONFIRMED by reading** (verify UIKit part). `viewDidAppear` always calls it (no
  guard, no cancel): reloads list, `currentIndex=0`, new `runMigration` (:103-120). The lock screen is presented on the
  migration VC (AuthService:313-325); dismissing a full-screen modal calls the presenter's `viewDidAppear` (verify).
  Then the notification resumes a second loop if `isPaused` (:216-221); SceneDelegate correctly adds none. Both loops
  share `currentIndex`/list across `await`: items processed twice or skipped; the second migrate of a file throws (source
  gone) → spurious failure, "Some Files Failed" (maybe twice), Retry can't clear it. Doesn't reach finalize with an
  unmigrated file, but the user is stuck in a failure loop.
- **(b) `completedFully`: CONFIRMED** = `failedFiles.isEmpty` (Migration:162), no re-scan. List computed once
  (`startMigration`, :112) from `.root`, recursive, excludes hidden. So **`finalizeMigration(.decrypt)` runs with
  encrypted data still present**: trash items and `.trash_map` (always), `.vault_map` files (see (g)), files added after
  the list. Then B, Bio and K are deleted → trash permanently undecryptable. Skip is not a bypass.
- **(c) `hasAuthenticated` after setup: REFUTED for the normal flow.** Fresh install LM=none; `sceneDidBecomeActive` →
  `handleForeground` sets it (AuthService:239-241) before the wizard finishes, so background lock works. It never resets
  ("ever authenticated this process"); `isLocked` is the real state.
- **(d) LAError branches: CONFIRMED unreachable.** Completion gets only nil or `AuthError.keychainError` (AuthService:195,
  204); `error as? LAError` always fails (LockScreen:187); switch :191-202 dead. Lockout/not-enrolled/passcode messages
  never shown; `errSecItemNotFound` after enrolment change looks the same.
- **(e) plaintext map after mid-operation wipe: CONFIRMED reachable.** `saveEncryptedJSON` writes plaintext if
  `!isKeyLoaded` (FileSystem:874-879). `migrateFileToEncrypted`: `loadMapping` (:669) → long `encryptFile` (:677,
  captured key) → `saveMapping` (:679). Background wipe in that window → whole map written **plaintext** (names
  exposed); after unlock `loadEncryptedJSON` has no plaintext fallback (:842-863) → `mappingUnreadable`, directory
  inaccessible. `migrateFileToDecrypted` (:716-722) same shape, after the encrypted file is already deleted.
  `moveToTrash` and other writers likewise. Wipe before `loadMapping` → safe failure.
- **(f) trash not migrated: CONFIRMED.** `.skipsHiddenFiles` (FileSystem:88), `.trash` hidden (:488), `filesToMigrate`
  (:631) uses `contents`. After decrypt: trash + map under the wiped key. After encrypt: plaintext `.trash_map` unreadable
  once a key is loaded; `moveToTrash` moves then throws (:512); `contentsOfTrash` throws (verify). Decrypt case: trash ops
  in LM=none with the encrypted map throw too.
- **(g) NEW: encrypted `.vault_map` left after a decrypt migration.** `migrateFileToDecrypted` saves the map with the key
  loaded, leaving an encrypted (eventually empty) map (:720-722). `migrateVaultToDecrypted` (deletes `.vault_map`,
  :693-694) has **no caller** (dead). After finalize wipes the key, `loadMapping` decodes ciphertext as JSON → throws
  `mappingUnreadable` (:865-869); `contents(of:)` calls it first (:91) → **every listing would fail after a completed
  "Remove Lock"**. No test covers decrypt (verify with a journey test). Highest-impact finding.
- Other: `startMigration` load failure (e.g. `mappingUnreadable`) shows an error with no way to dismiss the migration VC;
  P stays (Migration:112-116, guess).

## 4. Proposed contract surface (suggestion)

Operations:
- `createVault(password:, mode:)` atomic: B, optional Bio, then LM; rollback B/Bio if a later step fails. Errors
  `alreadyExists`, `keychain(status)`, `biometryUnavailable`.
- `unlock(password:)`, `unlockWithBiometrics()`. Errors `wrongPassword`, `noKeyBlob`, `biometryLockedOut`,
  `biometryChanged`/`itemInvalidated`, `biometryNotEnrolled`, `passcodeNotSet`, `userCancelled`, `keychain`. Biometric
  unlock verifies the key against B (or a known-answer check).
- `lock()` wipes K; waits for or refuses while key-using operations are in flight.
- `changePassword(current:, new:)` verifies, rewraps, confirms by unwrapping with the new password.
- `setMode(_:)` (password ↔ biometric): Bio before LM, roll back on failure.
- `removeLock(password:)`, `addLock(...)` as multi-step operations with one persisted record (type, target, status).
- Scoped key access (`withKey { }`) so file code doesn't read `isKeyLoaded`.

Observable state: `state` enum (`noVault`, `unlocked(mode)`, `locked(mode)`, `migrating(type, progress, paused)`,
`needsRepair(reason)`), `lockMode`, `biometricType`, `biometricsAvailable`, `pendingMigration`, an events stream replacing
`vaultUnlockedNotification`.

Invariants for tests:
- B, Bio, LM and the files' encryption state never disagree after any failure or kill.
- Key and blob deleted only when every file, including trash and maps, is plaintext.
- No plaintext map written while a key could be required (decide encryption once per operation).
- One migration runner; idempotent start; explicit "already running" guard.

## Suspected issues

- Migration.swift:66-69, 103-120, 216-221 — double-run; shared index → duplicates, spurious failures.
- FileSystem.swift:669-680, 716-722, 874-879 — key wipe between load and save writes a plaintext map → directory
  unreadable after unlock; names exposed.
- FileSystem.swift:88, 631-642 — trash never migrated (stuck under wiped key; plaintext trash map unreadable after encrypt).
- FileSystem.swift:720-722, 683-706 + Migration.swift:144-159 — **encrypted `.vault_map` left after decrypt; listings
  likely fail after "Remove Lock"**; `migrateVaultToDecrypted` has no caller.
- Migration.swift:161-176 + AuthService.swift:127-148 — P cleared before `onComplete`; kill after a decrypt → plaintext,
  LM=password, B present, no record. `completedFully` has no re-scan.
- SetupWizard.swift:220-231, SecuritySettings.swift:216-229 — B before LM; failure/kill → wizard dead end
  (`masterKeyAlreadyExists`); reinstall reaches the same (verify).
- AuthService.swift:57-59 — `hasPassword()` true on Keychain error → plain-switch branch, plaintext under LM=password.
- AuthService.swift:61-65 — `removePassword` aborts before removing the raw-key Bio item.
- AuthService.swift:71-75, 89-115; SecuritySettings.swift:220; LockScreen.swift:149-151 — delete-then-add + `try?` →
  silent Bio loss.
- AuthService.swift:172-207 — biometric key not checked against B.
- LockScreen.swift:185-203 — dead LAError switch.
- Migration.swift:112-116 — no way out of the migration VC on a load failure (guess).
- Migration.swift:192-198 — Skip leaves P; VC re-presented every unlock; decrypt keeps the lock.
- AuthService.swift:211 — `hasAuthenticated` misleading name.
- FileSystem.swift:644-660, 683-706 — `migrateVaultTo*` dead; early return at :648.

NOT READ: none.
