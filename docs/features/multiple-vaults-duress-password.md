# Multiple vaults / duress password

<!-- Added with `feature add`. The orchestrator fills the sections below during the feature's stage 1. -->

## Idea
more than one vault, each with its own password, including a duress password that opens a decoy vault

From the human (2026-11-10): there is always one unencrypted vault, and the user can make encrypted vaults; more than one
encrypted vault is part of Pro. The app opens to the unencrypted vault's root. A Vaults button lets the user type a
vault's password, which finds the matching vault and opens it, or create a new vault. Because any password simply opens
the vault it belongs to, a second vault doubles as a duress (decoy) vault.

## Discussion notes
- 2026-11-10 (human): the app-wide lock goes: no setup wizard, no lock screen at launch, no Settings → Lock Mode and no
  encrypt/decrypt-everything migration. Encryption belongs to each vault, fixed when it's created.
- 2026-11-10 (human): sending the app to the background while an encrypted vault is open closes it (key and plaintext temp
  files wiped); returning shows the unencrypted vault's root, no lock screen.
- 2026-11-10 (human): the free 100-file limit counts per vault (each vault up to 100 files without Pro). Pro also allows
  more than one encrypted vault.
- Assumed (stated to the human, not objected to): upgrading a No Lock vault → its files are the unencrypted vault;
  upgrading a locked vault → it becomes the first encrypted vault with the same password and the unencrypted vault starts
  empty. The app never shows how many encrypted vaults exist; the Vaults button shows only a password field and "Create
  New Vault"; Settings inside an open vault manages that vault only. Each vault has its own folders, trash and Storage.
