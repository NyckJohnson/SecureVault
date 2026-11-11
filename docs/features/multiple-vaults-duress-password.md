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
  with device-level access); timing of the password search; renaming a vault; lockout, password strength, password
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