- 2026-11-10 (human, after learning iOS doesn't say which face matched): Face ID / Touch ID can be turned on for one
  chosen encrypted vault at most (from that vault's Settings); the Vaults screen then offers a Face ID button.
- 2026-11-10 (human): Move and Copy gain "To Another Vault…": type the target vault's password (or pick the unencrypted
  vault); files are re-encrypted / decrypted on the way. This replaces the encrypt-everything migration.
- The vault folder is not shared with the Files app (no UIFileSharingEnabled), so other vaults aren't visible there.

- 2026-11-10 (human): encrypted vaults are named at creation (the name is the vault root's title; stored encrypted).
- 2026-11-10 (human): an encrypted vault can be deleted from its own Settings ("Delete This Vault", confirmed by typing
  its password): its files, trash and key are erased and the app returns to the unencrypted root.
- 2026-11-10 (human): a free user with one encrypted vault who taps Create New Vault sees the paywall; accepted that this
  reveals a vault exists (the unencrypted vault is a free user's decoy).
- Assumed (stated to the human): inside an encrypted vault the Vaults button also offers "Close Vault"; a new vault whose
  password another vault already uses is refused ("Choose a different password."); a wrong password shows only
  "Incorrect password"; Change Password stays, per vault.
- Orchestrator notes: 1.2 is not released yet, so "upgrading users" are test devices (the human's own holds a 23 GB
  locked vault). Each password try costs one PBKDF2 (600,000 iterations, a fraction of a second on device), so opening
  takes longer with more vaults (a spinner shows). The queued `faster-lock-changes-in-large-folders` loses its lock
  changes; the same slow pattern remains for large moves between vaults and the upgrade's leftover encryption (that brief
  to be updated when this feature is accepted).

## Agreed scope
- Vault model: one unencrypted vault, always there, the app's Documents folder as today; any number of encrypted vaults
  (one without Pro), each its own folder outside Documents with its own password-wrapped key, name (encrypted), folders,
  trash. The app never lists or counts encrypted vaults.
- New or changed journeys:
  - 1 First launch → the browser opens on the unencrypted vault's root; no setup wizard.
  - 2 Unlock → "Open a vault": Vaults button (root toolbar) → Vaults screen: password field, Open, "Use Face ID" (only when
    a vault has Face ID), "Create New Vault", and "Close Vault" while an encrypted vault is open. The password opens the
    vault it belongs to (that vault's root, titled with its name). Wrong → "Incorrect password". Backgrounding with an
    encrypted vault open: privacy cover, then close (key and plaintext temp files wiped); return shows the unencrypted
    root with no lock screen.
  - 8 Change lock mode → "Manage a vault": in an encrypted vault's Settings: Change Password; "Use Face ID for This
    Vault" (turning it on moves Face ID from whichever vault had it, silently); Delete This Vault (type its password).
    The unencrypted vault's Settings has none of these.
  - 9 Paywall: also opens from Create New Vault when one encrypted vault exists without Pro; copy covers both limits.
  - 4 Import: the 100-file free limit counts the open vault only.
  - New 10 Create a vault: name, password, confirm → the new vault opens. Failures: empty name, empty password,
    mismatch, password used by another vault, paywall.
  - New 11 Move/Copy to another vault: long press and Select mode → Move / Copy → "To Another Vault…" → the unencrypted
    vault, or type a vault's password → files (folders whole) re-encrypted or decrypted into the target's root, with
    progress; per-vault free limit checked first; a failure part-way leaves each item in exactly one place (move) and
    reports how many failed.
  - New 12 Upgrade from one vault (once, at first launch of this version): No Lock → the files are the unencrypted vault.
    A lock → the vault (files, trash, key and Face ID) becomes an encrypted vault named "My Vault" with the same
    password, and the unencrypted vault starts empty. Crash-safe (resumes at next launch). Files a past lock change left
    plaintext are encrypted when that vault is next opened (progress screen). The old lock-mode settings are then unused.
- New or changed screens: Vaults screen (new), Create Vault (new), vault picker for "To Another Vault…" (new), transfer
  progress (new); Settings (per vault); Migration screen → "Encrypting leftover files"; Paywall (copy); Browser (Vaults
  button, root title, Move/Copy to vault). Removed: setup wizard, lock screen.
- Affected modules (new / changed): VaultCrypto (key per vault), Preferences (lock-mode keys read only for the
  upgrade), VaultStore (one store per vault, mode fixed per vault; decrypt-migration steps go), VaultLock (becomes the
  vault registry: create, open by password or Face ID, close, delete, change password, Face ID, upgrade), LockMigration
  (only encrypts an opened vault's leftovers), LockScreens (Vaults and Create Vault screens, privacy cover, close on
  background; wizard and lock screen removed), Settings, Browser, app shell (services per open vault). New module
  VaultTransfer (move/copy between vaults with the per-vault limit). Import, Export, Media, Viewer unchanged in code
  (built per vault by the shell).
- Contract changes: VaultCrypto (per-vault key store), Preferences, VaultStore, VaultLock, LockMigration, LockScreens,
  Settings, Browser (exact shapes in the outline).
- Out of scope: hiding vaults from someone examining the device itself (vault folders and Keychain items can be counted
  with device-level access); timing of the password search (except: no vaults vs some, closed 2026-11-11); renaming a vault; lockout, password strength, password
  recovery (their own features); making large moves fast (feature `faster-lock-changes-in-large-folders`).

## Build notes
- 2026-11-10: `feature plan` reopened Viewer unit 2 and gave LockScreens unit 2 an extra file only because the memo's
  Files lines name `Views/LiveViewerFactory.swift` and `Views/LockPresenter.swift`, which the adoption-era status units
  lacked. Viewer needs no change: at build, run `ios-pipeline gates Viewer` and, on a pass, mark unit 2 done with no
  subagents. LockPresenter.swift is handled with LockScreens unit 2 as the memo says.
- Skeleton next (`MODE: feature multiple-vaults-duress-password`), then prototype for the Vaults, Create Vault, vault
  picker and changed Settings screens; no manual project setup is needed (Face ID usage text already exists).
- 2026-11-10 (prototype): Browser takes an optional `BrowserVaultServices(lock:transfer:vaultsScreens:)` via
  `LiveBrowserFactory(..., vaultServices:)`, and FileBrowserViewModel optional `lock:`/`transfer:`; nil hides the
  Vaults button and the vault actions. AppDependencies doesn't pass them yet (live lock and transfer are stubs): the
  shell rework must, and Browser's build units may make them required once tests are updated. The drag-out rule
  still also checks the old `lockMode`/`pendingMigration` (existing tests depend on it); Browser's build drops them.
  VaultPickerViewModel is `init(lock:isMove:)`. Vaults/CreateVault view models are `ObservableObject` (as the
  existing screens), with `onDone`/`onNeedsPro`/`onCreateVault` closures set by `LiveVaultsScreenFactory`.
- 2026-11-10 (prototype, Settings): SecuritySettingsViewController is `init(lock:store:pro:onRestore:)` (no migrator);
  Settings reads `lock.current` once when made; `onVaultDeleted` closes Settings unless the shell already has.
  `makeMigration` is live (`waitsForNewRun: true`; the shell calls `encryptLeftovers(in:)` after showing it). New
  identifiers (2026-11-03 naming): `settings.biometricSwitch`, `settings.biometricRow`, `settings.deleteVaultRow`,
  `settings.deleteVaultPasswordField`; nav title stays "Security". Kept for existing tests, for Settings' build units to
  change to the spec (comments mark each): paywall copy "Store more than 100 files." (also J9 line 58); "Decrypting
  Files" for `kind: .decrypt` and the `kind:` parameter (a Preferences `MigrationKind`; drop it); "These files couldn't
  be migrated: a, b"; the no-names failure "The migration couldn't finish. Retry, or Skip to stop for now.". Tests:
  MigrationViewModelTests decryptTitle/failureText/singleFailureText/failureWithoutNames,
  SettingsMigrationViewControllerTests decryptTitle/failureAlert, PaywallViewModelTests.strings,
  PaywallViewControllerTests.staticContent.
- 2026-11-10 (prototype review): the human wants a lock screen back (opening straight into the unencrypted vault could
  confuse users). Decided: it shows at launch and on every return from the background (any vault); the browser's Vaults
  button becomes a Lock button and the Vaults sheet goes (the lock screen is the Vaults screen, full-screen, with "Open
  Unencrypted Vault" instead of Cancel / Close Vault); Face ID stays a tapped button (no automatic prompt, for duress).
  Delete This Vault ends on the lock screen (orchestrator's call, for the same consistency). Memo revised; contract
  changes in LockScreens (`lock()`, `makeLockScreen(onDone:onNeedsPro:)`) wait for the human's approval.
  Approved by the human 2026-11-10; `status feature plan` rerun.
- 2026-11-10 (prototype, lock screen): VaultsViewModel loses Close Vault / Cancel / `observeCurrentVault`, gains
  `unencryptedTapped()` (ignored while busy; `close()` then `onDone`); the view is full-screen (icon `koalaT`, name,
  centred column ≤ 420 pt, keyboard-safe, nav bar hidden except on Create Vault). Browser: `Route.lock`,
  `showsLockButton`, `lockTapped()`, button `lockButton` calling `BrowserVaultServices.onLock`. `AppLockCoordinator.lock()`
  is still a stub and nothing presents the lock screen yet (LockScreens' build units and the shell rework).
  Prototype flow approved by the human 2026-11-10 (ui-approved).
- 2026-11-10 (build): `gates --after-merge` can't skip on the feature branch yet (no earlier `--all` pass there: the
  skeleton passed with `--skip-coverage`), so it runs `--all`. That run fails only on coverage of modules not yet built
  in this feature (skeleton/prototype code), which each module's own coverage triage clears; build, tests, lint and api
  pass. The `gates --all` after the last module must be fully green.
- 2026-11-10 (build, stage 5 done): all modules merged; `gates --after-merge` after Browser ran green (coverage clean everywhere).
  Next, before verify: the shell rework (memo § App shell, "Shell changes"), by a code-writer brief naming the shell files.
  Interim shell edits made during the build, which that brief must replace:
  - `AppLockCoordinator(lock:screens:presenter:onNeedsPro: { _ in })`: the `onNeedsPro` placeholder must present the paywall.
  - `BrowserVaultServices(lock:transfer: LiveVaultTransfer(pro:), onLock: coordinator.lock())`.
  - Remove the leftover "signature updated" / "Interim" markers in AppDependencies.swift (reviewer, Browser unit 2).
  Open questions for the human (raised in LockScreens unit 3 review, not in the spec):
  1. Password fields use `textContentType` `.password` (lock screen) and `.newPassword` (Create Vault), so iOS offers to save
     vault passwords in iCloud Keychain / suggest strong ones. For a duress vault a saved copy may be unwanted.
  2. Create Vault keeps the typed password in its view model after success (errors clear it); clearing on success is
     hygiene but not in the spec.
  Accepted minors: a late transfer-progress report could show against the next transfer (tiny window).
- 2026-11-11 (build, fix-up): both open questions answered by the human (memo decisions log 2026-11-11). LockScreens unit 3
  reopened: lock screen and Create Vault password fields set `textContentType = nil`; Create Vault clears both password
  fields on success. Browser unit 3 reopened for the same change on the vault picker's password field. Both merged (via
  `fix/password-fields` and `fix/vault-picker-password`; the module branches had already merged and share their names
  with the module tags, which stay on the first merges). `gates --all` green at ee9b6cf.
  Reviewer note (not in the spec, for the human): a secure text field with no content type can still show the keyboard's
  Passwords shortcut, and iOS may still offer to save after a submit (the Create Vault name + password pair looks like a
  login form). Only a non-password content type blocks this for sure, which would be a spec change. Check on a device
  during verify.
  Next, before verify: the shell rework (above).
- 2026-11-11 (verify, shell rework): the UI-test writer found the shell rework hadn't run (`status next` jumped to verify);
  done before the journey tests: test-writer (PostUnlockMaintenanceTests, d013e45), code-writer (7c1f586,
  `gates --all --skip-coverage` green), reviewer pass. Accepted minors: `VaultDeletionRelay` wraps `VaultLocking` in the
  shell to call `lock()` after Delete This Vault, because `SettingsFactory` has no vault-deleted callback (candidate small
  contract change later: `onVaultDeleted` on `SettingsFactory`); the old vault's thumbnails stay in memory for one
  main-actor hop after Lock/background (the key and temp files are wiped at once, the lock screen covers the window);
  a transfer target's cipher object (no key) is held until the next vault change. Shell structure added:
  `VaultRootViewController` (root container), `LockScreenTracker`, `VaultCiphers`, `NoKeyStore`.
  Journey tests must drop `UITEST_PENDING_MIGRATION` / `UITEST_PLAINTEXT_INDEX` (J8). Pro in journey tests: buy through the
  StoreKit test session, as J9 does (no Pro seed in the spec).
- 2026-11-11 (verify, Create Vault autofill): journey tests showed iOS Strong Password autofill taking over Create Vault's
  password fields (vault got a password nobody typed). Scratch experiment (branch
  `scratch/create-vault-autofill-experiment`, kept for reference): name field without content type didn't help; the
  password in an alert did. Human approved the alert (memo e1517d9); LockScreens unit 3 reopened and merged via
  `fix/create-vault-alert`. Journey-test helper `fillCreateVaultForm` must type into the alert next.
- 2026-11-11 (verify, feature review): reviewer pass, no blockers; duress model, key wiping, upgrade crash-safety,
  transfer safety, identifiers, Dynamic Type, dark mode checked. Minors for the human: wrong-password timing reveals
  zero vs some encrypted vaults (timing of the password search is out of scope per Agreed scope); `.vault_info` written
  without `.completeFileProtection` (sealed, but unlike other store files; not in the spec); vault listing + Keychain
  reads on the main actor when the lock screen is made (fast for few vaults); Preferences `hasCompletedSetup` /
  `PendingMigration.Kind.decrypt` unused outside the upgrade/seeds (contract clean-up later); the two shell minors
  already recorded (thumbnail hop, VaultCiphers).
- 2026-11-11 (verify, RESUME HERE): all 12 journeys pass in one full `--app-ui-tests` run; feature review done. Waiting on
  the human, who will test later. On resume, FIRST discuss and settle these four review minors with the human (they
  asked for them to be discussed and done after a fresh session), THEN the device test and acceptance:
  1. Wrong-password timing reveals zero vs some encrypted vaults (VaultLock `LiveVaultLock.findVault`: no PBKDF2 runs
     when there are no vaults). Proposed: dummy derivation when empty (needs a memo line; Agreed scope currently puts
     password-search timing out of scope), or queue with 2.
  2. `.vault_info` written without `.completeFileProtection` (VaultLock `VaultCatalog.writeName`). Proposed: add it
     (memo line + VaultLock unit reopen), possibly together with 1.
  3. Preferences contract leftovers: `hasCompletedSetup` (only written by UI-test seeding), `PendingMigration.Kind.decrypt`
     / `targetLockMode` (only read by the upgrade). Removing = contract change (needs approval). Proposed: queue a clean-up.
  4. Lock screen lists `Vaults/` + Keychain reads on the main actor each time it's made (`LiveVaultLock.hasBiometricVault`,
     `canCreateVault`; `VaultsViewModel.init`). Proposed: accept.
  Also kept from the shell review: `VaultDeletionRelay` could become `onVaultDeleted` on `SettingsFactory` later.
  Then: device test (all journeys; watch for iOS offering to save/suggest passwords, and Face ID), triage, acceptance.
- 2026-11-11 (verify, review minors settled): the human decided: 1 and 2 fixed now (VaultLock units 1 and 2 reopened:
  decoy derivation when no vault to try, `.vault_info` complete file protection); 3 removed now (Preferences contract
  change approved: `hasCompletedSetup` out, `PendingMigration`/`MigrationKind` → `hasPendingEncryptMigration` +
  `clearPendingMigration()`; Preferences unit 1 reopened, VaultUpgrade and the shell follow); 4 accepted. Order:
  contract + mock (skeleton-builder, feature mode), Preferences unit 1, VaultLock unit 2, VaultLock unit 1, shell, then
  `gates --all`, journeys, device test.
- 2026-11-11 (verify, review minors done): merged via `fix/review-minors`; `gates --all` green. Preferences unit 1, VaultLock
  units 1-2 done again. `.vault_info` protection has no test (simulator doesn't record protection classes; decided by the
  human): confirm on the device test. Accepted review minors: decoy blob creation is tried once (a failure, practically
  impossible with the in-memory Keychain, is logged and later no-vault searches are fast); no test that the decoy's
  random password differs per lock; no test of a lock change during the decoy wait (the code checks it).
  Next: journey tests (`gates --app-ui-tests`), then the device test.
- 2026-11-11 (verify, RESUME HERE): after the review-minors merge, all 12 journeys pass (`--app-ui-tests`, ~53 min).
  Next: the human's device test (all journeys; iOS offering to save/suggest passwords; Face ID; `.vault_info` file
  protection can't be seen without tools, so it rests on the code review), triage, acceptance.
- 2026-11-12 (verify, device test): the human found folders empty for 15-20 s after opening an encrypted vault. Cause (read
  from the code, not profiled): `afterOpening` runs `sweepOrphans` and `hasUnencryptedFiles` on the `LiveVaultStore` actor,
  each a whole-vault walk in one synchronous step (the second reads every file's SVC5 header), so `contents` waits. On
  `main` only the sweep ran after unlock; the unencrypted-files check was gated by the pending-migration flag. Human chose:
  fix now, no contract change (memo VaultStore spec bullet + decisions log). VaultStore unit 2 reopened on
  `fix/open-vault-housekeeping`. Then gates, journeys, device retest, acceptance.
- 2026-11-12 (verify, RESUME HERE): open-vault housekeeping fix merged (74036af): `sweepOrphans` / `hasUnencryptedFiles`
  step one folder at a time, yield between folders, stop on cancel/lock, check stops at first plaintext file. VaultStore
  unit 2 done (attempts 2: an over-strict test assertion, then review minors), coverage clean, `gates --after-merge` green,
  all 12 journeys pass (`--app-ui-tests`). Next: the human retests on the device (folders show at once after opening a
  large vault; then the rest of the device test), triage, acceptance.
- 2026-11-12 (verify, device retest): very large folders still take seconds to show. Timing on the simulator (branch
  `scratch/large-folder-timing`, kept for reference): listing 9,000 files ~1.2 s, mostly per-item path resolution,
  per-file stat and sort; the check's big-folder step ~3 s. Human chose: speed up first (VaultStore units 1 and 2,
  no contract change: listing per-folder work once, prefetched attributes, precomputed sort keys; housekeeping
  breadth-first, check in batches of 256). Files appearing as they load only if still needed. Branch `fix/large-folders`.
- 2026-11-12 (verify, large folders): merged via `fix/large-folders` (ff7520c). VaultStore unit 1: listing per-folder
  work once, prefetched attributes, NSString sort keys; 9,000-file listing 1,225 → ~413 ms (simulator, real cipher).
  Unit 2: both housekeeping walks breadth-first; the check in batches of 256 per step. Reviews pass; coverage clean;
  `gates --after-merge` green. Next: journeys, then the human's device retest.
- 2026-11-12 (verify, RESUME HERE): all 12 journeys pass after the large-folder speed-up. Next: the human's device retest
  (very large folders show quickly; rest of the device-test checklist), triage, acceptance. If big folders are still too
  slow: "files appear as they load" (VaultStore contract + Browser change), as decided.
- 2026-11-12 (verify, device retest): large folders now fast; retest passed. The human's design notes
  (`docs/DesignNotes.txt.rtf`) folded in before acceptance (human's choice): rounded lock screen logo (LockScreens
  unit 3), folder name at the left after the back button and a "< 🔒" Lock button after the gear (Browser unit 2),
  Delete This Vault in its own last section and a one-vault Face ID note (Settings units 1 and 2). Dark mode
  dropped (already follows the phone). No contract change. Branch `fix/design-tweaks`.
- 2026-11-12 (verify, device test): the human reports importing very large files crashes (memory). First look
  (orchestrator, read-only): encryption (1 MB SVC5 chunks), the duplicate hash (1 MB reads), the photo picker copy
  (file to file) and encrypted thumbnails (decrypt to temp) all stream already, so the cause is not yet known.
  Waiting on details (source, file type and size, vault kind, crash log). Fix now (bug) once diagnosed.
  Details (human): Files app, one folder of 9,000+ JPGs; many import, then the crash. Diagnosis (orchestrator, code
  read): per file, `isDuplicate` → `findItem` builds the destination's whole listing (LiveVaultStore.swift:66) and
  `insertFile` reads the whole index, lists the folder for free names, then re-encrypts and rewrites the whole index
  (VaultFileOperations.swift:60). Work and temporary Foundation objects per file grow with the folder; the import is one
  long async task, so autoreleased objects aren't drained and memory climbs until iOS ends the app. Fix scope: human to choose.
  Human approved (2026-11-12): fix memory and batch. `VaultStoring.addFiles(_:to:)` + `VaultFileToAdd` (contract change,
  listed in the memo), store operations release memory, `findItem` looks up one name; Import lists the destination
  once and adds in batches of 64. VaultStore unit 1 and Import unit 1 reopened, after the design tweaks. Move/Copy to
  Vault batching left as a known issue. Order: the contract change (skeleton-builder, MODE: feature) first, then
  VaultStore, then Import.
- 2026-11-12 (verify): design tweaks and the large-folder import fix merged into the feature branch; `gates --all`
  and all 12 journeys pass. Next: the human retests on the device (the three design tweaks; importing the 9,000-JPG
  folder from Files), then acceptance.
- 2026-11-13 (device retest): the "< 🔒" Lock button was still in the bar's button group beside the gear. The human
  chose: gear stays at the far left; "< 🔒" leaves the group, has no button background, and sits right before the
  vault's name. Browser unit 2 reopened (view only, no contract change); then the human retests again.
- 2026-11-13 (verify): lock button placement merged into the feature branch; `gates --all` and all journeys pass.
  Next: the human retests on the device ("[⚙]  < 🔒 Vault name" on a vault's root; check the gap between gear and
  lock), then acceptance.
- 2026-11-13 (device retest 2): the Lock button still sat in the navigation bar. The human clarified: a back arrow
  left of the folder's name, on the name's line under the bar ("<" up one folder; "< 🔒" from a vault's root to the
  lock screen); no back or Lock button in the bar; gear stays on the root's bar. Browser unit 2 reopened again;
  journeys that use the bar's back button are updated in verify.
- 2026-11-13 (verify): title row merged (back arrow beside the folder name; no browser title, back or Lock button
  in the bar); journeys updated; `gates --all` and all 12 journeys pass. Next: the human retests on the device, then
  acceptance.
- 2026-11-13 (device retest 3): everything checks out: title row with the arrow beside the name (root and
  subfolders), swipe-back, select mode, rounded logo, Settings layout, 9,000-JPG import. New report (human): sometimes
  after a folder is moved or something is deleted the folder view doesn't refresh. Read-only reviews of every path
  that moves or deletes vault items, checking each refreshes the affected browser views, run before acceptance.
- 2026-11-13 (verify): refresh fix merged. Review of every move/delete/copy/rename/transfer path: each reloads its own
  grid, but a browser popped back to (or under a closed viewer) never reloaded. Fix: a browser reloads quietly every
  time it reappears (Browser unit 2, no contract change). `gates --all` and all 12 journeys pass. Next: the human
  retests on the device (move/delete from a subfolder, then go back), then acceptance.
- 2026-11-13 (device retest 3, Recently Deleted): rows stay after Restore/Delete until the list reloads, slowly, with
  thousands of trashed items (minutes to open; a stale row's action fails "no longer exists"; a listing error shows
  an empty trash). Not reproducible on simulators with a few items (new journeys added, pass on iOS 18.6 and 26.5).
  Diagnosis (review): every trash listing and restore opened, copied and checked each trashed file; the unreadable-
  trash and housekeeping trash checks were single long steps; bulk Delete rewrote the trash index per item. The
  human chose the full fix with batch delete (contract change: `moveToTrash(_ items:)`) and "missing file on
  Restore/Delete just removes the row". Order: contract (skeleton-builder, MODE: feature), then VaultStore, Settings,
  Browser; then journeys and the human's device retest.
- 2026-11-13 (large trash, RESUME HERE): on branch `fix/large-trash`. Done: batch `moveToTrash(_ items:)` contract
  (snapshot written), VaultStore unit 2 (stored-flag listing, own-file restore probe, missing-file handling, batched
  trash checks; review pass), Settings unit 1 (Recently Deleted rows update at once, not-found silent, errors never
  shown as empty; review pass). Next: Browser unit 1 (bulk Delete uses the batch call, 256 per call): test-writer,
  code-writer, gates, review; then coverage triage and full gates for VaultStore, Settings and Browser; merge into
  the feature branch; `gates --after-merge`; journeys (`gates --app-ui-tests`, ~45 min, run in background); the
  human's device retest (Recently Deleted with thousands of items; bulk Delete), then acceptance. Paused for the
  weekly usage limit (95%).
- 2026-11-16 (verify, large trash merged): `fix/large-trash` merged (549e415). Browser unit 1: bulk Delete uses the batch
  `moveToTrash(_:)`, 256 per call (review pass; the context-menu Delete is a one-item batch). Coverage triage: VaultStore
  tests added for four missed blocks; Browser: the human chose to keep "a cancelled bulk Move/Copy is not a failure" and
  spec it (memo + test). Full gates for VaultStore, Settings, Browser and `gates --after-merge` pass. Next: journeys
  (`gates --app-ui-tests`), then the human's device retest (Recently Deleted with thousands of items; bulk Delete), then
  acceptance.
- 2026-11-16 (verify, RESUME HERE): after the large-trash merge, all journeys pass (`--app-ui-tests`). Next: the human's
  device retest (Recently Deleted with thousands of items: opens quickly, Restore/Delete removes the row at once; bulk
  Delete of many items from select mode), then acceptance. The human's new app icon / logo image (koalatvault.png) is
  committed on the feature branch (47ea62d).
- 2026-11-16 (device test notes, RESUME HERE): the human's `docs/Notes.rtf`. Decided: one folder size (the larger,
  pre-thumbnail one; thumbnail requested at the icon area's size); selection no longer reloads the grid (no flicker);
  no long-press menu in select mode; `FileIconMapping.swift` deleted (SharedUI unit 1); right-side bar buttons become a
  named menu (Select stays a button); select mode's actions, Move/Copy to Vault included, in a ☰ menu ("To Vault" never
  appeared on the phone). Branch `fix/browser-notes`; SharedUI unit 1 then Browser unit 2 reopened; journeys that tap
  the old bar buttons are updated in verify. Large-trash device retest result not yet reported by the human.
- 2026-11-16 (verify, RESUME HERE): device-test notes merged (`fix/browser-notes`, 911b5c2): SharedUI unit 1 (empty file
  deleted) and Browser unit 2 (bar menus, select-mode ☰ menu with Move/Copy to Vault, no long press in select mode,
  no reload on selection, one folder size) done; review minors logged (unbounded thumbnail cache now holds larger
  folder thumbnails; stale width after rotation; FileBrowserViewController at 900 lines). Full gates, after-merge
  gates and all journeys (123 UI tests) pass. Next: the human's device retest (these notes + the large-trash retest
  still unreported), then acceptance.
