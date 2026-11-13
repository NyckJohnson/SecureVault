# KoalaTVault outline

<!-- The behavior spec describes what the app does; adopted 2026-11-09 (the adoption's history is in the decisions log). -->

## Purpose
KoalaTVault is an offline, encrypted file store for iPhone and iPad. The user keeps files (photos, videos, documents) in
a private vault on the device, browses them in folders, views images and videos, edits rich-text notes, and moves files in
and out. There is always one unencrypted vault, which the app opens to; the user can add encrypted vaults, each with its
own name and password (file names and contents encrypted on disk, SVC5 format), opened by typing that password (one may
also open with Face ID / Touch ID). Any password opens only its own vault, so a second vault doubles as a duress (decoy)
vault. A one-time "Unlock Pro" purchase lifts the free limit of 100 files per vault and allows more than one encrypted
vault. The app is accepted by App Store Connect (1.2, build 4) but not yet released.

## User journeys
1. **First launch** — a new user opens the app. The lock screen shows (journey 2): password field, Open, "Open
   Unencrypted Vault" and "Create New Vault"; no setup wizard. "Open Unencrypted Vault" → the browser shows the
   unencrypted vault's root ("KoalaTVault"), empty. Ends when the browser shows. (Changed by feature
   multiple-vaults-duress-password: the setup wizard is gone; journey 10 creates an encrypted vault.)
2. **Open a vault** — a user wants into a vault. The lock screen shows at launch, on every return from the background,
   and after the Lock button on any vault's root (which closes the open vault): password field, Open, "Use <Face
   ID|Touch ID>" (only when a vault has Face ID turned on and biometrics are available; tapped, never automatic), "Open
   Unencrypted Vault" and "Create New Vault"; no Cancel. A password opens the vault it belongs to: the lock screen goes
   and the browser shows that vault's root, titled with its name. Face ID opens the vault that has it. "Open Unencrypted
   Vault" shows the unencrypted vault's root. Ends when the browser shows the vault. Nothing on any screen says how many
   encrypted vaults exist.
   - Failure path: a password that opens no vault → "Incorrect password", field cleared; no lockout, no delay, no wipe.
   - Failure path: Face ID cancel → nothing shown; lockout → "Too many attempts. Use your password."; not enrolled →
     "Face ID is not set up."; no passcode → "Set a device passcode to use Face ID."; enrolment changed or item missing →
     "Face ID changed. Use your password." and Face ID is turned off for that vault (the button goes); other failures →
     "Biometric authentication failed". The password field always stays usable.
   - Lock (the browser's root, any vault) → the open vault closes (an encrypted vault's key and plaintext temp files
     wiped) and the lock screen shows.
   - Backgrounding with an encrypted vault open shows the privacy cover at once; entering the background closes the
     vault (key and its plaintext temp files wiped, anything presented over the browser dismissed) and puts the lock
     screen up, so the app switcher and the return both show the lock screen. In the unencrypted vault, entering the
     background also puts the lock screen up.
   - Opening a vault that has files a 1.2 lock change left unencrypted (journey 12) shows the Migration screen
     ("Encrypting Files") until they are encrypted (journey 8's failure paths apply).
3. **Browse** — the user wants to find and organise files. The browser shows a grid of folders and files (thumbnails,
   name, size), folders first, sorted by the global sort option. Tap a folder → push its browser; back returns. Bar
   buttons: New Folder, New Document, Import, Sort, Select; the settings gear and the Lock button (journey 2) only on the root. The folder's name sits at the left of the bar, on the same line as and right after the back button (not centred); on a vault's root the Lock button looks like a back button ("< 🔒"): it sits outside the gear's button bubble, with no bubble of its own, right before the vault's name, and the gear stays at the far left (design tweaks, device test 2026-11-12; Lock moved out of the bar's button group 2026-11-13). Sort sheet: Name, Type,
   Date Modified; tapping the current option flips ↑/↓. Long press: Export, Move, Copy, Rename, Delete. Select mode: tap
   to toggle, "N Selected", bulk Delete, Move, Export, Copy, Cancel. Move opens the folder picker at the root ("Move
   Here", "Cancel"); Copy always copies into the current folder with " 1", " 2" names; drag a cell onto a folder cell to
   move it. Ends when the files are where the user wants them.
   - Failure path: empty folder shows "No files yet"; empty names are ignored; a name with "/" or starting with "." → "Names can't contain / or start with .";
     a move into the item's own folder does nothing; the picker doesn't offer the folders being moved or their subfolders
     (the store still refuses such a move with "A folder can't be moved into itself"); any failed operation shows its error (bulk operations report how many failed).
4. **Import** — the user wants to add files. Import → sheet "Choose Files", "Choose Folder", "Choose Photos", "Cancel".
   Files/Folder: document picker, multi-select → progress "Importing..." → grid reloads. Photos: photo picker (images and
   videos, unlimited) → "Importing Photos..." → if any failed, "N imported, M failed" → then iOS asks to delete the
   imported originals from the photo library. Same name and same content is skipped; same name, different content gets
   " 1". Ends when the grid shows the new files.
   - Failure path: free tier and the import would pass 100 files (all non-hidden files in the open vault, subfolders
     included, trash excluded; each vault has its own 100) → nothing is imported and the paywall opens after the picker
     closes.
   - Failure path: photo picker Cancel closes the picker and imports nothing.
   - Failure path: a file that fails mid-import → earlier files stay imported, the error is shown.
5. **View / edit** — the user wants to look at or edit a file. Tap a non-`.rtf` file → full-screen viewer paging through
   the folder's files: images zoom 1x-5x (pinch, double-tap); videos stream with play/pause, ±10 s, scrubber, buffering
   spinner, bars fade after 3 s while playing; other kinds show in QuickLook. Tap toggles the bars; X closes; Share
   exports the current file. Tap an `.rtf` file (or New Document) → full-screen rich-text editor with a toolbar (bold,
   italic, underline, size ±2 pt (min 8), align left/centre/right), autosave 1 s after typing and on Done. Ends when the
   user closes the viewer or editor.
   - Failure path: a file that can't be decrypted shows "This file can't be opened." on its page.
   - Failure path: an editor load failure shows the error and the editor is read-only, so the original is never
     overwritten; a save failure shows the error.
6. **Delete / restore** — the user wants to remove a file and maybe get it back. Delete (context menu or bulk, with a
   confirm) moves items to Recently Deleted (Settings → Storage → Recently Deleted): each row shows "Deletes in N days";
   tap → Restore / Delete Permanently / Cancel; "Empty Trash" with a confirm. Each vault has its own Recently Deleted.
   Items older than 30 days are purged automatically when the vault is opened (the unencrypted vault: at launch and on
   each return to the foreground). Ends when the item is restored or gone.
   - Failure path: restoring into a folder that has the same name gives " 1"; restoring when the original folder is gone
     recreates it; a failure shows its error.
   - Failure path: deleted items that can never be read (sealed with a key the vault no longer has, e.g. by an older
     version that left the trash out of a lock change) → on opening Recently Deleted, "Some Deleted Items Can't Be Read"
     / "They were encrypted with a key this vault no longer has, so they can never be restored or opened. Clear them
     now?" with Clear / Not Now; Clear removes only those items and reloads the list.
7. **Export / share** — the user wants a file outside the vault. Export (context menu, bulk, viewer share) → sheet "Save
   to Files", "Save to Camera Roll" (only when the selection has images or videos), "Cancel". Save to Files → "Exporting..."
   → document picker (copies); decrypted copies are removed when the picker closes. Save to Camera Roll → "N saved, M
   failed". Ends when the copy is saved.
   - Failure path: a failure part-way removes every decrypted copy made so far and shows the error; photo access denied →
     "Allow KoalaTVault to add photos in Settings.".
   - Folders are exported whole: an encrypted folder becomes a decrypted copy of its whole tree with the original names
     (no index files, no UUID names). Encrypted items can't be dragged out to other apps (drags stay inside the app).
8. **Manage a vault** — the user wants to change an encrypted vault. In that vault, Settings ("Settings") → Vault
   section: "Change Password", "Use <Face ID|Touch ID>" (a switch; hidden without biometrics) with the note "Note: only
   one vault can use <Face ID|Touch ID>." under it (shown with the switch); "Delete This Vault" is in its own section at
   the bottom of Settings, after Storage (design tweaks, device test 2026-11-12). The
   unencrypted vault's Settings has no Vault section and no Delete This Vault. Change Password → current, new, confirm → "Password changed
   successfully". Turning the switch on gives this vault Face ID and silently takes it from any other vault; off removes
   it. Delete This Vault → "Delete This Vault?" / "Everything in "<name>" will be erased. This can't be undone. Enter the
   vault's password to confirm." with a password field, Delete and Cancel → the vault (files, trash, key, Face ID) is
   erased and the lock screen shows. Ends when the change is in force.
   - Failure path: empty new password → "Password cannot be empty"; mismatch → "Passwords do not match"; wrong current
     → "Current password is incorrect"; a new password another vault uses → "Choose a different password."
   - Failure path: wrong password to delete → "Incorrect password", nothing erased.
   - Failure path: Face ID can't be turned on (no biometrics, Keychain error) → the error, and the switch stays off.
   - Migration screen (opening a vault with leftover unencrypted files, journey 2): "Encrypting Files", a progress bar
     and "N% complete"; some files fail → "Some Files Failed" listing them, Retry (failed files only) or Skip (they stay
     unencrypted and are offered again the next time the vault opens); deleted items that can never be read → "Some
     Deleted Items Can't Be Read" / "They were encrypted with a key this vault no longer has, so they can never be
     restored or opened. Clear them to continue." with Clear and Continue / Skip; backgrounding closes the vault and
     stops it (the rest is done the next time the vault opens); Retry after a failure that happens again shows it again.
   (Before feature multiple-vaults-duress-password this journey was "Change lock mode": No Lock / Password / Password +
   Face ID with encrypt and decrypt migrations of the whole vault; that is gone.)
9. **Paywall** — a free user wants more than 100 files in a vault or a second encrypted vault. Settings "Upgrade to
   Pro", the import limit, the transfer limit (journey 11) or Create New Vault with one encrypted vault already there
   opens the paywall ("Unlock Pro", "Store more than 100 files in a vault and keep more than one encrypted vault.", price,
   Unlock, Restore Purchases, X). Unlock → App Store purchase → paywall
   closes, Settings shows "Pro Unlocked". Ends when Pro is unlocked.
   - Failure path: cancel → paywall stays; pending → "Purchase pending approval."; restore with nothing → "No previous
     purchase found to restore."; price unavailable → "Price unavailable" and Unlock still works.
10. **Create a vault** — the user wants a new encrypted vault. Lock screen → "Create New Vault" → Create Vault screen
   (Name, Create) → Create opens the "Set Password" alert ("Choose a password for this vault.", Password, Confirm
   Password, Cancel, Create) → "Creating Vault…" → both screens go and the browser shows the new,
   empty vault's root, titled with its name. Ends when the new vault is open.
   - Failure path: free tier with one encrypted vault already → tapping "Create New Vault" opens the paywall instead (this
     tells whoever taps it that a vault exists; accepted, decision 2026-11-10); after unlocking, the user taps it again.
   - Failure path: name empty after trimming → "Enter a name for the vault" (no alert); after the alert's Create, errors
     show on the Create Vault screen and Create asks again: empty password → "Password cannot be empty";
     mismatch → "Passwords do not match"; a password another vault already uses → "Choose a different password."; a
     Keychain or disk failure shows the error and leaves no half-made vault.
11. **Move or copy to another vault** — the user wants files in a different vault. Long press → "Move to Vault…" or "Copy
   to Vault…"; Select mode → "To Vault" → "Move to Vault…" / "Copy to Vault…" / Cancel. The vault picker shows
   "Unencrypted Vault" (only from an encrypted vault), a password field with "Use Vault", and Cancel. The items (folders
   with everything in them) go to the target vault's root, decrypted or encrypted on the way, with "Moving…" /
   "Copying…" progress; names that clash get " 1". Move removes the originals (not to Recently Deleted). Ends when the
   items are in the target vault (the browser stays in the current vault).
   - Failure path: a password that opens no vault → "Incorrect password"; the current vault's own password → "These
     items are already in this vault."
   - Failure path: free tier and the target would pass 100 files → nothing is transferred and the paywall opens.
   - Failure path: an item that fails → the others still go; "N of M failed". A moved item is never lost: its original
     is removed only after its copy is complete, so a failure or a kill part-way leaves it in the source (or, at worst,
     in both vaults).
   - Backgrounding stops the transfer (the vault closes); items already done stay done.
12. **Upgrade from one vault** (once, at the first launch of this version; 1.2 has one vault with a lock mode) —
   No Lock → the files are the unencrypted vault, unchanged. A lock (Password or Password + Face ID, or an unfinished
   change to one) → the whole vault (files, folders, trash, indexes) becomes an encrypted vault named "My Vault" with the
   same password (Face ID kept for it in Password + Face ID), and the unencrypted vault starts empty. Ends when the
   lock screen shows.
   - The upgrade is safe to interrupt: a kill part-way finishes it at the next launch; nothing is copied, only moved.
   - Files the old app left unencrypted in a locked vault (a skipped or unfinished lock change) are encrypted when "My
     Vault" is next opened (journey 2).
   - An unfinished lock change with no password on the device (an encrypt that never got its key) is dropped and the
     files are the unencrypted vault.
   - A failure (disk or Keychain) shows "Couldn't finish updating your vaults. Restart the app to try again." over the
     lock screen; the next launch carries on.

## Screens and navigation
- **Lock screen** (the Vaults screen; feature multiple-vaults-duress-password, revised at the prototype): open a vault by
  password or Face ID, open the unencrypted vault, create one. UI: UIKit. Full-screen navigation controller over the
  window's root, shown by the app lock coordinator at launch, on entering the background, and from the browser's Lock
  button or a deleted vault. Serves 1, 2, 8, 10, 12. A privacy cover (no screen of its own) hides content while the app
  is inactive with an encrypted vault open.
- **Create Vault**: name on the screen, password and confirmation in a "Set Password" alert. UI: UIKit. Pushed in the lock screen's navigation. Serves 10.
- **File browser**: the open vault's grid; root of the navigation stack, one instance per folder; replaced as a whole
  when another vault opens or the vault closes. UI: UIKit. Serves 1, 3, 4, 6, 7, 11.
- **Vault picker**: choose the target of "Move/Copy to Vault…". UI: UIKit. Form sheet from the browser. Serves 11.
- **Folder picker**: choose a move target. UI: UIKit. Form sheet from the browser. Serves 3.
- **File viewer** (with file pages): view images, video, QuickLook kinds. UI: UIKit. Full-screen from the browser. Serves 5, 7.
- **Text editor**: edit `.rtf`. UI: UIKit. Full-screen nav from the browser (or a viewer page). Serves 5.
- **Security settings**: Pro, the open vault (password, Face ID, delete), storage. UI: UIKit. Form-sheet nav from the
  browser's gear. Serves 6, 8, 9.
- **Migration**: encrypting a vault's leftover unencrypted files. UI: UIKit. Full-screen, presented by the app shell when
  such a vault opens. Serves 2, 8, 12.
- **Recently Deleted**: the trash. UI: UIKit. Pushed from Settings. Serves 6.
- **Paywall**: Unlock Pro. UI: UIKit. Form sheet from Settings, an import, a transfer or Create New Vault. Serves 9, 10, 11.
- Removed by feature multiple-vaults-duress-password: the setup wizard and the old password lock screen (the lock screen
  above replaces it).
- Import and export sheets, pickers and share sheets are presented by the Import and Export modules' presenters over the
  calling screen.

## Constraints
- Stack: ios
- Minimum platform version: iOS 16.6; iPhone and iPad, all orientations. No `@Observable` (iOS 17); UIKit view models
  publish with Combine (`@Published`) or closures.
- UI technology: every adopted screen stays `UI: UIKit` (decision 2026-10-24 in the discussion notes).
- Offline: fully offline; the only network use is StoreKit.
- Accounts: none.
- Sync: none (iCloud backup is a queued feature). Documents (the vault) and the blob Keychain item are included in device
  backups today; that stays as is.
- Third-party: none. Apple frameworks only: CryptoKit, CommonCrypto, Security, LocalAuthentication, StoreKit 2,
  PhotosUI/Photos, QuickLook, AVFoundation.
- Compatibility: the SVC5 file format, the master-key blob v1 format, the Keychain items (service "com.KoalaTVault",
  accounts "com.KoalaTVault.masterKeyBlob" and "com.KoalaTVault.biometricMasterKey"), the `.vault_map` / `.trash_map` JSON
  shapes and the UserDefaults keys stay readable as they are. A 1.2 vault is upgraded once (journey 12) without
  rewriting any file or Keychain item: the upgraded vault keeps the old blob account.
- Tests never touch the real Keychain, UserDefaults.standard or the real Documents vault: every module takes its
  storage (Keychain access, UserDefaults suite, vault root URL) by injection; the composition root wires the real ones.
- The `-uiTesting` launch argument (replacing today's DEBUG `--uitesting`) starts the app with an empty vault in a
  temporary directory, an in-memory Keychain and a throwaway UserDefaults suite; `UITEST_SEED_FILE_NAME`,
  `UITEST_SEED_FILE_COUNT` and `UITEST_FAIL_MIGRATION_FILE` keep their meaning in that mode only (seed files go in the
  unencrypted vault). From feature multiple-vaults-duress-password: `UITEST_PASSWORD` seeds an empty encrypted vault
  named "Test Vault" with that password (the app still opens on the lock screen; journey tests open the vault they need through it,
  "Open Unencrypted Vault" for the unencrypted one); `UITEST_LEGACY_LOCK` =
  `password` / `biometric` seeds the 1.2 layout instead (the seed files, a blob for `UITEST_PASSWORD`, lock mode set, not
  upgraded; `hasCompletedSetup` is no longer seeded) so the upgrade runs at launch; `UITEST_PENDING_MIGRATION` and `UITEST_PLAINTEXT_INDEX` go.

## Out of scope
- New features: the queued backlog (below) is built after the adoption through `/feature`.
- Moving screens to SwiftUI: later `/feature` work.
- Changing the SVC5 format or the blob format; the Keychain layout changes only by adding one blob account per new
  vault and the Face ID vault marker.
- Hiding encrypted vaults from someone examining the device itself (vault folders and Keychain items can be counted
  with device-level access), and the time the password search takes (it grows with the number of vaults); renaming a
  vault (feature multiple-vaults-duress-password, out of scope).
- Repo-root `art samples/`, `previews/`, `vault_test_files/`: not app code; no module owns them.
- `API-Memo.md` and `REVIEW.md` stay as references; this memo and `docs/api/` replace them for new work.

## Later features
<!-- Already queued in the backlog (ios-pipeline status feature list). -->
- Minimum password strength: REVIEW.md S2.
- iCloud backup: back up the vault to iCloud.
- Password recovery: a way back in when the password (or its Keychain blob) is lost.
- Timed lockout for failed passwords.
- Encrypt folder names: folder names, sizes and structure are plaintext on disk today.
- Vault size in Settings: show the current total size of the vault (and file count) in the Storage section.
- Orphan sweep doesn't hold up the grid: after an unlock with a large vault, the grid's listing waits behind the sweep (one synchronous pass inside the VaultStore actor, OrphanSweep.swift); sweep per folder with yields — app review 2026-11-04.
- Remove `ThumbnailProviding.clearCache(for:)` from the Media contract: no caller (the cache key includes modification date and size) — contract change — app review 2026-11-04.
- Dark mode: the selection checkmark sits on a hard white disc (FileCell.swift `.white`); use a semantic colour — app review 2026-11-04 (may go with the accessibility feature).

## Data models
### VaultDirectory
| Field | Type | Notes |
| --- | --- | --- |
| name | String | display name; the root is "KoalaTVault" |
| diskURL | URL | the folder on disk |
| rootURL | URL | the vault root this folder belongs to |

### VaultItem
| Field | Type | Notes |
| --- | --- | --- |
| id | String | disk path relative to the vault root (trash items: `.trash/<uuid>`); stable across listings |
| name | String | display name (original name for encrypted files) |
| isDirectory | Bool | also true for folders in the trash |
| dateModified | Date | from the disk file |
| fileSize | Int? | nil for folders |
| deletedAt | Date? | trash items only |
| diskURL | URL | |
| rootURL | URL | |
| isEncrypted | Bool | the disk name is listed in the folder's index |
| kind | FileKind | computed from the name's extension |

### FileKind
`image` (jpg, jpeg, png, heic, gif, webp), `video` (mp4, mov, m4v), `audio` (mp3, m4a, wav, aac), `pdf`, `word` (doc,
docx), `spreadsheet` (xls, xlsx), `presentation` (ppt, pptx), `archive` (zip, rar, 7z), `text` (txt, rtf, md), `other`;
extension matching ignores case.

### TrashEntry (in `.trash_map`, keyed by the trash UUID)
| Field | Type | Notes |
| --- | --- | --- |
| originalDiskName | String | |
| originalDirectoryURL | String | written relative to the vault root; older absolute paths are re-based onto the current root by the part after the vault root's folder |
| deletedAt | Date | |
| isEncrypted | Bool | |
| originalName | String | |
| rootURL | String | kept for compatibility, not read |

### Pending migration (UserDefaults `pendingMigrationType` = "encrypt"/"decrypt", `pendingMigrationTargetLockMode`)
Left by 1.2 when a lock migration didn't finish. Since feature multiple-vaults-duress-password only the upgrade (journey 12)
reads it, and only whether it is an encrypt; then it clears both keys. Nothing writes it. (The `PendingMigration` /
`MigrationKind` types went in the minors clean-up, 2026-11-11.)

### On-disk and Keychain formats (kept as they are)
- **Unencrypted vault root**: the app's Documents folder; real subfolders with plaintext names; always plaintext mode.
  Hidden entries (`.vault_map`, `.trash`, `.trash_map`, `.vault_info`) are never listed.
- **Encrypted vaults** (feature multiple-vaults-duress-password): `Application Support/Vaults/<vaultID>/` is each
  encrypted vault's root (same layout as an encrypted root above), always encrypted mode. `vaultID` is a new UUID
  string, or `primary` for the vault the upgrade made. The vault's name is in `<root>/.vault_info`: JSON
  `{ "name": "…" }` sealed like an index (AES-256-GCM with the vault's key, AAD ".vault_info"); missing or unreadable →
  the name "My Vault" (written on the next open). A folder there with no blob in the Keychain is not a vault; an empty one (an
  interrupted creation) is removed at launch, a non-empty one is left alone.
- **Keychain per vault**: the blob of vault `primary` is the old account "com.KoalaTVault.masterKeyBlob"; any other
  vault's is "com.KoalaTVault.masterKeyBlob.<vaultID>" (same v1 format). The biometric item (account
  "com.KoalaTVault.biometricMasterKey", unchanged) holds the key of the one vault that has Face ID, named by the plain
  item "com.KoalaTVault.biometricVaultID" (UTF-8 vaultID, accessible when unlocked). No list of vaults is stored: the
  vaults are the folders under `Vaults/`.
- **Plaintext mode** (lock mode none): files keep their names; conflicts get " 1", " 2" before the extension.
- **Encrypted mode** (lock mode password or password + biometrics): each file is `<UUID>` with no extension; each folder's
  `.vault_map` is JSON `{ "<UUID>": { "originalName": "…" } }`, AES-256-GCM (nonce 12 | ciphertext | tag 16) with the
  master key and AAD ".vault_map" (reads also accept the folder-relative path and "" as AAD). `.trash/.trash_map` (inside the trash folder, where the legacy app keeps it) likewise with AAD
  ".trash_map" and `{ "<trashUUID>": TrashEntry }`.
- **SVC5 file**: header 32 bytes = "SVC5" | chunkSize UInt32 LE (1 MiB on write) | plaintext size UInt64 LE | fileID 16
  random bytes; body = per chunk [length UInt32 LE | AES-GCM combined]; per-file key HKDF-SHA256(master key, salt fileID,
  info "file-key", 32 bytes); chunk AAD = header + chunk index UInt64 LE; random nonce per chunk; chunkSize 1…16 MiB,
  total ≤ 2 TiB.
- **Master-key blob v1** (Keychain generic password, service "com.KoalaTVault", account "com.KoalaTVault.masterKeyBlob",
  accessible when unlocked): version 0x01 | iterations UInt32 LE (600,000 written; 100,000…10,000,000 accepted) | salt 32 |
  AES-GCM combined of the 32-byte master key with the 37-byte header as AAD; the wrapping key is PBKDF2-HMAC-SHA256 of the
  NFC-normalised UTF-8 password.
- **Biometric item** (account "com.KoalaTVault.biometricMasterKey", `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` +
  `.biometryCurrentSet`): the raw 32-byte master key. Legacy item account "com.KoalaTVault.password" is deleted on unlock.
- **UserDefaults**: `lockMode` ("none"; unknown → none), `sortOption` ("name"),
  `sortDirection` ("ascending"), `pendingMigrationType`, `pendingMigrationTargetLockMode`, `entitlement.isUnlocked`,
  `vaultsUpgraded` (false; feature multiple-vaults-duress-password). `lockMode` and the pending migration are read only
  by the upgrade. 1.2's `hasCompletedSetup` key is no longer read or written (left on disk as it is).

## Build order
1. VaultCrypto (depends on: none)
2. Preferences (depends on: none)
3. Entitlements (depends on: none)
4. VaultStore (depends on: VaultCrypto)
5. SharedUI (depends on: VaultStore)
6. VaultLock (depends on: VaultCrypto, Preferences, VaultStore, Entitlements)
7. LockMigration (depends on: VaultStore)
8. VaultTransfer (depends on: VaultStore, Entitlements)
9. Media (depends on: VaultStore, VaultCrypto, Preferences)
10. Import (depends on: VaultStore, Entitlements, SharedUI)
11. Export (depends on: VaultStore, SharedUI)
12. LockScreens (depends on: VaultLock, SharedUI)
13. Viewer (depends on: VaultStore, Media, Export, SharedUI)
14. Settings (depends on: VaultLock, LockMigration, VaultStore, Entitlements, SharedUI)
15. Browser (depends on: VaultStore, VaultLock, VaultTransfer, Preferences, Media, Import, Export, SharedUI, Viewer, Settings, LockScreens)

## Modules

### VaultCrypto
- Purpose: the master key and everything cryptographic: the in-memory key, the password-wrapped blob, the biometric key
  item, the SVC5 file format and small-data encryption for the indexes.
- Depends on: none
- Files: KeychainStore.swift, MasterKeyBlob.swift, LiveMasterKeyStore.swift | SVC5Format.swift, LiveFileCipher.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import CryptoKit
  import Foundation

  enum VaultCryptoError: Error, Equatable, Sendable {
      case noKeyLoaded, noMasterKeyBlob, masterKeyAlreadyExists, wrongPassword, emptyPassword
      case corruptBlob, invalidKeyData, encryptionFailed, decryptionFailed
      case biometricItemMissing, biometricCancelled, biometryLockedOut, biometryNotEnrolled, passcodeNotSet
      case keychain(OSStatus)
  }

  /// User-facing text; callers show `localizedDescription` in alerts.
  extension VaultCryptoError: LocalizedError { var errorDescription: String? { get } }

  enum KeychainAccessibility: Sendable { case whenUnlocked, biometryCurrentSetThisDeviceOnly }

  /// Seam over the Keychain (generic password items in one service); tests use an in-memory fake.
  protocol KeychainAccessing: Sendable {
      func read(account: String, prompt: String?) throws -> Data?
      func write(_ data: Data, account: String, accessibility: KeychainAccessibility) throws
      func delete(account: String) throws
  }

  protocol MasterKeyStoring: Sendable {
      var isKeyLoaded: Bool { get }
      func hasMasterKeyBlob() throws -> Bool
      func createMasterKey(password: String) throws
      func unlock(password: String) throws
      func rewrap(newPassword: String) throws
      func deleteMasterKeyBlob() throws
      func storeBiometricKey() throws
      func unlockWithBiometricKey(prompt: String) throws
      func deleteBiometricKey() throws
      func wipeKey()
      /// Runs `body` with the key captured once; a later wipe doesn't affect the running body.
      func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T
  }

  struct StreamInfo: Sendable, Equatable { let totalSize: Int; let chunkSize: Int }

  protocol FileCipher: Sendable {
      func encrypt(_ data: Data, context: String) throws -> Data
      func decrypt(_ data: Data, contexts: [String]) throws -> Data
      func encryptFile(at source: URL, to destination: URL) throws
      func decryptFile(at source: URL, to destination: URL) throws
      func streamInfo(of url: URL) throws -> StreamInfo
      func decryptChunk(_ index: Int, of url: URL, info: StreamInfo) throws -> Data
  }
  ```
- Behavior spec:
  - createMasterKey: no blob → random 256-bit key stored as a v1 blob (600,000 iterations, 32-byte random salt) and loaded; blob exists → throws `.masterKeyAlreadyExists` and writes nothing; empty password → `.emptyPassword`; Keychain write fails → `.keychain(status)`, no key loaded.
  - unlock: right password → key loaded (replacing any loaded key); wrong → `.wrongPassword`, loaded key unchanged; no blob → `.noMasterKeyBlob`; wrong version, iterations outside 100,000…10,000,000 or unwrapped length ≠ 32 → `.corruptBlob`.
  - Passwords are NFC-normalised before derivation: "é" composed and decomposed unlock the same blob.
  - rewrap: key loaded → blob replaced in place with a new salt, same key (files still decrypt; old password now `.wrongPassword`); no key → `.noKeyLoaded`; write failure → old blob intact.
  - hasMasterKeyBlob: true / false; Keychain error → `.keychain(status)`.
  - deleteMasterKeyBlob: removes it; already absent → succeeds; other failure → `.keychain(status)`.
  - storeBiometricKey: key loaded → item written with `.biometryCurrentSetThisDeviceOnly`, replacing any old item; the new item is written before the old one is removed, so a failure leaves the old item; only when the old item can't be updated without user interaction (invalidated, or the system refuses a silent update) is it deleted and re-added, and a failed re-add there leaves no item (the password still unlocks; Face ID can be re-enabled); no key → `.noKeyLoaded`.
  - unlockWithBiometricKey: item present and approved → key loaded (32 bytes required, else `.invalidKeyData`); user cancel → `.biometricCancelled`; missing or invalidated → `.biometricItemMissing`; lockout → `.biometryLockedOut`; not enrolled → `.biometryNotEnrolled`; no passcode → `.passcodeNotSet`; other → `.keychain(status)`.
  - deleteBiometricKey: removes it; absent → succeeds; other failure → `.keychain(status)`.
  - wipeKey: key unloaded; `isKeyLoaded` false; a `withKey` body already running finishes with its captured key.
  - withKey: no key → `.noKeyLoaded` without running the body.
  - Unlock deletes the legacy "com.KoalaTVault.password" item (errors ignored).
  - One store per vault (feature multiple-vaults-duress-password): `LiveMasterKeyStore` takes the blob account at init (default
    "com.KoalaTVault.masterKeyBlob", so existing callers and the upgraded vault are unchanged); every blob operation
    (`hasMasterKeyBlob`, `createMasterKey`, `unlock`, `rewrap`, `deleteMasterKeyBlob`) uses that account only, so two
    stores with different accounts never see each other's blob or key. The biometric item's account is the same for
    every store (one vault has Face ID at a time). Only the store with the default account deletes the legacy
    "com.KoalaTVault.password" item on unlock.
  - encrypt/decrypt(data): round trip with the same context; any listed context that matches decrypts (tried in order); other key or context → `.decryptionFailed`; no key → `.noKeyLoaded`; nonce differs per call.
  - encryptFile: writes SVC5 (layout in Data models) via a staging file with `.complete` protection, then atomically moves/replaces; source == destination works; no key → `.noKeyLoaded` and no output; empty file → header only; exactly 1 MiB → one chunk; over 2 TiB or short read → `.encryptionFailed`.
  - decryptFile: round trip; wrong magic, flipped header byte, swapped or foreign chunk, dropped last chunk, truncation, trailing bytes, or size mismatch → `.decryptionFailed`, an existing destination left untouched; success replaces the destination.
  - streamInfo: reads the header only; bad magic or truncated header → `.decryptionFailed`; chunkSize outside 1…16 MiB or total over 2 TiB → `.decryptionFailed`.
  - decryptChunk: index in range → that chunk's plaintext; out of range → `.decryptionFailed`.
  - errorDescription (logic in `Contracts/`): noKeyLoaded "No encryption key is loaded."; noMasterKeyBlob "No password has been set up."; masterKeyAlreadyExists "A master key already exists."; wrongPassword "Incorrect password."; emptyPassword "Password cannot be empty."; corruptBlob "The stored password data is damaged."; invalidKeyData "The stored key is invalid."; encryptionFailed "Encryption failed."; decryptionFailed "Decryption failed. The data may be damaged."; biometricItemMissing "Face ID key not found. Use your password."; biometricCancelled "Authentication was cancelled."; biometryLockedOut "Too many attempts. Use your password."; biometryNotEnrolled "Face ID is not set up."; passcodeNotSet "Set a device passcode to use Face ID."; keychain(status) "Couldn't access secure storage (error <status>)." (the status number appears in the text).
- Changes (multiple-vaults-duress-password): LiveMasterKeyStore.swift
- Contract: see `docs/api/VaultCrypto.md` (generated; do not edit by hand)

### Preferences
- Purpose: typed app settings in UserDefaults, and the lock-mode and sort types.
- Depends on: none
- Files: UserDefaultsPreferences.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  enum LockMode: String, Sendable, Codable, CaseIterable { case none, password, passwordAndBiometrics }
  enum SortOption: String, Sendable, Codable, CaseIterable {
      case name, type, dateModified
      var displayName: String { get }
  }
  enum SortDirection: String, Sendable, Codable, CaseIterable { case ascending, descending }

  protocol PreferencesStoring: AnyObject, Sendable {
      var lockMode: LockMode { get set }
      var sortOption: SortOption { get set }
      var sortDirection: SortDirection { get set }
      /// Whether 1.2 left an encrypt migration unfinished (`pendingMigrationType` == "encrypt").
      var hasPendingEncryptMigration: Bool { get }
      /// Removes both pending-migration keys.
      func clearPendingMigration()
      var vaultsUpgraded: Bool { get set }
  }
  ```
- Behavior spec:
  - Defaults on an empty store: `lockMode` .none, `sortOption` .name, `sortDirection` .ascending, `hasPendingEncryptMigration` false, `vaultsUpgraded` false.
  - vaultsUpgraded (feature multiple-vaults-duress-password): round-trips under the key `vaultsUpgraded`; persists across stores on the same suite.
  - Each property round-trips through the injected UserDefaults under the keys in Data models, with raw values "none"/"password"/"passwordAndBiometrics", "name"/"type"/"dateModified", "ascending"/"descending".
  - Values written by a store are read by a new store on the same suite (persistence).
  - Unknown raw values read as the defaults.
  - hasPendingEncryptMigration (minors clean-up 2026-11-11): true only when `pendingMigrationType` is "encrypt" ("decrypt", unknown or missing → false; `pendingMigrationTargetLockMode` is never read). clearPendingMigration removes `pendingMigrationType` and `pendingMigrationTargetLockMode`; other keys untouched.
  - displayName: "Name", "Type", "Date Modified". (Contract logic in `Contracts/PreferencesModels.swift`; unit 1 tests it.)
  - Thread-safe: reads and writes from several threads don't crash or tear.
- Changes (multiple-vaults-duress-password): UserDefaultsPreferences.swift
- Contract changes (multiple-vaults-duress-password): `PreferencesStoring` gains `var vaultsUpgraded: Bool { get set }`.
  Minors clean-up (approved by the human 2026-11-11): `hasCompletedSetup` removed; `MigrationKind`, `PendingMigration` and
  `pendingMigration` replaced by `hasPendingEncryptMigration` (get-only) and `clearPendingMigration()`.
- Contract: see `docs/api/Preferences.md` (generated; do not edit by hand)

### Entitlements
- Purpose: the "Unlock Pro" non-consumable through StoreKit 2.
- Depends on: none
- Files: StoreKitProUnlock.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import UIKit

  enum ProUnlock {
      static let productID = "nej.KoalaTVault.unlockpro"
      static let freeFileLimit = 100
  }
  enum PurchaseOutcome: Sendable, Equatable { case unlocked, cancelled, pending }
  enum ProUnlockError: Error, Equatable, Sendable { case productUnavailable, verificationFailed, purchaseFailed }
  extension ProUnlockError: LocalizedError { var errorDescription: String? { get } }

  @MainActor
  protocol ProUnlocking: AnyObject, Sendable {
      var isUnlocked: Bool { get }
      /// Thread-safe cached value for non-main callers (the import limit).
      nonisolated var isUnlockedNow: Bool { get }
      func displayPrice() async -> String?
      func purchase(confirmIn scene: UIScene?) async throws -> PurchaseOutcome
      func restore() async throws -> Bool
      func refresh() async
      func unlockedUpdates() -> AsyncStream<Bool>
  }
  ```
- Behavior spec:
  - Start: `isUnlocked` and `isUnlockedNow` both start from the cached `entitlement.isUnlocked` value, then a refresh sets both from StoreKit.
  - refresh: a verified current entitlement for the product → unlocked; none → locked (revocation); the cache follows; observers of `unlockedUpdates` get each change once.
  - displayPrice: the product's display price; no product or a load error → nil.
  - purchase: verified success → transaction finished, unlocked, `.unlocked`; user cancel → `.cancelled`, unchanged; pending → `.pending`; unverified → `.verificationFailed` and the transaction is not finished; no product → `.productUnavailable`; other → `.purchaseFailed`. iOS 17+ with a scene confirms in that scene.
  - A successful purchase ends with a refresh queued after any refresh already in flight, so an older refresh can't re-lock after the purchase.
  - `premiumTesting.storekit` contains `ProUnlock.productID` as a non-consumable (a config test checks it).
  - restore: syncs with the App Store, refreshes, returns whether unlocked; user cancel rethrows the StoreKit cancel error.
  - Transaction updates: a verified update is finished and triggers a refresh (a purchase made elsewhere unlocks live); unverified updates are ignored.
  - Tests use `SKTestSession` with `premiumTesting.storekit` and an injected UserDefaults suite. The initializer takes two seams that default to the real calls: `purchase: (Product, UIScene?) async throws -> Product.PurchaseResult` (on iOS 17+ with a scene, `purchase(confirmIn:)`; else `purchase()`) and `sync: () async throws -> Void` (`AppStore.sync()`). Unit tests drive purchase outcomes and the restore cancel through them, because purchases in the hosted unit-test process always fail on the simulator (AMS 305).
  - errorDescription (logic in `Contracts/`, next to `ProUnlockError`; one asserting test per case): productUnavailable "Pro upgrade is currently unavailable."; verificationFailed "Could not verify purchase."; purchaseFailed "Purchase could not be completed."
- Contract: see `docs/api/Entitlements.md` (generated; do not edit by hand)

### VaultStore
- Purpose: the vault on disk: folder indexes, browse and sort, open and write, folder and file operations, trash, the
  per-file migration steps, the orphan sweep and temp files. One module because all of these share the index
  read-modify-write and the rule for whether the vault is encrypted.
- Depends on: VaultCrypto (Preferences until feature multiple-vaults-duress-password)
- Files: VaultIndex.swift, VaultNaming.swift, LiveVaultStore.swift, VaultFileOperations.swift | VaultTrash.swift, VaultMigrationSteps.swift, OrphanSweep.swift, VaultTempFiles.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import Foundation

  struct VaultDirectory: Sendable, Codable, Equatable, Hashable { let name: String; let diskURL: URL; let rootURL: URL }

  enum FileKind: String, Sendable, Codable, CaseIterable {
      case image, video, audio, pdf, word, spreadsheet, presentation, archive, text, other
      init(extension: String)
  }

  struct VaultItem: Identifiable, Sendable, Codable, Equatable, Hashable {
      let id: String
      var name: String
      let isDirectory: Bool
      let dateModified: Date
      let fileSize: Int?
      let deletedAt: Date?
      let diskURL: URL
      let rootURL: URL
      let isEncrypted: Bool
      var kind: FileKind { get }
      var asDirectory: VaultDirectory? { get }
  }

  enum VaultStoreError: Error, Equatable, Sendable {
      case indexUnreadable(folder: String)
      case locked
      case invalidName
      case notFound
      case moveIntoItself
      case io(String)
  }
  extension VaultStoreError: LocalizedError { var errorDescription: String? { get } }

  protocol VaultStoring: Sendable {
      var root: VaultDirectory { get }
      var isEncrypted: Bool { get }
      func contents(of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection) async throws -> [VaultItem]
      func open(_ item: VaultItem) async throws -> URL
      func write(_ data: Data, to item: VaultItem) async throws
      func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem
      func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem
      func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem
      /// Adds many files to one folder in one step, writing the folder's index once (large imports).
      func addFiles(_ files: [VaultFileToAdd], to directory: VaultDirectory) async throws -> [VaultItem]
      func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem?
      func move(_ item: VaultItem, to directory: VaultDirectory) async throws
      func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem
      func rename(_ item: VaultItem, to name: String) async throws -> VaultItem
      func moveToTrash(_ item: VaultItem) async throws
      func remove(_ item: VaultItem) async throws
      func trashContents() async throws -> [VaultItem]
      func restore(_ trashed: VaultItem) async throws -> VaultItem
      func deletePermanently(_ trashed: VaultItem) async throws
      func emptyTrash() async
      func purgeExpiredTrash(now: Date) async throws -> Int
      func hasUnreadableTrash() async -> Bool
      func clearUnreadableTrash() async throws
      func countFiles() async throws -> Int
      func itemsToEncrypt() async throws -> [VaultItem]
      func migrateToEncrypted(_ item: VaultItem) async throws
      func finishEncryption() async throws
      func hasUnencryptedFiles() async throws -> Bool
      func keyMatchesVault() async -> Bool
      func sweepOrphans() async
      func makeTempDirectory() throws -> URL
      func removeTemporary(_ url: URL)
      func removeAllTemporaryFiles()
  }
  ```
- Behavior spec:
  - One store per vault (feature multiple-vaults-duress-password): the live store is given its root folder, the root's display name (the vault's name; "KoalaTVault" for the unencrypted vault), whether it is encrypted, its own key store and cipher, and its temp folder; `root.name` is that name and `isEncrypted` that flag, fixed for the store's life (no longer read from Preferences, which VaultStore no longer uses). Two stores never touch each other's files, indexes, trash or temp files. Each operation captures the key once at its start; in encrypted mode with no key, every operation that reads or writes an index or file content throws `.locked` before changing anything.
  - Index writes are serialized (the live store is an actor): concurrent imports, moves and migration steps never lose an index entry.
  - Index read: absent → empty; encrypted with the key → decoded (AAD ".vault_map", then folder-relative path, then ""); plaintext JSON → decoded in either mode and rewritten encrypted on the next write in encrypted mode; unreadable → `.indexUnreadable(folder:)` and the index is never overwritten.
  - Index write: encrypted in encrypted mode, plaintext JSON in plaintext mode; never plaintext in encrypted mode.
  - contents: non-hidden entries; mapped files show their original name with `isEncrypted` true; unmapped files and folders show the disk name; folders first, then by option and direction (name: case-insensitive; type: by extension then name; dateModified); ids are root-relative paths and equal across listings.
  - Large-folder listing speed (feature multiple-vaults-duress-password, device test 2026-11-12): a listing's cost per item is only that item's own work. Work that is the same for every item of a folder (its root-relative path, the folder's index) is done once per listing; sizes, dates and folder flags come from the directory read itself (attributes prefetched), not a separate stat per file; sorting compares precomputed keys. Results are exactly as before (same items, fields, ids and order, ties included).
  - open: plaintext item → its disk URL; encrypted → decrypted into a new temp folder as `<temp>/<name>`; failure → `.io` / `.locked` and no temp file left.
  - write: encrypted item → plaintext staged in temp, encrypted, atomically replaces the file, plaintext removed; plaintext item → atomic write; key missing → `.locked`, file unchanged.
  - Names: any other name is valid and kept exactly as given (long names up to 200 characters, spaces and symbols such as "&" and "!") through addFile, createFolder, createDocument, rename and contents, in both modes.
  - createFolder: plaintext name on disk in both modes, conflict → " 1"; empty, containing "/", or starting with "." → `.invalidName`.
  - createDocument: empty `.rtf` (".rtf" added if missing) through the same path as addFile, so it is encrypted and indexed in encrypted mode; conflict → " 1" (an existing document is never truncated); empty, containing "/", or starting with "." → `.invalidName`.
  - addFile: encrypted mode → encrypted as a new `<UUID>` and indexed in one serialized step; plaintext mode → copied with its name; name conflict → " 1"; key missing → `.locked`, nothing written; source unreadable → `.io`.
  - findItem: the item with that display name (encrypted or plaintext), or nil. It looks the one name up (in the folder's index and on disk); it never builds the folder's whole listing (large-folder import, device test 2026-11-12).
  - addFiles (large-folder import, device test 2026-11-12): `VaultFileToAdd` is `struct VaultFileToAdd: Sendable, Equatable { let source: URL; let name: String }` (in `Contracts/VaultStoring.swift`). The files go into one folder, in order, as one serialized store step: the folder's index is read once and the folder listed once for names; each file is added exactly as `addFile` would (encrypted mode: encrypted as a new `<UUID>`; plaintext mode: copied; names resolved against the folder and against the earlier files of the same call, " 1" on a clash); in encrypted mode the index is written once, after the last file, with all their entries. Returns the added items in order. A file that fails (invalid name → `.invalidName`, source missing, a folder or unreadable → `.io`, encryption fails) stops the call there: the files before it are kept (and indexed by the one write) and the error is thrown; later files are not attempted. The index write failing removes every file this call encrypted and throws. Key missing → `.locked` before anything is written. An empty list → `[]`, nothing written. The memory a file's work uses is released when that file is done, so it doesn't grow with the number of files. Callers send at most 64 files per call, so a call never holds up other store operations (a listing) for long.
  - Memory (device test 2026-11-12): every store operation releases the temporary memory its work uses when it ends (an autorelease pool around each operation's body, and around each step of the stepped housekeeping), so a long run of operations from one task (an import, a transfer) doesn't build up memory.
  - move: encrypted file → index entry moved and file moved, conflicts on the display name resolved with " 1"; plaintext → moved with " 1" on conflict; into its own folder → no change; a folder into itself or a descendant → `.moveIntoItself`; a failure part-way leaves the item findable in exactly one place.
  - copy: new item in the target with " 1", " 2" names; encrypted copies stay encrypted and decrypt to the same content; a folder into itself or a descendant → `.moveIntoItself`, nothing copied.
  - rename: encrypted → index only; plaintext → disk rename; conflict → " 1"; a name that differs from the item's own only in letter case is not a conflict (renamed in place, both modes); empty, containing "/", or starting with "." → `.invalidName`.
  - remove (feature multiple-vaults-duress-password; a transfer's move removes originals with it): a file → the file and (encrypted) its index entry are deleted, index first; an encrypted file whose index entry is already gone (a stale item) → its file is just deleted; a folder → its whole tree, then the folder; never into the trash; an item of the trash → `.notFound` (that is `deletePermanently`); unknown item → `.notFound`; key missing for an encrypted item → `.locked`, nothing deleted; a failure part-way throws `.io` and leaves what it hasn't reached; if an encrypted file's delete fails after its entry was removed, the entry is written back, best-effort (should that also fail, the unlisted file is left for `sweepOrphans`).
  - moveToTrash: moves into `.trash/<newUUID>` and records a TrashEntry (relative original folder, deletedAt now, encryption state, original names) in one serialized step; a failure leaves the item where it was; folders keep `isDirectory` true.
  - trashContents: one flat list of trash items with `deletedAt`; unreadable trash index → `.indexUnreadable`; a trash file whose header can't be read is still listed with its stored flag (listing and restore never fail because of one unreadable file; migration steps stay strict).
  - restore: back to the original folder (recreated if missing; older absolute paths re-based onto the current root; a target outside the root, through `..`, a hidden folder or a symlink, or a bad disk name → `.io`, nothing moved, entry kept); name conflict → " 1"; encrypted items re-indexed; unknown trash item → `.notFound`.
  - deletePermanently: removes the file and its entry; unknown → `.notFound`.
  - emptyTrash: removes everything in `.trash` and its index, best-effort.
  - purgeExpiredTrash: removes entries with `deletedAt` more than 30 days before `now` and returns how many; unreadable index → throws without writing; a file that can't be removed keeps its entry (retried on the next purge) while the other expired items are still removed, the map is saved, and then the first error is thrown.
  - countFiles: non-hidden files under the root, subfolders included, trash and indexes excluded; a subfolder that can't be read → `.io` (never a partial count).
  - itemsToEncrypt (was `itemsToMigrate(toEncrypted: true)`): every plaintext file under the root and in the trash; empty in plaintext mode.
  - migrateToEncrypted: plaintext file → encrypted `<UUID>`, indexed, plaintext removed (in that order); if an encrypted entry with the same original name already holds identical content, only the plaintext is removed; different content → kept as a new " 1" item. Trash items are re-encrypted in place and their entry updated. Interrupt-safe at every step: a rerun finds a plaintext file whose identical encrypted copy is already indexed and only removes the plaintext; an incomplete encrypted copy is dropped with its entry; a trash item's real form is read from the file's SVC5 header (not the entry's flag), so a conversion killed between the map update and the file replace is corrected on the next itemsToMigrate / migrate / finishDecryption and any leftover hidden `.migrating` staging file is finished or removed. A plaintext file is skipped as already migrated only if it really is an SVC5 file. Every content check (the byte-for-byte compare of a copy with its plaintext) streams one chunk at a time and frees each chunk's buffers before the next, so memory stays bounded by a few chunks whatever the file size (a multi-GB video verifies like a small file).
  - migrateToEncrypted on a trash item that has no trash entry → `.notFound`, nothing changed; on a trash item whose entry exists but whose file is gone → treated as already done (no change, no error), as for files outside the trash. (Feature multiple-vaults-duress-password removes `migrateToDecrypted`, `finishDecryption` and `.stillEncrypted`: nothing decrypts a whole vault any more.)
  - finishEncryption: the last step of an encrypt migration; in encrypted mode with the key, every `.vault_map` under the root (folders inside `.trash` included) that is still plaintext JSON is rewritten encrypted (".vault_map" context) with the same entries, and a plaintext `.trash/.trash_map` likewise (".trash_map"); indexes that are already encrypted or are unreadable are left byte-for-byte as they are; no key → `.locked` before anything is written; plaintext mode → no change.
  - hasUnencryptedFiles: true if any plaintext file is under the root or in the trash; stops at the first one found.
  - Open-vault housekeeping never holds up browsing (feature multiple-vaults-duress-password, device test 2026-11-12): `sweepOrphans` and `hasUnencryptedFiles` work one folder at a time, visiting folders breadth-first (the root, then every folder at the next depth, and so on; the trash is one step); `hasUnencryptedFiles` also splits a large folder's file checks into batches of at most 256 files, each its own step (the folder's listing is taken once, at its first batch; a file gone by its batch is skipped). Each folder's work is one serialized step, as every other store operation, and other store operations (a listing, an import, a move) may run between folders, so a listing asked for while they run waits for at most the step in progress (one folder for the sweep, one batch for the check), never the whole vault. A folder found changed between steps is judged as it is when its step runs; one removed in between is skipped. The root missing at the first step of `hasUnencryptedFiles` throws `.io` as before. A cancelled task stops between steps (the sweep returns, the check throws `CancellationError`); a vault that locks mid-walk stops it (no deletion without the key; the check throws `.locked`). The results are as before: the same orphans deleted, the same answer.
  - keyMatchesVault: true when the loaded key decrypts the root index, or when there is no encrypted index to check; false otherwise.
  - sweepOrphans: only in encrypted mode with the key loaded; in each folder whose index exists and reads, deletes extensionless UUID-named files the index doesn't list and that carry an SVC5 header (a plaintext file with such a name is kept); folders with no index, an unreadable index, and the trash are never swept.
  - Unreadable trash (definition): trash that can never be decrypted, because it was sealed with a key the vault no longer has. Only when all hold: encrypted mode with the key loaded; the key opens the vault (as `keyMatchesVault`); the data was read in full (a read, file-protection or I/O error never counts) and fails authentication under every context it may have been sealed with. Two kinds: (a) the trash index `.trash/.trash_map` (only if it is at least as long as a sealed record, 12-byte nonce + 16-byte tag; an empty or shorter file is uncertain) → the whole trash is unreadable; (b) a top-level trash item (with a readable trash index): a file whose first encrypted chunk fails authentication or is incomplete, judged only on bytes the store itself read (the header and the first chunk, never the whole file; the cipher is never asked to re-read the trash file, so a read error can't pass for a wrong key) (an SVC5 file only; a plaintext file is never unreadable), or a folder in which any `.vault_map` or encrypted file (judged the same way) fails. Anything uncertain (no key, read error, key doesn't match, plaintext mode, `.trash` that is a symlink or not a folder) is never unreadable.
  - hasUnreadableTrash: true when the trash holds unreadable trash as defined above; false otherwise, including on any error (never throws).
  - clearUnreadableTrash: re-checks the definition at the time of the call and removes only what still meets it: kind (a) → everything in `.trash`, the index included; kind (b) → those items (a folder with its whole tree) and their entries, the other items and their entries untouched; the trash index is rewritten without their entries before anything is removed (a failed write removes nothing). Each removal is logged (no names). Nothing unreadable → no change. A removal that fails throws `.io` after the rest are removed; no key → `.locked`, nothing removed.
  - Temp files: `makeTempDirectory` creates a unique folder under the app temp folder; `removeTemporary` removes one; `removeAllTemporaryFiles` removes everything the store created.
  - Contract logic (in `Contracts/VaultStoreModels.swift`; unit 1 tests it): `FileKind(extension:)` maps every extension in Data models › FileKind (one case per extension, also upper and mixed case); an empty or unknown extension → `.other`. `VaultItem.kind` comes from the display name's extension (an encrypted item's original name, not its UUID disk name). `asDirectory`: a folder → `VaultDirectory` with the item's name, diskURL and rootURL; a file → nil.
  - errorDescription (logic in `Contracts/VaultStoring.swift`, next to `VaultStoreError`; tested in a reopened VaultStore change, one asserting test per case): indexUnreadable "Couldn't read the vault's file index. It may still be locked, or a file may have become corrupted."; locked → the text of `VaultCryptoError.noKeyLoaded` ("No encryption key is loaded."); invalidName "Names can't contain / or start with ."; notFound "This item no longer exists."; moveIntoItself "A folder can't be moved into itself"; io(message) → the message itself. Alerts show `localizedDescription`, so this is the text the user sees.
- Changes (multiple-vaults-duress-password): LiveVaultStore.swift, VaultIndex.swift, VaultFileOperations.swift, VaultMigrationSteps.swift, OrphanSweep.swift, VaultTrash.swift (autorelease pools only, large-folder import)
- Contract changes (multiple-vaults-duress-password): `VaultStoring` gains `addFiles(_:to:)` and `VaultFileToAdd` (large-folder import, device test 2026-11-12; the mocks and the shell's store wrapper implement it); `VaultStoring` gains `isEncrypted` and `remove(_:)`; `itemsToMigrate(toEncrypted:)` becomes `itemsToEncrypt()`; `migrateToDecrypted(_:)` and `finishDecryption()` are removed; `VaultStoreError.stillEncrypted(count:)` is removed (and its `errorDescription` case, in `Contracts/VaultStoring.swift`).
- Contract: see `docs/api/VaultStore.md` (generated; do not edit by hand)

### SharedUI
- Purpose: UIKit pieces several screens use: progress overlay, alerts, presentation helpers, file icons.
- Depends on: VaultStore
- Files: FileIconMapping.swift, Views/ProgressOverlayView.swift, Views/AlertPresenting.swift, Views/UIViewController+Topmost.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import UIKit

  struct FileIcon: Sendable, Equatable { let symbolName: String; let tintName: String; let usesFolderAsset: Bool }
  enum FileIconMapping {
      static func icon(for kind: FileKind, isDirectory: Bool, folderAssetAvailable: Bool) -> FileIcon
  }
  @MainActor protocol AlertPresenting: AnyObject {
      func showError(_ error: Error)
      func showError(_ message: String)
      func showSuccess(_ message: String)
  }
  ```
- Behavior spec:
  - FileIconMapping (the logic lives in `Contracts/FileIconMappingContract.swift`; unit 1 tests it there, and `FileIconMapping.swift` needs no code of its own): folders → `FileIcon("nej_FolderIconB", tint "clear", usesFolderAsset: true)` when the asset is available, else `("folder.fill", "systemYellow", false)`; files, by kind (symbol, tint): image ("photo", "systemGreen"), video ("video", "systemPurple"), audio ("music.note", "systemPink"), pdf ("doc.richtext", "systemRed"), word ("doc.text", "systemBlue"), spreadsheet ("tablecells", "systemGreen"), presentation ("rectangle.stack", "systemOrange"), archive ("archivebox", "systemBrown"), text ("doc.plaintext", "systemGray"), other ("doc", "systemGray"); one test per kind. Tints are `UIColor` names.
  - AlertPresenting (default implementation for view controllers): error alert titled "Error" with OK and the message (or `localizedDescription`); success alert with no title; presented from the topmost presented controller so it never fails silently.
  - ProgressOverlayView: title, progress bar, status "Preparing...", optional Cancel; `update(progress:status:)` and `dismiss()` are main-actor and safe to call repeatedly. It covers the whole presenting screen including its navigation bar (shown on the navigation controller's view when the screen has one), so nothing behind it can be tapped while it shows, and it is modal for VoiceOver. It can also be shown without progress: an activity indicator in place of the bar, with a status line given at show time (fixed in verify, app review B1/B3). (View; covered by journey tests.)
  - UIViewController+Topmost: `topmostPresentedController` follows `presentedViewController` to the end, stopping before a controller that is being dismissed, so an alert shown right after a sheet closes is not lost (fixed in verify, app review B2). (View.)
- Contract: see `docs/api/SharedUI.md` (generated; do not edit by hand)

### VaultLock
- Purpose: the vaults (feature multiple-vaults-duress-password; before it, the one vault's lock): which vault is open, the unencrypted vault,
  finding and opening an encrypted vault by password or Face ID, creating, closing and deleting vaults, changing a
  vault's password, its Face ID, the transfer target, closing on background, and the one-time upgrade from 1.2.
- Depends on: VaultCrypto, Preferences, VaultStore, Entitlements
- Files: LockState.swift, BiometricInfo.swift, LiveVaultLock.swift | VaultCatalog.swift, VaultUpgrade.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import Foundation

  enum BiometricKind: Sendable, Equatable { case none, faceID, touchID }

  /// A vault ready to use: the unencrypted vault, or an encrypted vault whose key is loaded.
  struct OpenVault: Sendable {
      /// "unencrypted", "primary" (the upgraded vault) or a UUID string.
      let id: String
      let name: String
      let isEncrypted: Bool
      let store: any VaultStoring
  }

  enum VaultLockError: Error, Equatable, Sendable {
      case wrongPassword, emptyPassword, emptyName, passwordInUse, vaultLimitReached, sameVault, notOpen
      case biometricsUnavailable, noBiometricVault
      case biometricCancelled, biometryLockedOut, biometryNotEnrolled, passcodeNotSet, biometricChanged
      case keychain(Int32), io(String)
  }
  extension VaultLockError: LocalizedError { var errorDescription: String? { get } }

  @MainActor
  protocol VaultLocking: AnyObject, Sendable {
      var current: OpenVault { get }
      var unencryptedVault: OpenVault { get }
      func currentUpdates() -> AsyncStream<OpenVault>
      var biometricKind: BiometricKind { get }
      var biometricsAvailable: Bool { get }
      var hasBiometricVault: Bool { get }
      var currentUsesBiometrics: Bool { get }
      func upgradeIfNeeded() async throws
      func canCreateVault() async -> Bool
      func createVault(name: String, password: String) async throws
      func open(password: String) async throws
      func openWithBiometrics() async throws
      func close()
      func appWillResignActive() -> Bool
      func appDidEnterBackground()
      func changePassword(current: String, new: String) async throws
      func setUsesBiometrics(_ enabled: Bool) async throws
      func deleteCurrentVault(password: String) async throws
      func openTransferTarget(password: String) async throws -> OpenVault
      func closeTransferTarget(_ vault: OpenVault)
  }
  ```
- Behavior spec (feature multiple-vaults-duress-password; replaces the lock-mode spec):
  - Injection: the live lock takes the Documents root (the unencrypted vault), the `Vaults/` folder, the Keychain seam,
    the preferences, the Pro entitlement, the biometric info, and factories for a vault's key store (by blob account),
    cipher (over a key store) and store (root, name, encrypted, key store, cipher). Tests use temp folders, the
    in-memory Keychain and fakes; nothing touches the real ones.
  - VaultCatalog (VaultCatalog.swift): lists the vaults (each folder under `Vaults/` whose blob exists; the blob account
    rule in Data models); reads a vault's name from `.vault_info` (missing or unreadable → "My Vault") and writes it
    sealed (written atomically with complete file protection, like the other store files; minors clean-up 2026-11-11; the simulator doesn't record protection classes, so as for the other store files the reviewer checks the option and the device test confirms it — decided by the human); removes at launch a folder whose blob is missing only when it is empty (an interrupted creation holds no files; a blobless folder with anything in it is left alone and not listed, so files are never deleted); reads and
    writes the Face ID vault marker ("com.KoalaTVault.biometricVaultID"). A Keychain error reading a blob counts as the
    blob existing (a vault is never removed on an error).
  - current / currentUpdates: launch → the unencrypted vault (id "unencrypted", name "KoalaTVault", plaintext store over
    Documents). Each change of `current` is published once (only changes; subscribers read `current` first).
  - open(password): empty → `.emptyPassword`; tries the password against each vault's blob (PBKDF2 once per vault) and
    stops at the first that unlocks; none → `.wrongPassword` (no other information); with no encrypted vault to try,
    the search still runs one decoy derivation at the blob's cost (see "Decoy derivation" below), so a wrong password
    doesn't come back faster when there are no encrypted vaults; the vault already open → no change;
    otherwise the open vault (if any) is closed first (key wiped, its temp files removed), the found vault's name is read
    (and written if missing), and it becomes `current`.
  - openWithBiometrics: no marker or its vault is gone → `.noBiometricVault`; not available → `.biometricsUnavailable`;
    loads that vault's key from the biometric item; the key doesn't open the vault (`keyMatchesVault` false) or the item
    is missing/invalidated → key wiped, item and marker deleted, `.biometricChanged`; cancel, lockout, not enrolled, no
    passcode → their cases; success → as open.
  - canCreateVault: true with Pro or with no encrypted vault yet; false otherwise.
  - createVault(name, password): name trimmed; empty → `.emptyName`; empty password → `.emptyPassword`; not allowed
    (`canCreateVault` false) → `.vaultLimitReached`; the password opens an existing vault → `.passwordInUse`; then a new
    UUID folder, key created under its blob account, `.vault_info` written, and the vault opened as `current`. A
    failure after the folder or blob was made removes both (no half-made vault) and rethrows.
  - close: an encrypted vault open → key wiped, its temp files removed, a transfer target closed too, `current` = the
    unencrypted vault; already unencrypted → nothing.
  - appWillResignActive: true (show the privacy cover) when an encrypted vault is open. appDidEnterBackground: as close.
  - changePassword(current:new:): only in an encrypted vault (`.notOpen` otherwise); empty new → `.emptyPassword`; wrong
    current → `.wrongPassword`, blob unchanged; the new password opens another vault → `.passwordInUse`; then the blob
    is rewrapped (same key, files stay readable).
  - setUsesBiometrics(true): encrypted vault only (`.notOpen`); not available → `.biometricsUnavailable`; stores this
    vault's key in the biometric item (replacing any other vault's), then the marker = this vault; a failure leaves the
    marker as it was. (false): if this vault has it, marker and item deleted; otherwise nothing. currentUsesBiometrics:
    the marker names `current`. hasBiometricVault: the marker exists and names a listed vault.
  - deleteCurrentVault(password): encrypted vault only (`.notOpen`); the password must open this vault
    (`.wrongPassword`, nothing erased); then Face ID (item and marker) if it is this vault's, then the folder, then the
    blob; then as close. A failure part-way throws and what is left is still a vault, or (blob only) harmless.
  - openTransferTarget(password): empty → `.emptyPassword`; the open vault's own password → `.sameVault`; no vault →
    `.wrongPassword`; otherwise an `OpenVault` with its own loaded key, separate from `current`. closeTransferTarget wipes
    its key and temp files. The unencrypted vault as a target needs no password (`unencryptedVault`).
  - Password checks and races (VaultLock unit 1 review): a password is always tried on a fresh key store (never on the
    open vault's own), and a fresh store that didn't become the open vault or the transfer target is wiped. If `close`,
    `appDidEnterBackground` or another open runs while a check is in progress, the check's result is dropped and its key
    wiped: `open`, `openWithBiometrics` and `openTransferTarget` throw `.notOpen` and open nothing; `changePassword`,
    `deleteCurrentVault` and `setUsesBiometrics` throw `.notOpen` and change nothing; `createVault` keeps the finished
    vault but doesn't open it (no error). `createVault` calls run one at a time (a second waits, then makes its own
    checks), so two vaults never share a password. `setUsesBiometrics(false)` in the unencrypted vault does nothing.
  - Decoy derivation (minors clean-up 2026-11-11, closes "timing reveals zero vs some vaults"): every password search
    (open, createVault's and changePassword's in-use checks, openTransferTarget) that has no vault to try (none listed,
    or none left after excluding the open one) runs one PBKDF2 derivation of the typed password at the real cost
    (600,000 iterations) and discards it; nothing is stored or compared. The live lock takes a decoy key-store factory;
    the shell gives a `LiveMasterKeyStore` over a private in-memory Keychain (never the real one). The lock creates the
    decoy's blob for a random password (key wiped at once) once, off the main thread, starting when the lock is made,
    so the first search isn't slower than later ones (a search that comes before it's ready waits for it); the decoy's `unlock(password:)` is the derivation and its `.wrongPassword` is ignored. The decoy
    never unlocks, never becomes a vault and is never listed. With one or more vaults to try, nothing changes (the count of
    vaults can still be told from timing; out of scope).
  - VaultUpgrade (VaultUpgrade.swift), `upgradeIfNeeded` (journey 12), run once at launch before anything shows:
    `vaultsUpgraded` true → nothing. A lock (`lockMode` not .none, or `hasPendingEncryptMigration` while a blob exists; a Keychain
    error counts as a blob) → `Vaults/primary/` is created and every entry of Documents (hidden ones included) is moved
    into it (moves only; an entry whose name is already there is left in Documents and logged, never overwritten);
    `passwordAndBiometrics` → marker = "primary"; then `clearPendingMigration()` (always, whatever was stored) and `vaultsUpgraded` set (last).
    No lock (a pending encrypt with no blob is dropped) → `vaultsUpgraded` set, nothing moved. A failure throws; the next
    launch carries on from what is left. `lockMode` is not changed (nothing reads it after).
  - errorDescription (logic in `Contracts/VaultLockContract.swift`; one asserting test per case): wrongPassword
    "Incorrect password"; emptyPassword "Password cannot be empty"; emptyName "Enter a name for the vault"; passwordInUse
    "Choose a different password."; vaultLimitReached "More vaults with Pro."; sameVault "These items are already in this
    vault."; notOpen "Open a vault first."; biometricsUnavailable "Biometric authentication isn't available on this
    device."; noBiometricVault "No vault uses Face ID."; biometricCancelled, biometryLockedOut, biometryNotEnrolled,
    passcodeNotSet, biometricChanged "Biometric authentication failed"; keychain(status) "A Keychain error occurred
    (<status>)."; io(message) → the message.
  - Removed: `LockState`, `state`, `stateUpdates`, `lockMode`, `setUp`, `unlock`, `unlockWithBiometrics`,
    `appWillEnterForeground`, `switchMode`, `prepareToAddLock`, `removeKeysAfterDecryption`, the empty-vault check, and
    the errors `existingPasswordRequired`, `passwordMissing`, `notUnlocked`. LockState.swift keeps the open-vault state
    (`current` and its publishing).
  - Build note: the new unit 2 (VaultCatalog.swift, VaultUpgrade.swift) is built before the reopened unit 1, which uses it.
- Changes (multiple-vaults-duress-password): LockState.swift, BiometricInfo.swift, LiveVaultLock.swift; minors clean-up
  2026-11-11: LiveVaultLock.swift (decoy derivation), VaultCatalog.swift (file protection), VaultUpgrade.swift (new
  Preferences calls). No VaultLock contract change.
- Contract changes (multiple-vaults-duress-password): the `VaultLocking` protocol, `OpenVault` and `VaultLockError` above replace the lock-mode contract (`LockState` removed); VaultLock now depends on Entitlements.
- Contract: see `docs/api/VaultLock.md` (generated; do not edit by hand)

### LockMigration
- Purpose: encrypt the files an encrypted vault still holds unencrypted (left by a 1.2 lock change, journey 12) when it
  opens, with retry, skip and clearing unreadable trash. (Before feature multiple-vaults-duress-password: encrypt or decrypt the whole vault on a
  lock change, with a persisted pending record.)
- Depends on: VaultStore
- Files: MigrationProgress.swift, LiveLockMigrator.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  enum MigrationPhase: Sendable, Equatable {
      case idle
      case running(done: Int, total: Int)
      case failed(names: [String])
      case completed(fully: Bool)
      case unreadableTrash
  }

  @MainActor
  protocol LockMigrating: AnyObject, Sendable {
      var phase: MigrationPhase { get }
      func phaseUpdates() -> AsyncStream<MigrationPhase>
      func encryptLeftovers(in store: any VaultStoring) async
      func retryFailed() async
      func skipFailed() async
      func clearUnreadableTrash() async
      func cancel()
  }
  ```
- Behavior spec (feature multiple-vaults-duress-password):
  - encryptLeftovers: lists `itemsToEncrypt`, then encrypts one file at a time (`migrateToEncrypted`), then
    `finishEncryption`; phase `.running(0, n)` … `.completed(fully: true)`; nothing to encrypt → `.completed(fully: true)`
    at once; a second call while a run exists (running, failed, unreadable trash) does nothing (one runner); a store that
    isn't encrypted → no store calls, phase `.idle` (unless a run exists: it
    is left as it is). With nothing to encrypt, `finishEncryption` still runs and no
    `.running(0, 0)` is published.
  - No persisted record: whatever is left unencrypted is found again the next time the vault opens.
  - A file that fails → collected; at the end `.failed(names)` with the display names. retryFailed: only the failed files
    again (publishing `.running` first, so a repeat failure is published again). skipFailed: `.completed(fully: false)`.
  - A listing failure (not a lock) → `.failed(names: [])`, the error logged; Retry redoes the listing.
    `finishEncryption` (the closing step) failing with the key loaded is logged and the run still completes.
  - Unreadable trash: wherever the run would publish `.failed`, it first asks `hasUnreadableTrash()`; true →
    `.unreadableTrash`. clearUnreadableTrash (only from there): publishes `.running`, `clearUnreadableTrash()` on the
    store, then continues from a fresh listing; a clearing failure → `.failed(names: [])`. skipFailed from there as from
    `.failed`; retryFailed does nothing there.
  - cancel (the vault closed): the run stops after the file in progress (which finishes or fails without being counted)
    and the phase is `.idle`; the file in progress is safe (the store's steps are interrupt-safe). A `.locked` error from
    the store also ends the run as cancel does. An `encryptLeftovers` made while a cancelled run's file is still in
    progress waits for that file, then runs; a `cancel` during that wait drops it (it never touches the store). The store
    is held only while a run exists (running, failed, unreadable trash) and released when the run completes, is skipped
    or is cancelled.
  - `UITEST_FAIL_MIGRATION_FILE` (UI-test mode only) makes that file fail.
  - Removed: `pending`, `start(_:target:)`, `resumeIfPending`, `.paused`, decrypting, lock-mode switching, and the
    dependencies on VaultLock and Preferences.
- Changes (multiple-vaults-duress-password): MigrationProgress.swift, LiveLockMigrator.swift
- Contract changes (multiple-vaults-duress-password): `LockMigrating` above replaces `pending`, `start(_:target:)` and `resumeIfPending()` with `encryptLeftovers(in:)` and `cancel()`; `MigrationPhase.paused` removed.
- Contract: see `docs/api/LockMigration.md` (generated; do not edit by hand)

### VaultTransfer
- Purpose: move or copy items from one vault to another (feature multiple-vaults-duress-password, journey 11), decrypting or encrypting on the
  way, with the target's free-tier limit.
- Depends on: VaultStore, Entitlements
- Files: TransferPlan.swift, LiveVaultTransfer.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import Foundation

  struct TransferResult: Sendable, Equatable, Hashable {
      let done: Int
      let failed: Int
  }

  enum VaultTransferError: Error, Equatable, Sendable { case limitReached, sameVault }
  extension VaultTransferError: LocalizedError { var errorDescription: String? { get } }

  protocol VaultTransferring: Sendable {
      func transfer(
          _ items: [VaultItem],
          from source: any VaultStoring,
          to target: any VaultStoring,
          removingOriginals: Bool,
          progress: @escaping @Sendable (Int, Int) -> Void
      ) async throws -> TransferResult
  }
  ```
- Behavior spec:
  - TransferPlan: counts the files the items hold (a file 1; a folder every file in its tree, through the source's
    `contents`); without Pro, target `countFiles()` + that count > 100 → `.limitReached` before anything is written
    (exactly 100 is allowed); with Pro no check. Source and target with the same root → `.sameVault`.
  - transfer: items in order; each file: `open` from the source (a decrypted temp copy for an encrypted item, removed
    afterwards), `addFile` into the target's root (or the matching folder for files inside a moved folder; folders are
    recreated with `createFolder`, " 1" on a clash like any name), then, when moving, `remove` of the original only after
    its copy is complete. A folder being moved is removed only after everything in it was copied; if anything in it
    failed, the folder is kept in the source (its copied files stay in both). `progress(done, total)` after each file.
  - A failure of one item doesn't stop the others; the result counts top-level items done and failed. Nothing is ever
    removed from the source before its copy exists in the target.
  - Edge cases: a folder that can't be created in the target fails its whole item (its files are not copied or removed, the
    original stays in the source, and they still advance `progress` so it reaches the total); a `remove` of an original that
    fails after its copy succeeded counts that item as failed (the copy stays in the target).
  - Cancellation (the task cancelled because the vault closed) stops before the next file; what is done stays done.
  - Plaintext → plaintext and encrypted → encrypted transfers work the same way (content always goes through `open`).
  - errorDescription (logic in `Contracts/`; one asserting test per case): limitReached "The other vault would have more
    than 100 files."; sameVault "These items are already in this vault."
- Contract: see `docs/api/VaultTransfer.md` (generated; do not edit by hand)

### Media
- Purpose: thumbnails for the grid and streaming encrypted video to AVPlayer without writing plaintext to disk.
- Depends on: VaultStore, VaultCrypto, Preferences
- Files: ThumbnailCache.swift, LiveThumbnailProvider.swift, EncryptedVideoLoader.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import AVFoundation
  import UIKit

  protocol ThumbnailProviding: Sendable {
      func thumbnail(for item: VaultItem, size: CGSize, scale: CGFloat) async -> UIImage?
      func cancel(_ item: VaultItem)
      func clearCache()
      func clearCache(for item: VaultItem)
  }
  protocol VideoAssetProviding: Sendable {
      /// An asset that plays the item: streamed through a resource loader when encrypted, the file URL otherwise.
      func asset(for item: VaultItem) throws -> AVURLAsset
  }
  ```
- Behavior spec:
  - Cache: in memory only, keyed by item id + `dateModified` + `fileSize` (an edited or replaced file at the same path gets a fresh thumbnail, as today); a second request for the same unchanged item returns the cached image without generating; `clearCache` empties it and a generation finishing after the clear doesn't refill it.
  - Plaintext file → QuickLook thumbnail; encrypted video → a frame at min(5 s, duration / 2) through the streaming loader, nothing written to disk; other encrypted files → decrypted into a store temp folder, thumbnailed, temp removed; at most 2 decrypts at once.
  - Folder → the first image or video inside, in the user's current browser sort (`PreferencesStoring.sortOption`/`sortDirection`, read at request time), composed onto the folder icon; no media → the folder icon; cancelling a folder cancels its media request.
  - cancel before work starts → returns nil and no work is done; corrupt, truncated or locked files → nil.
  - asset(for:) encrypted: `vault-stream://` URL with a loader that answers content info (type from the extension, default mpeg-4; length = plaintext size; byte ranges) and data requests by decrypting only the needed chunks; empty range finishes at once; a decrypt error fails the request; invalid header → throws.
  - asset(for:) plaintext → the disk URL.
- Contract: see `docs/api/Media.md` (generated; do not edit by hand)

### Import
- Purpose: bring files, folders and photos into the vault with the free-tier limit and duplicate detection, and present
  the import sheet and pickers.
- Depends on: VaultStore, Entitlements, SharedUI
- Files: ImportLimit.swift, DuplicateCheck.swift, LiveVaultImporter.swift, PhotoLibraryAccess.swift | Views/ImportPresenter.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import Foundation

  struct ImportResult: Sendable, Equatable { var imported: Int; var skippedDuplicates: Int; var failed: Int }
  struct PhotoImportResult: Sendable, Equatable { var importedAssetIDs: [String]; var failed: Int }
  enum ImportError: LocalizedError, Equatable, Sendable { case fileLimitReached(limit: Int), unreadableSource(String) }

  protocol VaultImporting: Sendable {
      func checkAllowed(adding count: Int) async throws
      func importItems(_ urls: [URL], into directory: VaultDirectory, progress: @Sendable (Double) -> Void) async throws -> ImportResult
      func importPhotos(_ assets: [PhotoImportSource], into directory: VaultDirectory) async throws -> PhotoImportResult
  }
  /// One picked photo or video: its asset identifier (nil without library access) and a loader for its file.
  struct PhotoImportSource: Sendable {
      let assetID: String?
      let suggestedName: String
      /// Loads the asset's file: returns a file alone in its own store temp folder, which `importPhotos` removes afterwards.
      let loadFile: @Sendable () async throws -> URL
  }
  protocol CameraRollDeleting: Sendable { func deleteAssets(withIdentifiers ids: [String]) async }
  ```
- Behavior spec:
  - checkAllowed: Pro → always passes; free → `countFiles() + count > 100` throws `.fileLimitReached(limit: 100)`; exactly 100 passes.
  - importItems: counts every file in the selection (folders recursively) and checks the limit before importing anything (all or nothing); folders are recreated with their structure; a picked folder (or subfolder) whose name matches an existing folder in the destination is merged into it rather than getting " 1", and if the name belongs to a file the folder gets a free name; files go through `VaultStoring.addFiles` in batches of at most 64 per destination folder (the picked loose files share the destination), each file's place in the order kept; same name and same SHA-256 as an existing item → skipped and counted in `skippedDuplicates`; same name, different content → " 1"; progress reported from 0 to 1, after each batch and each skipped duplicate; a failure part-way keeps the earlier files and rethrows; security-scoped URLs are opened and closed.
  - Large folders (device test 2026-11-12: a 9,000-JPG folder crashed the app part-way): the work per file doesn't grow with the folder. The destination folder is listed once when its import starts; a file whose name isn't in that listing (or among the names this import has added there) is not a duplicate and needs no store lookup; only a name already there goes through the hash check (`findItem` + `open`). Memory is released after each file (hashing, building the batch) and after each batch, so a 9,000-file folder imports with memory that stays flat. A duplicate name found inside a pending batch counts as a duplicate only by the same rule as today (same name and content as an item already in the folder). A failure part-way (a lookup, a listing or a batch failing, or cancellation) first adds the files already waiting in batches, then rethrows, so every file before the failure is kept, as before. Names the store gives a file on a clash (" 1") count as names added by this import. A folder picked twice in one import, whose name belongs to a file in the destination, merges into the folder the first pick created ("Trip 1"), not a second one ("Trip 2") (review, 2026-11-12).
  - importPhotos: checks the limit for the count first; imports one at a time; returns the asset IDs that were imported or were already in the vault, and the failure count; temp copies are removed.
  - A photo is stored under its real name: the name iOS gives for it plus its type's extension, kept as is if the name already has an extension of that type (a dot alone doesn't make one: "Photo 2024.10.01" → "Photo 2024.10.01.heic"; JPEGs use ".jpg"); "photo" only when iOS gives no name.
  - Duplicate check in an encrypted vault decrypts the existing same-name file to a temp folder to hash it and removes it afterwards.
  - Names starting with ".": `VaultStoring.addFile` accepts them, but in a no-lock vault they would be hidden from listings (and a root ".trash" would clash with the trash), so Import handles them. A file or folder picked directly, or a photo's `suggestedName`, has its leading dots removed before it is stored (".env" → "env", ".trash" → "trash"), and the duplicate check uses the new name; it counts toward the limit. A name that is only dots counts as `failed` (`importPhotos`: in `failed`, with nothing imported for it). Hidden files and folders inside a picked folder are skipped: not imported, not counted toward the limit, not reported in `ImportResult`.
  - ImportError text: `.unreadableSource(name)` → `Couldn't read "<name>".`; `.fileLimitReached(limit)` → `This vault has reached its limit of <limit> files.`
  - ImportPresenter (view): sheet "Choose Files", "Choose Folder", "Choose Photos", "Cancel" anchored to the Import button on iPad; document pickers (multi-select); photo picker (images and videos, no limit, requests read-write access first); Cancel in any picker closes it; limit → picker closes then the caller's `onLimitReached` runs (the paywall); "Importing..." / "Importing Photos..." overlays with progress; "N imported, M failed" when any failed; then the camera-roll delete for the imported asset IDs (iOS shows its own confirmation); other errors shown after the picker closes.
- Changes (multiple-vaults-duress-password): LiveVaultImporter.swift, DuplicateCheck.swift (large-folder import, device test 2026-11-12)
- Contract: see `docs/api/Import.md` (generated; do not edit by hand)

### Export
- Purpose: decrypted copies for sharing, saved to Files or the photo library, with guaranteed clean-up.
- Depends on: VaultStore, SharedUI
- Files: LiveVaultExporter.swift, PhotoLibrarySaver.swift | Views/ExportPresenter.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import Foundation

  struct ExportBundle: Sendable { let urls: [URL]; let cleanUp: @Sendable () -> Void }
  struct PhotoSaveResult: Sendable, Equatable { var saved: Int; var failed: Int; var skipped: Int }
  enum ExportError: Error, Equatable, Sendable { case photoAccessDenied, nothingToExport }

  protocol VaultExporting: Sendable {
      func prepareForSharing(_ items: [VaultItem]) async throws -> ExportBundle
      func saveToPhotos(_ items: [VaultItem]) async throws -> PhotoSaveResult
      func canSaveToPhotos(_ items: [VaultItem]) -> Bool
  }
  ```
- Behavior spec:
  - prepareForSharing: plaintext items → their disk URLs; encrypted → decrypted copies with their original names in one store temp folder; a folder holding encrypted items → a decrypted copy of its whole tree (original names, no `.vault_map`, no UUID names), a plaintext folder → its disk URL; an empty selection → `.nothingToExport`; two copies with the same name in one selection get " 1", " 2" before the extension (plaintext items stay their disk URLs, whatever their names); a failure part-way removes every copy made and rethrows; `cleanUp` removes the temp folder (safe to call twice).
  - Copy names come from an index that may be crafted or corrupted, so each is made safe before use: "/" becomes "-", leading dots are removed, and a name left empty becomes "file"; nothing is ever written outside the temp folder, and a tree copy never holds a `.vault_map`. A cancelled export removes its copies and throws `CancellationError`, never returning a bundle; a cancelled saveToPhotos stops, removes the current temp copy and throws `CancellationError`.
  - saveToPhotos: add-only access required (`.photoAccessDenied` otherwise); images and videos only (others counted in `skipped`); each decrypted to temp, saved, temp removed; per-item failures counted.
  - canSaveToPhotos: true when any item is an image or video.
  - ExportPresenter (view): sheet "Save to Files", "Save to Camera Roll" (when allowed), "Cancel"; "Exporting..." overlay shown without progress, its status "Exporting N item(s)…" ("1 item"), never stuck on "Preparing..."; the "Saving to Camera Roll..." overlay likewise, status "Saving N item(s)…" (fixed in verify, app review B3); document picker for export as copies, `cleanUp` on pick or cancel; after a camera-roll save, "N item(s) saved to Camera Roll" ("1 item", "4 items") when nothing failed and "N saved, M failed" when any failed, skipped items not mentioned; `.nothingToExport` → "Nothing to export."; a camera-roll save shows a title-only "Saving to Camera Roll..." overlay; a picker that can't open removes the copies and shows "Couldn't open the Files picker."; a picker closed by anything, the user or the app, removes the copies; the caller's `completion` runs exactly once however the export ends, Cancel included; access denied → "Allow KoalaTVault to add photos in Settings."; errors shown.
- Contract: see `docs/api/Export.md` (generated; do not edit by hand)

### LockScreens
- Purpose: the lock screen (the Vaults screen) and Create Vault, the privacy cover, and closing the open vault and
  showing the lock screen at launch, on background and on Lock (feature multiple-vaults-duress-password; before it: the
  setup wizard and the password lock screen).
- Depends on: VaultLock, SharedUI
- Files: SetupWizardViewModel.swift, LockScreenViewModel.swift, AppLockCoordinator.swift | Views/SetupWizardViewController.swift, Views/LockScreenViewController.swift, Views/PrivacyCoverView.swift, Views/LockPresenter.swift | VaultsViewModel.swift, CreateVaultViewModel.swift, Views/VaultsViewController.swift, Views/CreateVaultViewController.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import UIKit

  @MainActor
  protocol AppLockCoordinating: AnyObject {
      func sceneDidConnect(window: UIWindow)
      func sceneWillResignActive()
      func sceneDidEnterBackground()
      func sceneDidBecomeActive()
      /// Closes the open vault and shows the lock screen (the browser's Lock button, a deleted vault).
      func lock()
  }

  @MainActor
  protocol VaultsScreenFactory: AnyObject {
      /// The lock screen in its navigation controller. `onDone` is called when a vault is open (by password, Face ID,
      /// a new vault, or the unencrypted vault). `onNeedsPro` is called with the screen to present the paywall from
      /// (Create New Vault without Pro, an encrypted vault already there).
      func makeLockScreen(onDone: @escaping () -> Void,
                          onNeedsPro: @escaping (UIViewController) -> Void) -> UIViewController
  }
  ```
- Behavior spec (feature multiple-vaults-duress-password):
  - VaultsViewModel (the lock screen): password field, Open, "Use <`biometricKind` name>" shown when `hasBiometricVault`
    and biometrics are available, "Open Unencrypted Vault", "Create New Vault"; no Cancel and no Close Vault. Open: empty
    password ignored; busy ("Opening…", buttons disabled) while it runs; success → done (the screen closes); every
    error and a success clear the field; `.wrongPassword` → "Incorrect password"; other errors → their message.
    Face ID: no automatic prompt; cancel → nothing; lockout → "Too many attempts. Use your password."; not enrolled →
    "Face ID is not set up."; passcode → "Set a device passcode to use Face ID."; changed → "Face ID changed. Use your
    password." and the button hides; other → "Biometric authentication failed". The error clears when typing starts.
    Create New Vault: `canCreateVault()` true → the Create Vault screen; false → `onNeedsPro`. Open Unencrypted Vault → `close()`
    (the unencrypted vault becomes `current`), done. Nothing in the model or its texts depends on how many vaults exist.
  - Lock screen logo (view; design tweaks, device test 2026-11-12): the app logo is shown in a square frame exactly the
    size of the logo image (no empty space around it), centred, with continuous rounded corners about 22.5% of its side,
    as an app icon on the Home Screen; it still scales with the text size as today.
  - CreateVaultViewModel: Name, Password, Confirm; Create: name trimmed empty → "Enter a name for the vault"; empty
    password → "Password cannot be empty"; mismatch → "Passwords do not match"; then `createVault`; busy ("Creating
    Vault…"); success → both password fields clear, then done (both screens close); `.passwordInUse` → "Choose a different password."; `.vaultLimitReached`
    → `onNeedsPro`; other errors → their message (the fields keep the name, the password fields clear).
  - AppLockCoordinator: connect → the lock screen full-screen over the window's root, without animation; resign active
    with `appWillResignActive()` true → privacy cover over the window; background → `appDidEnterBackground()` (closes
    the vault; the shell swaps the browser) and the lock screen up (if not already), for every vault, before the app
    switcher snapshot; active → the cover hidden (the lock screen stays); `lock()` → `close()` and the lock screen up;
    the lock screen's `onDone` → the lock screen dismissed. At most one lock screen at a time; anything presented over
    the browser is dismissed first. `onNeedsPro` is given by the shell (the paywall). No setup, no launch recovery.
  - Removed (the code-writer deletes the files and the test-writer their tests; the Files line drops them when the
    feature is accepted): SetupWizardViewModel.swift, LockScreenViewModel.swift, Views/SetupWizardViewController.swift,
    Views/LockScreenViewController.swift, and the old lock screen's presenting in `LockPresenter`
    (Views/LockPresenter.swift now presents the new lock screen and the privacy cover).
  - Views: identifiers `vaults.passwordField`, `vaults.openButton`, `vaults.biometricButton`, `vaults.createButton`,
    `vaults.unencryptedButton`, `vaults.errorLabel`, `createVault.nameField`,
    `createVault.createButton`, `createVault.errorLabel`, the alert's `createVault.alertPasswordField`,
    `createVault.alertConfirmField`, `createVault.alertCreateButton`,
    `privacyCover`. (Views; covered by journey tests.) `LiveVaultsScreenFactory` lives in `Views/VaultsViewController.swift`.
    Vault password fields (lock screen, Create Vault's alert) set no `textContentType` (`nil`), so iOS never offers to
    save a vault password to the Keychain / password manager or suggest a strong one (decided 2026-11-11). Create Vault
    shows only the Name field (no content type) and Create on the screen; Create with a trimmed-empty name goes straight
    to the view model (the name error), otherwise it opens the "Set Password" alert (title "Set Password", message
    "Choose a password for this vault.", secure Password and Confirm Password fields, Cancel, Create); the alert's Create
    passes both fields to the view model and runs Create; Cancel changes nothing. Name field Return = Create. (A
    name + password + confirm form on one screen gets iOS Strong Password autofill even with no content type, which
    gave vaults passwords the user never typed; decided 2026-11-11, verify.)
- Changes (multiple-vaults-duress-password): SetupWizardViewModel.swift, LockScreenViewModel.swift, AppLockCoordinator.swift, Views/SetupWizardViewController.swift, Views/LockScreenViewController.swift, Views/PrivacyCoverView.swift, Views/LockPresenter.swift
- Contract changes (multiple-vaults-duress-password): `AppLockCoordinating.sceneDidConnect(window:)` loses `needsSetup`; `onUnlocked` removed; new `VaultsScreenFactory` (`makeLockScreen(onDone:onNeedsPro:)`); `AppLockCoordinating` gains `lock()` (both revised at the prototype, 2026-11-10); LockScreens no longer depends on VaultCrypto or Preferences.
- Contract: see `docs/api/LockScreens.md` (generated; do not edit by hand)

### Viewer
- Purpose: the full-screen file viewer and the rich-text editor.
- Depends on: VaultStore, Media, Export, SharedUI
- Files: FileViewerViewModel.swift, FilePageViewModel.swift, TextEditorViewModel.swift | Views/FileViewerViewController.swift, Views/FilePageViewController.swift, Views/TextEditorViewController.swift, Views/LiveViewerFactory.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import UIKit

  @MainActor
  protocol ViewerFactory: AnyObject {
      func makeViewer(items: [VaultItem], startingAt index: Int) -> UIViewController
      func makeEditor(for item: VaultItem) -> UIViewController
  }
  ```
- Behavior spec:
  - FileViewerViewModel: items exclude folders; current index and title follow paging (neighbours computed from the page asked about, no wrap); video controls only for `.video`; `formatTime` "m:ss" (0 for invalid or NaN); progress fraction is 0 when the duration is 0; skip ±10 s clamped to 0…duration, and leaving the time alone while the duration is unknown (0), so a skip before metadata loads doesn't restart the video; bars auto-hide 3 s after play starts, not while scrubbing or paused, and a tap toggles them (showing them restarts the hide while playing); after close no hide runs or starts; close removes this viewer's temp files only: the opened copies of encrypted items its pages report, never a plaintext vault file, and never `removeAllTemporaryFiles`; `startingAt` indexes the given array and maps to the same item once folders are removed.
  - FilePageViewModel: routing by kind: image → zoomable image, video → player from `VideoAssetProviding` (only the visible page drives the shared player), `.rtf` → opens the editor, and after Done the viewer is back on the page it was swiped from, as today, others → QuickLook of the opened file; decrypt work off the main thread; failure → "This file can't be opened.", including an image or video the view reports it can't decode.
  - TextEditorViewModel: load RTF (empty data → empty text); non-empty data not starting `{\rtf` is a load failure, since the system parser accepts any text starting with `{` and saving would overwrite that file; load failure → error shown and the editor read-only (no save ever runs); autosave 1 s after the last change, on disappear, on Done (one save, not two; as today, these save even with no change, while autosave needs a change); save failure → error; a failed save on Done keeps the editor open and offers "Try Again" (Done again) or "Discard Changes" (closes with no save, and the disappear save doesn't write the discarded edit); bold/italic toggle traits, underline toggles, size ±2 pt (min 8), alignment on the selection and typing attributes. Writes land in order, newest text last; the decrypted copy of an encrypted item is removed once read, on success or failure, and a plaintext item's real file never is.
  - Views: identifiers as today: `viewer`, `viewer.pager`, `viewer.closeButton`, `viewer.titleLabel`, `viewer.shareButton`, `viewer.playPauseButton`, `textEditor.doneButton`, `textEditor.textView`, and the rest of today's `viewer.*`, `textEditor.*` and `filePage.*` set. (Views.)
- Contract: see `docs/api/Viewer.md` (generated; do not edit by hand)

### Settings
- Purpose: security settings, the migration screen, the paywall and Recently Deleted.
- Depends on: VaultLock, LockMigration, VaultStore, Entitlements, SharedUI
- Files: SecuritySettingsViewModel.swift, MigrationViewModel.swift, PaywallViewModel.swift, RecentlyDeletedViewModel.swift | Views/SecuritySettingsViewController.swift, Views/MigrationViewController.swift, Views/PaywallViewController.swift, Views/RecentlyDeletedViewController.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import UIKit

  @MainActor
  protocol SettingsFactory: AnyObject {
      func makeSettings() -> UIViewController
      func makePaywall(onUnlock: @escaping () -> Void) -> UIViewController
      func makeMigration(onFinish: @escaping (Bool) -> Void) -> UIViewController
  }
  ```
- Behavior spec:
  - Feature multiple-vaults-duress-password: Settings is built for the open vault (the shell builds a factory per vault); its contract is unchanged.
  - SecuritySettingsViewModel rows: Pro ("Upgrade to Pro" with a disclosure indicator, opens the paywall / "Pro Unlocked" with a checkmark, tapping does nothing; live from `unlockedUpdates`); Vault (only when the open vault is encrypted; the section title is the vault's name): "Change Password", "Use <biometric name>" switch (hidden when biometrics aren't available; on = `currentUsesBiometrics`); Storage ("Recently Deleted"); then, last and only when the open vault is encrypted, a section of its own with "Delete This Vault" (no title). No Lock Mode section and no Re-encrypt Everything (removed). (Design tweaks, device test 2026-11-12: Delete This Vault moved out of the Vault section.)
  - Face ID note (design tweaks, device test 2026-11-12): when the switch is shown, the Vault section's footer, directly under the switch, reads "Note: only one vault can use <biometric name>." (e.g. "Face ID", "Touch ID"); no footer when the switch is hidden. The text comes from the view model.
  - Face ID switch: on → `setUsesBiometrics(true)`, off → `setUsesBiometrics(false)`; an error is shown and the switch shows the real state afterwards; busy while working.
  - Change Password: empty → "Password cannot be empty"; mismatch → "Passwords do not match"; wrong current → "Current password is incorrect"; `.passwordInUse` → "Choose a different password."; success → "Password changed successfully"; busy while working.
  - Delete This Vault: prompt "Delete This Vault?" / "Everything in "<name>" will be erased. This can't be undone. Enter the vault's password to confirm." with a password field, "Delete" (destructive) and "Cancel"; empty password ignored; → `deleteCurrentVault`; `.wrongPassword` → "Incorrect password"; other errors → their message; success → Settings reports it is done (the shell calls the coordinator's `lock()`: Settings is dismissed and the lock screen shows); busy while working.
  - MigrationViewModel: title "Encrypting Files"; status "Preparing…", "N% complete", "Complete"; failures → "Some Files Failed" with "These files couldn't be encrypted: a, b" and Retry / Skip; an empty `names` failure → "Some files couldn't be encrypted." with Retry / Skip; finished → dismiss after 0.5 s and report whether it completed fully; `.idle` after a run started (the vault closed) → dismiss at once, reporting not fully; `wantsBackgroundTime` is true while running and false when failed or completed.
  - MigrationViewModel, unreadable trash: `.unreadableTrash` → alert "Some Deleted Items Can't Be Read" / "They were encrypted with a key this vault no longer has, so they can never be restored or opened. Clear them to continue." with "Clear and Continue" (→ `clearUnreadableTrash`) and "Skip" (→ `skipFailed`); `wantsBackgroundTime` false while it shows; the alert reappears if the phase is reached again.
  - PaywallViewModel: "Store more than 100 files in a vault and keep more than one encrypted vault."; price or "Price unavailable"; Unlock → `.unlocked` → close and `onUnlock`; `.cancelled` → stays; `.pending` → "Purchase pending approval."; Restore → unlocked → close, else "No previous purchase found to restore."; StoreKit cancel → silent; busy state.
  - RecentlyDeletedViewModel: rows, most recently deleted first, with name, icon and "Deletes in N days" (N = 30 − whole days since deletion, at least 0; "1 day" singular); empty → "No recently deleted files" and Empty Trash disabled; Restore → item back and the browser refreshed; Delete Permanently → confirm first; Empty Trash → confirm; errors shown. The open vault's trash only.
  - RecentlyDeletedViewModel, unreadable trash: on each load (opening the screen), `hasUnreadableTrash()` true → prompt "Some Deleted Items Can't Be Read" / "They were encrypted with a key this vault no longer has, so they can never be restored or opened. Clear them now?" with "Clear" (destructive; → the store's `clearUnreadableTrash()`, then the list reloads; an error is shown) and "Not Now" (no change; an unreadable trash index still shows its error). Asked at most once per opening of the screen.
  - Settings screen (view): a "Done" button at the top right closes Settings (identifier `settingsDoneButton`); it is disabled while Settings is busy (changing a password, Face ID, deleting the vault), so the result alert is never lost; swipe-down still closes it where the system allows (fixed in verify, app review B4).
  - Views: identifiers as the code and journey tests have them (2026-11-03 naming): `upgradeToProCell`, `settings.changePasswordRow`, `settings.biometricRow`, `settings.biometricSwitch`, `settings.deleteVaultRow`, `settings.deleteVaultPasswordField`, `settings.recentlyDeletedRow`, `settings.table`, `settingsDoneButton`, `paywallUnlockButton`, `restoreButton`, `paywall.closeButton`, `migration.statusLabel`, `recentlyDeleted.emptyTrashButton` (the `settings.lockMode.*` rows and the re-encrypt row removed). (Views.)
- Changes (multiple-vaults-duress-password): SecuritySettingsViewModel.swift, MigrationViewModel.swift, PaywallViewModel.swift, Views/SecuritySettingsViewController.swift, Views/MigrationViewController.swift
- Contract: see `docs/api/Settings.md` (generated; do not edit by hand)

### Browser
- Purpose: the file browser grid and the folder picker: browsing, sorting, selection, folder and file operations, drag and
  drop, and starting import, export, viewing and settings.
- Depends on: VaultStore, VaultLock, VaultTransfer, Preferences, Media, Import, Export, SharedUI, Viewer, Settings
- Files: FileBrowserViewModel.swift, FolderPickerViewModel.swift, FileCellModel.swift | Views/FileBrowserViewController.swift, Views/FileCell.swift, Views/FolderPickerViewController.swift | VaultPickerViewModel.swift, Views/VaultPickerViewController.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import UIKit

  @MainActor
  protocol BrowserFactory: AnyObject {
      func makeRootBrowser() -> UINavigationController
      func reloadAll()
  }
  ```
- Behavior spec:
  - FileBrowserViewModel load: items from `contents` with the global sort; a load error is shown once the vault is unlocked or open (never silently kept stale); empty → "No files yet"; the settings button only at the root.
  - Feature multiple-vaults-duress-password: the browser shows the open vault (the shell builds a browser factory per vault; the contract is unchanged); the root's title is the vault's name (`root.name`); the root's bar has a Lock button (identifier `lockButton`, every vault) that calls the `onLock` action the shell gives (the coordinator's `lock()`); Browser no longer depends on LockScreens (revised at the prototype, 2026-11-10).
  - Bar layout (view; design tweaks, device test 2026-11-12): the folder's name is shown at the left of the bar, on the same line as and right after the leading buttons, not centred (title leading-aligned). In a subfolder the system back button is the only leading button and shows just the chevron "<" (no parent folder name), so the bar reads "< Folder name". On a vault's root the leading buttons are, in order, the settings gear (unchanged, identifier `settingsButton`) and the Lock button, which now looks like a back button: a chevron with a lock ("< 🔒", accessibility label "Lock", identifier `lockButton`, same action), followed by the vault's name. The Lock button is not drawn as part of the bar's button group (revised 2026-11-13, device retest): the gear keeps its own button at the far left, and the "< 🔒" stands apart from it as plain chevron-and-lock content with no button background (on iOS 26 and later its own item with `hidesSharedBackground = true`, not sharing the gear's glass group), directly before the vault's name, so the root reads "[⚙]  < 🔒 Vault name" the way a subfolder reads "< Folder name". Same identifier, label, action and tap target. Select mode is unchanged (Cancel at the left; the title follows it). The folder picker is unchanged.
  - Move/Copy to Vault: context menu "Move to Vault…" and "Copy to Vault…"; Select mode "To Vault" (identifier `browser.bulkVaultButton`; context menu items `browser.contextMenu.moveToVault`, `browser.contextMenu.copyToVault`) → "Move to Vault…" / "Copy to Vault…" / Cancel; → the vault picker; its target → `transfer(items, from: current store, to: target store, removingOriginals:)` with progress "Moving…" / "Copying…" (N of M); then the target is closed (`closeTransferTarget`, not for the unencrypted vault) and the grid reloads; `.limitReached` → the paywall; any failed → "N of M failed"; other errors → their message. One transfer at a time.
  - VaultPickerViewModel: "Unencrypted Vault" row only when the open vault is encrypted (→ `unencryptedVault`); password field and "Use Vault" (→ `openTransferTarget`); empty ignored; busy; `.wrongPassword` → "Incorrect password"; `.sameVault` → "These items are already in this vault."; other errors → their message; Cancel → no target. Identifiers `vaultPicker.unencryptedRow`, `vaultPicker.passwordField`, `vaultPicker.useButton`, `vaultPicker.cancelButton`, `vaultPicker.errorLabel`. The password field sets no password `textContentType` (`nil`): iOS never offers to save or suggest a vault password (decided 2026-11-11).
  - Sort: current option flips direction; another option → ascending; saved in Preferences; reload.
  - Open: folder → push a browser; `.rtf` → editor; other files → viewer with the folder's non-folder items starting at the tapped one.
  - New Folder / New Document: names trimmed; empty ignored; through the store (New Document opens the editor on the created item).
  - Select mode: toggle, "Select Items" / "N Selected", Cancel clears; bulk Delete (confirm "Delete N items?"), Move (picker), Copy (into the current folder), Export; bulk results report "N of M failed" when any fail.
  - Move: one pending move at a time; cancelling the picker clears it; the picker's choice moves exactly the pending items.
  - Context menu: Export, Move, Copy, Rename (prefilled), Delete (confirm; message mentions Recently Deleted).
  - Drag a cell onto a folder cell → move; onto a file cell → not a drop target; drops from other apps ignored.
  - A drag stays inside the app when the open vault's store `isEncrypted` or the item `isEncrypted` (feature multiple-vaults-duress-password; was `lockMode` and `pendingMigration`); only items of the unencrypted vault can be dragged out (the on-disk file of an encrypted item is ciphertext). This rule lives in a tested view model, with a test for each case and an unknown drag item (stays in).
  - Refresh after restore, import, editor close and unlock.
  - FolderPickerViewModel: lists subfolders of the current folder in the saved sort (as today), starting at the root; excludes the items being moved (and so their subfolders); "Move Here" returns the current folder; the picker's title is the current folder's name, as the browser's title (fixed in verify, app review B5); load error shown.
  - FileCellModel: name, size text (`ByteCountFormatter` file style; empty for folders), icon from `FileIconMapping`, thumbnail requested and cancelled on reuse, and ignored if the cell now shows another item.
  - Views: identifiers `fileGrid`, `settingsButton`, `sortButton`, `newFolderButton`, `newDocumentButton`, `importButton`, `selectButton`, `bulkDeleteButton`, `bulkMoveButton`, `bulkExportButton`, `bulkCopyButton`, `fileCell_<name>`, `emptyStateLabel`, `folderPickerMoveHere`, `folderPickerCancel`. (Views.)
- Changes (multiple-vaults-duress-password): FileBrowserViewModel.swift, Views/FileBrowserViewController.swift
- Contract: see `docs/api/Browser.md` (generated; do not edit by hand)

## App shell
- App shell: AppDelegate.swift, SceneDelegate.swift, AppDependencies.swift, Info.plist, Assets.xcassets, Base.lproj/LaunchScreen.storyboard, PostUnlockMaintenance.swift
- App shell tests: PostUnlockMaintenanceTests.swift, LaunchTemporaryFilesTests.swift, .swiftlint.yml, premiumTesting.storekit
- Shell responsibilities: `AppDependencies` builds every live service once (real Keychain, UserDefaults.standard, Documents root; in `-uiTesting` mode the in-memory and temporary ones and the seeds); SceneDelegate wires `AppLockCoordinator`, the root browser, purges expired trash and sweeps orphans after unlock (never while a migration is pending: the sweep would delete encrypted copies not yet indexed; the post-unlock steps live in a small unit-tested shell helper), resumes a pending migration after unlock, and clears the thumbnail cache when the app goes to the background with a lock set (presenting the Migration screen).
- Shell clean-ups (verify, app review 2026-11-04): the root's storage bundle is `AppStorage` (was `LegacyStorage`; no "legacy" wording left in the shell); the test-only launch paths (`-uiTesting`, `-unitTestHost`, the `UITEST_*` seeds, `SlowMigrationVaultStore`, the in-memory services and `InertProUnlock` as the shell uses them) compile only in Debug (`#if DEBUG`; unit and UI tests build Debug), so a Release build has none of them; each launch gives the vault store its own temp folder (`<tmp>/StoreTemporaryFiles/<UUID>`); at launch the earlier launches' folders (and `<tmp>/VaultStore`, where builds before this one kept decrypted temp copies) are listed on the main thread and deleted on a background task, so the first frame never waits and files created after launch are never touched; the lock's wipe on background is unchanged; the asset catalog has no unused sets (`Color`, `Image` removed) and `AccentColor` is a valid colour set with no colour, so the app keeps today's system tint ( `koalaT.png` moves to its own image set `koalaT`, unused).
- Shell changes (feature multiple-vaults-duress-password; done after the last module's units, before verify, by a code-writer brief naming the
  shell files, with PostUnlockMaintenanceTests updated by the test-writer): `AppStorage` adds the `Vaults/` folder
  (`Application Support/Vaults`; in `-uiTesting` mode next to the temporary vault) and builds no single key store or
  cipher any more; `AppDependencies` builds the vault lock with the factories (a `LiveMasterKeyStore` per blob account,
  a `LiveFileCipher` over it, a `LiveVaultStore` per vault with its own temp folder under this launch's temp root) and,
  for each vault that becomes `current`, that vault's services (thumbnails, import and export presenters, viewer,
  settings and browser factories); the composition root keeps no vault-specific service beyond the current one's.
  SceneDelegate: at connect, `upgradeIfNeeded` (a failure shows "Couldn't finish updating your vaults. Restart the app
  to try again." over the lock screen and the app carries on), then the root browser for `current` with the lock screen
  over it (`AppLockCoordinator` built with the `VaultsScreenFactory` and the paywall for `onNeedsPro`; the browser's
  `onLock` and Settings' vault-deleted callback call its `lock()`), then the unencrypted vault's trash purge; on each `currentUpdates` change: dismiss everything presented, clear the old vault's thumbnail cache, cancel a
  leftover encryption, build the new vault's services and replace the window's root browser; for an encrypted vault,
  then the post-open housekeeping (`PostUnlockMaintenance.run(vaultStore:now:)`: purge expired trash, then sweep orphans
  — no pending-migration check any more), then, if `hasUnencryptedFiles()`, the Migration screen with
  `encryptLeftovers(in:)`. On return to the foreground the unencrypted vault's trash is purged. The setup wizard, launch
  recovery, `onUnlocked` and the resume of a pending migration go. Debug seeds per the Constraints section;
  `SlowMigrationVaultStore` keeps only the encrypt step's delay.
- Shell changes (minors clean-up 2026-11-11, feature multiple-vaults-duress-password): `AppDependencies` passes the vault
  lock its decoy key-store factory (a `LiveMasterKeyStore` over a private in-memory Keychain, in Release too, so the
  in-memory Keychain type is no longer Debug-only or a second, minimal one is added); the `UITEST_LEGACY_LOCK` seed no
  longer writes `hasCompletedSetup`.

## Known issues
- Import predicts the store's clash name (" 1") for a queued file and copies the naming rule imperfectly ("a 1.txt" clashing → predicted "a 1 1.txt", stored "a 2.txt"), so a duplicate picked before the batch is sent may be imported again; nothing is lost or wrongly skipped. Simplest fix: drop the prediction (flush records the real names). Also: one batch test pins exact sizes [64, 32]; no test for cancellation flushing (same path as the tested failures) — LiveVaultImporter.swift, LiveVaultImporterBatchTests.swift — open, minor (Import unit 1 review)
- The root's "< 🔒" Lock image is pre-rendered with `chevron.left`, so in a right-to-left language the chevron points the wrong way (use `chevron.backward` or flip for RTL); its size beside the gear to be checked on device; two bar-layout tests are looser than needed (minimal back button accepted on either controller; template rendering not asserted) — FileBrowserViewController.swift, FileBrowserViewControllerTests.swift — open, minor (Browser unit 2 review, design tweaks)
- Move/Copy to Vault adds files one at a time (`addFile`), so moving a folder of thousands of files into an encrypted vault is slow (the target folder's index is rewritten after each file); memory stays flat (the store releases it per operation). Fix: batch with `addFiles` per target folder — LiveVaultTransfer.swift — open, minor (device test 2026-11-12)
- Case-only rename of a plaintext item ("a.txt" → "A.txt"): the tests pass in both modes, but `rename`'s conflict check calls `fileExists` on a case-insensitive volume, which by reading should give "A 1.txt"; why the tests pass is unexplained. Check on device (verify) and, if it misnumbers, apply the case-insensitive self-match fix — VaultFileOperations.swift (rename) — open, VaultStore
- Folder names, sizes and structure are plaintext on disk in an encrypted vault — FileSystem.swift:418-422 — feature encrypt-folder-names
- No way back in when the password blob is missing — AuthService.swift:48, LockScreen.swift:~158 — feature password-recovery
- No lockout after failed passwords — LockScreen.swift:136-166 — feature timed-lockout-for-failed-passwords
- No minimum password strength — SetupWizard.swift:206-213, SecuritySettings.swift:255-262 — feature minimum-password-strength
- `FileIcon` → UIImage/UIColor helper (`iconImageAndTint`, `tintColor(named:)`) is duplicated — Browser/Views/FileCell.swift, Settings/Views/RecentlyDeletedViewController.swift — open; Settings kept a private copy in RecentlyDeletedViewController and Browser's FileCell keeps its own, so two copies remain after the switch-over (no shared view helper yet)
- Locking the device with the app in the foreground during a migration can fail one file with an I/O error before the background key wipe (the legacy screen paused on protected-data-unavailable; the engine pauses only on a lock); the file shows under Retry/Skip — LiveLockMigrator.swift (`isInterruption`), SceneDelegate.swift — open; candidate fix: treat a data-protection error as an interruption, or pause on `sceneWillResignActive`
- Settings has no unit test for which migration it starts (encrypt with `.password`, decrypt with `nil`, re-encrypt keeping a pending target), and the Migration screen has no test that `onComplete` fires once after paused → running → completed — SecuritySettings.swift, MigrationScreenTests.swift — open; Settings' module (which replaces both screens) tests them
- A cancelled photo import carries on through its remaining photos (`importPhotos` counts `CancellationError` as a failure); nothing can cancel an import today, since the overlays have no Cancel — LiveVaultImporter.swift — open, matters only if a Cancel is added
- If the "N imported, M failed" alert is torn down without OK (a lock screen dismissing it), that import's camera-roll delete prompt never appears and its flow stays suspended; originals stay in the library — ImportPresenter.swift — open, rare
- Dismissing the import sheet or photo picker without a handler firing (tap outside on iPad, swipe down) keeps the flow's model and the screen it captures until the next import — ImportPresenter.swift — open, minor
- A folder emptied in an encrypted vault exports as its disk URL with its hidden `.vault_map` (folders are never `isEncrypted`, and the index is sealed and lists nothing, so no data leaves) — LiveVaultExporter.swift — open, cosmetic
- Backgrounding with a lock while the export picker is open removes the copies it is reading (the spec's background rule), so tapping Save afterwards fails inside Files with no message from the app — ExportPresenter.swift — open, safe but unhelpful
- If the app (not the user) closes the export picker, copies are removed after a 30 s grace for a late pick report; a pick reporting later than that would lose its source and fail with no message, and no plaintext leaks — ExportPresenter.swift — open, rare
- The drag-out rule trusts `lockMode` and `pendingMigration` to match the disk; no path in the app reaches a no-lock vault still holding ciphertext, only something outside it (a restored backup) could — FileBrowser.swift — open, accepted
- `VaultLockError` had no user-facing text of its own, so "other errors → their message" would read "The operation couldn't be completed" for `.keychain` and `.notUnlocked` — VaultLock/Contracts — fixed during LockScreens unit 1 (`errorDescription`, approved 2026-11-02)
- `onUnlocked` can still run if the app backgrounds and relocks during the lock screen's dismissal animation (the coordinator's completion doesn't recheck the state; the code-writer reports legacy doesn't guard this either) — AppLockCoordinator.swift — open, minor
- Adding a lock when nothing is encrypted: if `deleteMasterKeyBlob` succeeds and `createMasterKey` then fails, the blob is gone with no rollback; a retry says the password is missing until relaunch, which drops the pending record and leaves the vault without a lock (nothing lost, Keychain write failure only) — LiveVaultLock.swift:134-146 — open, rare
- After `unlock` succeeds and `prepareToAddLock` fails on the lock screen, the key stays loaded with `lockMode` .none until the process ends (`appDidEnterBackground` wipes nothing with no lock; only the lock screen is reachable meanwhile) — LiveVaultLock.swift:212-217 — open, minor
- The setup wizard's option cards are title-less buttons whose labels sit in a non-interactive stack, so VoiceOver has nothing to read (same as legacy) — SetupWizardViewController.swift:75-81 — open, accessibility
- `SetupWizardViewController.showBusy` decides in the view whether the overlay shows (`selectedOption != .none`), a small view decision with no test (same as legacy) — SetupWizardViewController.swift:175 — open, minor
- `LockPresenter.dismissLockScreen` guards a second call with `transitionCoordinator`: if UIKit silently refused a dismissal and a retry arrived during an unrelated transition, the retry is dropped (the user can enter the password again), and if `presentingViewController` clears early in the animation a second call could fire `onUnlocked` twice; neither has been seen, and a throwaway simulator test found UIKit queues rather than refuses — LockPresenter.swift:38-44 — open, theoretical
- `onUnlocked` relies on the state update's job being queued ahead of it, so housekeeping is already running when it waits; if the update lagged, a migration would start alongside the trash purge rather than after it (the sweep still skips while a migration is pending) — SceneDelegate.swift — open, minor
- Text to RTF on save stays on the main thread, as in legacy (`NSAttributedString` isn't Sendable and the stack rules ban the workarounds); a large document can hitch on save — TextEditorViewModel.swift — open, minor
- A temp folder emptied by the viewer's `removeTemporary` of a file stays until `removeAllTemporaryFiles` — FileViewerViewModel.swift — open, cosmetic
- The editor's `{\rtf` check opens an RTF with a leading BOM or whitespace read-only; today's app would open it editable (safe: nothing is overwritten) — TextEditorViewModel.swift — open, minor
- Encoding on save drops what the RTF text-system parser doesn't keep, such as embedded images, on a plain open and close, same as today's app — TextEditorViewModel.swift — open, same as legacy
- `FilePageViewModel.reportFailure()` allows a later `load()`, which re-opens the file, while a failed open stays final; the views never reload a failed page, so nothing uses this — FilePageViewModel.swift:74-80 — open, minor
- A video page is black while swiping onto it, until it appears and its item loads; today each page has its own player. This is the cost of the shared player that fixed the wrong-player bug — FilePageViewController.swift:57-59 — open, cosmetic
- Pages are recreated on each swipe, so each revisit of an encrypted file decrypts another temp copy until the viewer closes, same as today — FileViewerViewController.swift — open, same as legacy
- The buffered-fraction arithmetic lives in the controller, copied from legacy, untested — FileViewerViewController.swift:171-186 — open, minor
- Viewer and editor buttons have no `accessibilityLabel` and time labels use a fixed font, same as today — Viewer/Views — open, accessibility
- After backgrounding with a lock in the viewer, an encrypted video shows "This file can't be opened." and doesn't recover after unlock (the page isn't reloaded); what QuickLook shows there is unverified — Viewer/Views — open, check on screen
- If an autosave error alert is up when Done fails, the Try Again alert appears over it; both stay reachable and Discard clears everything — TextEditorViewController.swift:95-101 — open, minor
- If a lock dismisses the editor while the Try Again alert is up, the disappear save still runs, so the edit is saved if the disk has recovered, even if the user meant to discard — TextEditorViewModel.swift — open, accepted
- The viewer checks for a refused editor present one main-queue turn later (seen working on iOS 18.6 only); if UIKit scheduled it later while the viewer opens on an `.rtf`, which no browser path does, the viewer could stay on a blank page — FileViewerViewController.swift:249-262 — open, theoretical
- The under-lock `.rtf` page journeys assume the created document is encrypted rather than checking the file — J5ViewEditJourneyTests.swift — open, minor
- On the iPhone simulator the Browser tests can't check where the bulk Export, Import and long-press Export popovers anchor (an action sheet has no popover there); the anchor is one line at each call site, as today. Fix: internal anchor getters on FileBrowserViewController asserted by the tests, or check on iPad in verify — FileBrowserViewController.swift — open, minor
- The sort sheet's "Name ↑/↓" titles are built in the view from Preferences rather than by the view model, and the arrow is not asserted — FileBrowserViewController.swift (sortTapped) — open, minor
- Browser hides only `VaultStoreError.locked` load errors (the unlock refresh reloads); today every load error is hidden while the vault is locked, so another error during an auto-lock (e.g. a decrypt failure after the key is wiped) could alert under the lock screen. The view model has no lock state (Browser does not depend on VaultLock) — FileBrowserViewModel.swift — open, minor

- A cached grid thumbnail now arrives one main-actor turn after the cell is configured (async `ThumbnailProviding`), so a cell may flash its kind icon while scrolling — Browser/Views/FileCell.swift — open, cosmetic; a fix needs a sync cache accessor (contract change)
- Once, after an earlier crashed lock-change run, subfolders showed empty while the main screen listed them (files intact; decrypting showed them); not reproduced after a completed run. Suspected: a listing that throws `.locked` is hidden by the browser while no lock screen shows — FileBrowserViewModel.swift, LiveVaultLock.swift — open, watch for it on device
- `setUsesBiometrics(true)` interrupted by a close or switch while the Keychain write runs, when another vault held Face ID: that vault's biometric item is already replaced and can't be restored, so its next Face ID open ends in `.biometricChanged` (Face ID forgotten; password still works) — LiveVaultLock.swift:284-288 — open, rare (VaultLock unit 1 review, feature multiple-vaults-duress-password)
- `setUsesBiometrics(true)` whose key is wiped by a close mid-write reports `.io` instead of `.notOpen` — LiveVaultLock.swift:284, 298 — open, minor
- An overlapping `changePassword` and `createVault` (or two `changePassword`s) could leave two vaults sharing a password; only `createVault` calls are serialized. Needs two password sheets at once, which the UI doesn't allow — LiveVaultLock.swift:185-270 — open, minor
## Features
<!-- Accepted features, oldest first. -->

## Decisions log
- 2026-10-24: Every adopted screen stays `UI: UIKit`, logic in tested view models — adoption keeps behavior; changing UI technology at the same time doubles the risk — approved by the human (discussion)
- 2026-10-24: 14 modules as in `docs/adopt/module-proposal.md`; VaultStore stays one module because the index read-modify-write and the encrypted-or-not rule are shared invariants — approved by the human
- 2026-10-24: Bugs split by risk: data-loss bugs fixed in the baseline; key-lifecycle failure paths corrected in the VaultStore / VaultLock / LockMigration specs; cosmetic issues fixed where a module's spec covers them or queued — approved by the human
- 2026-10-24: The vault format to preserve is SVC5 (the discussion notes said SVC4; the code only has SVC5) — approved by the human
- 2026-10-26: Exporting a folder exports a decrypted copy of the whole folder (the memo said folders were skipped; today's app exported the encrypted tree) — decided by the human after the device check
- 2026-10-26: Gates run on the iOS 18.6 simulator (StoreKit test sessions fail under xcodebuild on iOS 26.x, Apple FB22237318) — approved by the human
- 2026-10-24: Folder names, sizes and structure stay plaintext on disk for now; "encrypt folder names" queued as a feature — approved by the human
- 2026-10-24: Encrypted mode is `lockMode != .none`, not "a key is loaded"; with a lock and no key, store operations throw `.locked` instead of writing plaintext — key-handling robustness (the human's goal for the adoption)
- 2026-10-26: After a reinstall, a leftover vault key is replaced when the vault holds no encrypted data; with encrypted data (e.g. a restored backup) the old password is still required — decided by the human (baseline row 24)
- 2026-10-24: Tests never use the real Keychain, UserDefaults.standard or Documents; every module takes them by injection; `-uiTesting` replaces `--uitesting` — the old tests and UI-test reset could delete a real vault
- 2026-10-24: Setup: app target Default Actor Isolation MainActor → nonisolated; legacy `AuthService`, `ImportService`, `ExportService` marked `@MainActor` explicitly (their previous implicit isolation, no behavior change) and the old tests that touch them (`AuthServiceTests`, `ImportServiceTests`, `SecuritySettings*Tests`) made `@MainActor` with async setUp/tearDown, assertions unchanged — approved by the human
- 2026-10-27: Logic in `Contracts/` (`FileKind(extension:)`, `VaultItem.kind`/`asDirectory`, `SortOption.displayName`, `FileIconMapping.icon`) is module code: never coverage-exempt, specced in the owning module and tested in its unit 1, and the test-writer brief names the contract file — the scaffold had to give these contract members bodies — requested by the human
- 2026-10-27: `VaultCryptoError` conforms to `LocalizedError` with the legacy wording (new cases get their own text) — alerts show `localizedDescription`; contract change found by the VaultCrypto legacy-test scan — approved by the human
- 2026-10-27: Legacy `exportMasterKeyData` / `loadMasterKey(from:)` and their tests are obsolete; `storeBiometricKey` / `unlockWithBiometricKey` replace their only callers — approved by the human
- 2026-10-27: Exception to "tests never use the real Keychain": KeychainStoreTests (only) use the simulator's real Keychain with a unique service per test, and the legacy-account test adds and deletes the service-less "com.KoalaTVault.password" item — the only way to test the SecItem wrapper — approved by the human
- 2026-10-27: Removing the lock (VaultLock.removeKeysAfterDecryption) deletes the legacy plaintext password item; VaultCrypto's unlock already does — gap found in the VaultCrypto switch-over review — approved by the human
- 2026-10-27: Hosted unit tests run with `-uiTesting` (test plan default argument) so legacy singletons get the in-memory Keychain, a temporary vault and a UserDefaults suite; `TestCrypto` preconditions fail closed otherwise — VaultCrypto switch-over
- 2026-10-27: During adoption stage 5, `gates --all` on adopt/main may fail only on the coverage of not-yet-built modules whose contracts hold real code (VaultStoreModels.swift, FileIconMappingContract.swift); that is expected until each module's unit 1 tests it, and doesn't hold up a module's merge, snapshot or tag. Every other gate must pass — Preferences merge — approved by the human
- 2026-10-27: StoreKitProUnlock takes injectable `purchase` and `sync` closures (defaulting to StoreKit) because every `Product.purchase()` in the hosted unit-test process fails on the iOS 18.6 simulator (storekitd: AMS 305 "Server canceled the purchase"); the J9 journey still covers a real purchase — Entitlements unit 1 — approved by the human
- 2026-10-27: A successful purchase ends with a queued refresh (closes a re-lock race found in the Entitlements unit 1 review); the legacy StoreKit config-file test is re-created against `ProUnlock.productID` — approved by the human (Entitlements legacy scan)
- 2026-10-28: The unit-test host gets a second test-plan argument, `-unitTestHost` (UI tests don't get it). With it, AppDependencies installs an inert `ProUnlocking` with no StoreKit listener, so it doesn't race StoreKitProUnlockTests. Purchase errors other than cancel now show "Purchase could not be completed.", not StoreKit's own text (the contract maps them to `.purchaseFailed`). Both from the Entitlements switch-over review; approved by the human.
- 2026-10-28: VaultStore names: a name starting with "." is `.invalidName` (dot names were hidden from listings and a root ".trash" folder would become the trash); a case-only rename renames in place in both modes (it became " 1"; the legacy app threw); copying a folder into itself or a descendant throws `.moveIntoItself` — VaultStore unit 1 review — approved by the human
- 2026-10-28: VaultStore unit 1 closed with the case-only rename question open (see Known issues); dot-named imports are Import's to handle, not `addFile`'s — decided by the human
- 2026-10-28: The trash index stays at `.trash/.trash_map`, as the legacy app writes it (tests had assumed the vault root); no on-disk move, so older builds still read the trash — VaultStore unit 2 — decided by the human
- 2026-10-28: VaultStore migration steps judge a file's form by its SVC5 header, not by index or trash-entry flags, so an interrupted trash-item conversion is repaired on rerun; the orphan sweep deletes only unlisted files that carry an SVC5 header — VaultStore unit 2 review (data-safety blocker), within the approved interrupt-safety rule
- 2026-10-28: An unindexed encrypted file (orphan) is ignored by Remove Lock and not counted by finishDecryption, as in the legacy app; it is normally a duplicate left by an interrupted step, and the sweep removes it after unlock — decided by the human
- 2026-10-28: VaultStore unit 2 gets a fourth attempt for one regression (an unreadable trash file made Recently Deleted fail) — approved by the human
- 2026-10-28: purgeExpiredTrash with an unreadable trash index throws without writing (spec kept); the legacy test that expected it to stay quiet is dropped; callers catch and ignore the error — VaultStore legacy-test scan — decided by the human
- 2026-10-28: Valid names are kept exactly as given, long names and names with spaces and symbols included; the legacy cases carry over as tests — VaultStore legacy-test scan — decided by the human
- 2026-10-28: VaultItem keeps synthesized (all-field) equality; callers that track items across reloads (the browser's multi-select) hold `VaultItem.ID`s, not items — VaultStore legacy-test scan — decided by the human
- 2026-10-28: VaultStoring gains `finishEncryption()` (approved contract change): the encrypt migration ends by re-encrypting plaintext indexes left by older builds, as the legacy app did, so no index naming encrypted files stays readable — VaultStore switch-over — approved by the human
- 2026-10-28: Empty Trash no longer shows an error when it fails part-way: `emptyTrash()` is best-effort by the approved contract (it removes what it can) — VaultStore switch-over review — follows the approved spec
- 2026-10-28: VaultStore error behaviors found by coverage are kept and specified: countFiles throws on an unreadable subfolder, migrating an unrecorded trash item throws `.notFound`, purge keeps going past a file it can't remove and then throws — VaultStore coverage triage — decided by the human
- 2026-10-28: The invalid-name message is "Names can't contain / or start with ." for both rules (one `.invalidName` error); journey 3 expects it — VaultStore switch-over gates — decided by the human
- 2026-10-29: `VaultStoreError` conforms to `LocalizedError` with the legacy `legacyErrorMessage(for:)` wording, as `VaultCryptoError` does; SharedUI's `AlertPresenting` shows `localizedDescription` and would otherwise show the system fallback text — contract change found in the SharedUI unit 1 review — approved by the human
- 2026-10-29: Backgrounding with a lock always wipes the key and removes store temp files, even if never unlocked (the legacy `hasAuthenticated` guard is dropped); `stateUpdates` publishes changes only, so callers read `state` first (replaces `vaultUnlockedNotification`, incl. the no-lock launch) — VaultLock switch-over legacy-test scan — decided by the human
- 2026-10-29: VaultLock switch-over review notes, left to later modules: LockScreen's `addPendingLockIfNeeded` (old pending encrypt with lockMode never saved) passes a `.passwordAndBiometrics` target to `prepareToAddLock`, unlike Settings which always adds `.password` first (no current flow produces that target; LockScreens/LockMigration should always add `.password`); Settings with a lock but no password blob now shows the password-missing error instead of re-prompting (follows the spec) — VaultLock switch-over review — orchestrator, recorded
- 2026-10-29: LockMigration edge cases specified (finishEncryption failure logged; step failures and decrypt leftovers as `.failed(names: [])` with Retry/Skip; no resume while failures await; Skip always completes; switchMode only when the mode differs, target never `.none`; locked resume goes straight to paused; `start` ignored while a run exists) — LockMigration unit 1 review — decided by the human
- 2026-10-29: The launch recovery for an encrypt left pending (`resolveUnfinishableEncryption` and PendingEncryptionLaunchTests) belongs to LockScreens, not LockMigration; it stays legacy until LockScreens and must run before `resumeIfPending` — LockMigration switch-over legacy-test scan — decided by the human
- 2026-10-30: Media's thumbnail cache key is item id + `dateModified` + `fileSize` (edited notes refresh their thumbnail, as legacy `ThumbnailService.cacheKey` did), and a folder thumbnail's first media follows the user's browser sort (Media now depends on Preferences) — Media unit 1 review — decided by the human
- 2026-10-30: Import names starting with ".": directly picked files and folders and photo names lose their leading dots before storing (a name of only dots counts as failed); hidden items inside a picked folder stay skipped, uncounted and unreported — Import unit 1 prerequisite — decided by the human
- 2026-10-30: Import spec gains today's folder merge (a same-named existing folder is merged into, FileSystem.swift:99-108), which the survey had omitted; no behavior change — Import unit 1 tests — orchestrator, recorded
- 2026-10-30: Contract change approved: `ImportError` is a `LocalizedError` with tested text, and `PhotoImportSource.loadFile` documents its own temp folder; `ImportContract.swift` now holds real code — Import unit 1 review — approved by the human
- 2026-10-30: Photos are stored under their real names. Random names were a regression from 420725e (2026-10-07), whose temp copy got a UUID name that was then stored, and the survey recorded it as today's behavior; photos imported since then keep their UUID names — Import unit 2 review — decided by the human
- 2026-10-30: Presenters may use SharedUI's views (`ProgressOverlayView`, `topmostPresentedController`) directly, though they are outside SharedUI's `Contracts/` — Import unit 2 review — approved by the human
- 2026-10-30: Export: same-named decrypted copies in one selection get " 1", " 2" in their shared temp folder (legacy handed the picker two URLs with the same name) — Export unit 1 — orchestrator, recorded
- 2026-10-30: Export makes copy names safe and handles cancellation, so decrypted data can never land outside the temp folder or outlive a cancelled export (`VaultItem.name` from an index is unvalidated on read) — Export unit 1 review — orchestrator, recorded
- 2026-10-30: Export messages follow today's app: "N item(s) saved to Camera Roll" with no failures (the memo gave only the failure wording); the "Exporting..." overlay loses its percentage, because the agreed contract has no progress callback — Export unit 2 tests — orchestrator, recorded
- 2026-10-30: ExportPresenter: the camera-roll overlay is title-only (the contract has no progress callback), a refused picker shows a message, any picker close removes the copies, and `completion` runs once on every ending — Export unit 2 review — orchestrator, recorded
- 2026-10-31: The drag-out check is a simple rule in the browser (a lock, a pending migration, or an encrypted item keeps the drag in the app), with no contract change; `needsDecryptedCopy` is deleted — Export switch-over — decided by the human
- 2026-10-31: Exporting an empty selection throws `.nothingToExport` (the old test expected an empty result; the screens block it) — Export legacy-test scan — decided by the human
- 2026-10-31: LockScreens spec gains the launch recovery assigned to it on 2026-10-29 and the pending-lock step on unlock (always `.password`, per the 2026-10-29 review note); it also depends on VaultCrypto and Preferences — LockScreens start — orchestrator, recorded
- 2026-11-02: `VaultLockError` conforms to `LocalizedError` with the legacy `legacyMessage` wording, as `VaultStoreError` and `ImportError` do; the LockScreens spec shows "their message" for unmapped errors and would otherwise show the system fallback text — contract change found before LockScreens unit 1's code — approved by the human
- 2026-11-02: LockScreens spec records what unit 1's review confirmed against legacy: the "Biometrics" fallback name, a prompt cancel, every error clearing the field, the cover hiding when active and locked, and `onUnlocked` waiting for the lock screen's dismissal — LockScreens unit 1 review — orchestrator, recorded
- 2026-11-02: Unlocking with `lockMode` .none and a pending encrypt unlocks first, then adds the lock, as today's app does. This replaces the 2026-10-31 order: `prepareToAddLock` first would let a mistyped password replace the saved one when nothing is encrypted yet, and the migration would then encrypt the files under the typo — LockScreens unit 1 — decided by the human
- 2026-11-02: LockScreens' views may use SharedUI's `ProgressOverlayView` and `topmostPresentedController` directly, as the 2026-10-30 decision lets presenters — LockScreens unit 2 review — orchestrator, recorded
- 2026-11-02: Adding Password + biometric encrypts under `.password` and turns biometrics on only after a full migration, as journey 8 and today's app do; the Settings bullet's "with the target" was wrong — Settings unit 1 — decided by the human
- 2026-11-02: `ProUnlockError` conforms to `LocalizedError` with today's three messages, as the other error types do — contract change found in Settings unit 1 — approved by the human
- 2026-11-02: Viewer unit 2 gets one more try after the retry cap, to fix one test that couldn't catch its own bug — Viewer unit 2 review — decided by the human
- 2026-11-02: A failed save on Done offers Try Again or Discard Changes, so a lasting failure can't trap the user and only an explicit choice loses an edit — Viewer unit 2 review — decided by the human
- 2026-11-02: Viewer and Browser may use `ExportPresenter` and `ExportSheetAnchor` directly, though they are outside Export's `Contracts/`; it's a UIKit flow, and a contract would gain little — Viewer unit 2 review — decided by the human
- 2026-11-02: An encrypted video that can't set up streaming shows "This file can't be opened." with no decrypted-copy fallback; the fallback parses the same header with the same key, so it would fail too — Viewer unit 2 review — orchestrator, recorded
- 2026-11-02: Viewer views keep today's identifiers as LockScreens' did, and `LiveViewerFactory` in `Views/` implements the contract's `ViewerFactory` — Viewer unit 2 — orchestrator, recorded
- 2026-11-02: LockScreens views use the identifiers the journey tests already use (`lockScreen.*`, `setupWizard.*`), not the five the memo named; the adoption keeps today's app and the journeys are its baseline, and no test named the memo's — LockScreens unit 2 — orchestrator, recorded
- 2026-11-02: LockScreens unit 1 gets one more try after the retry cap; the third failure was a test defect (a test expecting a second lock screen, against the spec's "once") — LockScreens unit 1 — decided by the human
- 2026-11-03: Settings spec gains three legacy behaviors the code already had: a store read error hides Re-encrypt Everything, the settings view model records the migration kind and the Migration screen's `wantsBackgroundTime`, and Recently Deleted lists newest deletions first — Settings unit 1 review — decided by the human
- 2026-11-03: Settings views use the identifiers the journey tests already use (`settings.lockMode.noLockRow`, `settings.changePasswordRow`, `paywall.closeButton`, `migration.statusLabel`, `recentlyDeleted.emptyTrashButton`, …), not the memo's names where they differ; same reasoning as LockScreens — Settings unit 2 — orchestrator, recorded
- 2026-11-03: The existing-password prompt (adding a lock over an old password blob; not in today's app) is titled "Enter Existing Password", uses `VaultLockError.existingPasswordRequired`'s text as its message, a "Continue" button and field `settings.existingPasswordField` — Settings unit 2 review — orchestrator, recorded
- 2026-11-03: Settings spec keeps three checks from the legacy tests: tapping "Pro Unlocked" does nothing; the Pro row shows a disclosure indicator when free and a checkmark when unlocked; the Migration screen reappearing while paused does not start the migration again. MigrationScreenTests.swift added to Settings' legacy tests — Settings switch-over scan — decided by the human
- 2026-11-03: The folder picker lists folders in the saved sort, as today's app does (the spec named no order; the first implementation sorted by name) — Browser unit 1 review — orchestrator, recorded
- 2026-11-03: Browser views use the identifiers the journey tests already use where they differ from the memo's (`browser.cell.<name>`, `browser.newDocumentButton`, `browser.bulk*Button`, `browser.cancelSelectButton`, `browser.emptyStateLabel`, `folderPicker.moveHereButton`, `folderPicker.cancelButton`); same reasoning as LockScreens and Settings — Browser unit 2 — orchestrator, recorded
- 2026-11-03: Browser unit 2 gets a fourth attempt after hitting the retry cap on test-file warnings and format errors; the browser's long-press menu moves to UIKit's multi-item `contextMenuConfigurationForItemsAt:point:` (the single-item form is deprecated) — Browser unit 2 — decided by the human
- 2026-11-03: The folder picker doesn't offer the folders being moved (or their subfolders), as the Browser spec says, instead of offering them and showing "A folder can't be moved into itself" as today; journey 3's into-itself test checks the folder is absent from the picker — Browser full gates — decided by the human
- 2026-11-04: Adoption legacy check (stage 6): Settings' switch-over is reopened to delete `Model/AuthService.swift` (dead since Settings; the memo gave it to Settings); `PostUnlockMaintenance.swift` and its tests, `KoalaTVaultTests/.swiftlint.yml` and `premiumTesting.storekit` are app shell; the empty template `KoalaTVaultTests.swift` is deleted; the baseline regression tests (`BaselineFix20_23Tests.swift` → VaultStore, `BaselineFix24Tests.swift` → VaultLock, helper `LegacyCryptoSupport.swift`) are checked against the modules' tests: redundant ones are deleted, the rest move into VaultStore's and VaultLock's tests — decided by the human
- 2026-11-04: VaultLock spec gains the line on what counts as encrypted data, describing today's `VaultEncryptedDataCheck` (including its safe side: anything unreadable counts as encrypted); the legacy check found 8 of BaselineFix24Tests' 9 cases not covered by VaultLock's tests, so they move into VaultLock's tests; all 10 of BaselineFix20_23Tests' cases are covered by VaultStore's tests (docs/adopt/legacy-scan-baseline-fix-20-23.md), so that file and LegacyCryptoSupport.swift are deleted — per the human's decision, recorded by the orchestrator
- 2026-11-04: The legacy check has no app-shell allowlist for test files, so `adopt finish` would always refuse PostUnlockMaintenanceTests.swift, .swiftlint.yml and premiumTesting.storekit; the human fixes the pipeline (`legacy_left` reads `- App shell tests:` under `## Legacy code`), and the app is unchanged — decided by the human
- 2026-11-04: `StoreKitProUnlockTests.updatesDeliverEachChangeOnce` is flaky (the refund sometimes lands after the test's wait under a full run); Entitlements' unit 1 is reopened for a test-only fix that waits robustly without changing what it checks — decided by the human
- 2026-11-04: Whole-app review (docs/adopt/app-review.md): fix now in the adoption — the combined-screen bugs B1-B5 (overlay under the nav bar, alert on a dismissing controller, export overlay stuck on "Preparing...", no Done in Settings, unnamed folder in the picker) and the app-shell clean-ups (rename `LegacyStorage`, test-only launch paths `#if DEBUG`, launch temp clean-up off the main thread, asset catalog); accessibility and Dynamic Type become the next feature; memo corrected (LockScreens and Settings dependencies, thumbnail clearing on background); the sweep, `clearCache(for:)`, migration-ordering and checkmark-disc items go to Later features — decided by the human
- 2026-11-04: Spec lines for the app-review fixes B1-B5 and the shell clean-ups (SharedUI ProgressOverlayView and Topmost, Export overlay, Settings Done, folder picker title, shell section) — approved by the human
- 2026-11-04: B3 also covers the "Saving to Camera Roll..." overlay (status "Saving N item(s)…"), found while writing Export's tests; same intent as the approved line (no overlay stuck on "Preparing...") — orchestrator, recorded
- 2026-11-09: Device test: decrypting stopped at once ("Some Files Failed") because `.trash/.trash_map` on the device was sealed with a key deleted by an earlier lock change in the old version (which never converted the trash); Retry then left the screen on "Preparing…" because the repeated identical `.failed` phase was not published. Fixed on the device by hand (the trash index replaced with an empty one). Fix now: Retry publishes `.running` before redoing a step; trash that can never be decrypted (strict definition in VaultStore's spec: key loaded and matching the vault, data read in full, authentication fails; trash only) is detected and, after the user confirms, cleared — prompted in Recently Deleted (Clear / Not Now) and on the migration screen (Clear and Continue / Skip). Contract changes: VaultStoring gains `hasUnreadableTrash()` and `clearUnreadableTrash()`; MigrationPhase gains `.unreadableTrash`; LockMigrating gains `clearUnreadableTrash()`. No VaultCrypto change (the store reads the bytes itself, so an authentication failure is told apart from a read error). A no-lock vault with an old sealed trash is left as it is (the clear is offered once a lock is added) — decided by the human
- 2026-11-09: VaultStore review of the unreadable-trash change: the definition is narrowed (only safer): an empty or too-short index is uncertain; files are judged on the header and first chunk the store read itself (an incomplete first chunk counts, being permanent damage); a symlinked or non-folder `.trash` is never cleared; kind (b) rewrites the trash index before removing — orchestrator, recorded (within the approved intent)
- 2026-11-09: VaultStore unit 2 (device-fixes) passed review on attempt 3. Trash listing, restore and migration steps now read trash file headers through the same probe (a copy of the leading bytes in a store temp folder; with strict, a temp failure is `.io`) — within the existing spec. Open minors, for the human at the end of the fixes: `TrashFileProbe.close()` removes the shared store temp folder when it created it (tiny race with a concurrent open/write; fix: never remove the parent); header-only reads copy 64 KiB per trash file (could be ~4 KiB) — orchestrator, recorded
- 2026-11-09: Coverage triage found that `migrateToEncrypted` on a trash item whose file has gone missing (entry kept) throws a misleading `.io("Decryption failed…")` while `migrateToDecrypted` skips it as done; pre-existing, unspecified, outside device-fixes — left as it is and listed for the human with the other open minors — orchestrator, recorded
- 2026-11-09: Device-test leftovers fixed now (decided by the human): the trash probe never removes the shared store temp folder; header-only probe reads copy only a few KiB; `migrateToEncrypted` on a trash item whose file is gone does nothing (as `migrateToDecrypted` and files outside the trash) instead of a misleading `.io`; the stray change-note comment in MigrationProgressTests is removed. VaultStore unit 2 and LockMigration unit 1 reopened — orchestrator, recorded
- 2026-11-09: Device test: re-encrypting the vault was killed by iOS at its 2 GB memory limit (JetsamEvent `per-process-limit`, 2098 MB), and every resume died again within seconds: the byte-for-byte check of an encrypted copy against its plaintext (`encryptedFile(at:matches:)` in VaultMigrationSteps) kept every chunk's read buffers alive until the step ended (no autorelease pool per chunk, unlike the cipher's own loops), so a large video was held in memory twice; the resume re-checks the interrupted video's leftover copy first. Fix: the check frees each chunk before the next (spec bullet added to migrateToEncrypted); VaultStore unit 2 reopened — orchestrator, recorded
- 2026-11-09: Device test after the memory fix: re-encrypting 17,700 files (23 GB) completed, but slowly: in a 9,090-file folder each file re-read, decrypted, checked and rewrote the whole folder index (~850 KB), about one file per second and slowing (quadratic in folder size; the trash has the same pattern via `correctedTrashMap`). Once, after an earlier crashed run, subfolders showed empty with the main screen listing them (files intact; decrypting showed them); not reproduced after the completed run. Suspected: a listing that throws `.locked` is silently skipped by the browser while no lock screen shows. Watch for it — orchestrator, recorded
- 2026-11-09: The slow migration in large folders is left as it is for now and queued as a feature (batching or index caching, to be chosen then) — decided by the human
- 2026-11-09: Adoption finished and the app accepted (checkpoints `adopted` and `app-accepted`): all 14 modules adopted, no legacy code left, journeys and the device test pass. Memo cleaned: per-module `Legacy files` / `Legacy tests` / `Callers to repoint` lines removed, `## Legacy code` reduced to `## App shell` (shell files, shell tests, shell responsibilities), `## Known issues` keeps only open items — decided by the human
- 2026-11-10: Feature multiple-vaults-duress-password (multiple vaults / duress password): one always-there unencrypted vault the app opens to, plus named encrypted vaults opened by typing their password on the Vaults screen (the password finds its vault, so any vault can be a decoy); the app-wide lock (setup wizard, lock screen, Lock Mode, encrypt/decrypt-everything) is removed; backgrounding closes an encrypted vault and returns to the unencrypted root with no lock screen; Face ID can open one chosen vault (iOS can't tell faces apart); free: one encrypted vault and 100 files per vault, Pro: more of both; the paywall on Create New Vault may reveal that a vault exists (accepted); vaults can be deleted (by password) but not renamed; Move/Copy to Vault replaces encrypting an existing vault; a 1.2 vault is upgraded once (locked → "My Vault", unlocked → the unencrypted vault) — decided by the human
- 2026-11-10: Feature multiple-vaults-duress-password design: encrypted vaults live in `Application Support/Vaults/<id>/` (outside Documents, so the unencrypted vault never sees them), each with its own blob account (the upgraded vault keeps the old one, so no Keychain item is rewritten) and an encrypted `.vault_info` name; no list of vaults is stored; the Face ID vault is named by a plain Keychain marker; one `VaultStoring` per vault with its mode fixed (VaultStore drops Preferences); VaultLock becomes the vault registry; LockMigration only encrypts an upgraded vault's leftovers, with no persisted record; new module VaultTransfer; Settings, Browser and the other screen modules are built per vault by the shell, so Import, Export, Media and Viewer don't change — orchestrator, approved with the memo
- 2026-11-10: Feature multiple-vaults-duress-password transition: the skeleton applies the final contracts at once. Code in modules not yet rebuilt that calls a removed member becomes a loud "Not implemented" stub, and the unit tests that reach it are disabled with `.disabled("feature multiple-vaults-duress-password: rebuilt in <Module> unit <n>")`; each rebuilt unit's test-writer replaces them. The app doesn't run end to end from the skeleton until the shell step after Browser; previews (mocks) work throughout. VaultLock's new unit 2 is built before its reopened unit 1 — orchestrator, approved with the memo
- 2026-11-10: Later-features item "Harden no sweep while a migration is pending" dropped: lock changes and their pending record are gone with feature multiple-vaults-duress-password — orchestrator, approved with the memo
- 2026-11-10: Feature multiple-vaults-duress-password, prototype revision: a lock screen comes back, because opening straight into the unencrypted vault could confuse users. It is the Vaults screen made full-screen: password, Open, Use Face ID (tapped, never automatic, so it can't open the real vault under duress), "Open Unencrypted Vault", "Create New Vault"; it shows at launch, on every return from the background (in any vault) and after Delete This Vault; the browser's Vaults button becomes a Lock button (every vault's root) and the Vaults sheet and Close Vault go. Contract changes: `AppLockCoordinating.lock()`, `VaultsScreenFactory.makeLockScreen(onDone:onNeedsPro:)` replaces `makeVaults(onNeedsPro:)`; Browser drops its LockScreens dependency; VaultLock unchanged — decided by the human
- 2026-11-10: VaultStore `remove`: a failed file delete after the index write puts the entry back, best-effort, so the item stays findable (reviewer finding, VaultStore unit 1 of feature multiple-vaults-duress-password) — orchestrator
- 2026-11-10: VaultStore `remove` on an encrypted file whose index entry is already gone deletes the file (no error) — decided by the human (VaultStore coverage triage, feature multiple-vaults-duress-password)
- 2026-11-10: VaultCatalog removes a blobless vault folder at launch only when it is empty, so an upgraded vault whose Keychain blob is missing (e.g. after a restore) never has its files deleted (reviewer finding, VaultLock unit 2) — orchestrator
- 2026-11-10: VaultLock races: a close/background/switch during a password check drops the check's result and wipes its key (opens and management calls throw `.notOpen`); createVault runs one at a time; setUsesBiometrics(false) in the unencrypted vault is a no-op (reviewer findings, VaultLock unit 1) — orchestrator
- 2026-11-10: LockMigration: only a listing failure gives `.failed(names: [])`; `finishEncryption` failing is logged and the run completes (the "closing-step failure" wording was left from the decrypt flow) — test-writer note, LockMigration unit 1 — orchestrator
- 2026-11-10: LockMigration: an `encryptLeftovers` during a cancelled run's last file waits for it, and a second cancel drops the waiting call; the store is held only while a run exists; a non-encrypted store sets `.idle` (reviewer findings, LockMigration unit 1) — orchestrator
- 2026-11-10: Settings' Views identifier line corrected to the names the code and journey tests use (2026-11-03 naming; the prototype's new `settings.*` identifiers); no behavior change — orchestrator
- 2026-11-11: vault password fields (lock screen, Create Vault, vault picker; Settings' alert fields already set none) set no password `textContentType`, so iOS never offers to save or suggest a vault password; Create Vault clears its password fields on success too — decided by the human (LockScreens unit 3 review, feature multiple-vaults-duress-password)
- 2026-11-11 (verify): Create Vault asks for the password and confirmation in a "Set Password" alert after Create, with
  only the name on the screen. On one screen, iOS Strong Password autofill took over the password fields despite no
  content type, so a new vault got a password the user never typed (5 journey tests); an experiment showed the
  alert avoids it, as the 1.2 setup wizard did. `.oneTimeCode` rejected (misdescribes the field). No contract change;
  LockScreens unit 3 reopened — decided by the human (feature multiple-vaults-duress-password)
- 2026-11-11 (verify, review minors): (1) a password search with no encrypted vault runs one decoy PBKDF2 derivation, so
  a wrong password no longer reveals "no encrypted vaults" by its speed (VaultLock + shell; counting vaults by timing stays
  out of scope); (2) `.vault_info` written with complete file protection; (3) Preferences contract clean-up:
  `hasCompletedSetup` removed, `PendingMigration`/`MigrationKind`/`pendingMigration` replaced by
  `hasPendingEncryptMigration` + `clearPendingMigration()` (contract change approved); (4) lock-screen vault listing and
  Keychain reads on the main actor accepted as they are — decided by the human (feature multiple-vaults-duress-password)
- 2026-11-12: Device test: folders stayed empty for 15–20 s after opening an encrypted vault (the human's 23 GB vault): after each open the shell runs `sweepOrphans` then `hasUnencryptedFiles`, each walking the whole vault (the second reads every file's header) in one actor step, so the browser's listings waited behind them. Fix now: both work one folder at a time and let other store operations run between folders; `hasUnencryptedFiles` stops at the first plaintext file. No contract change; VaultStore unit 2 reopened — decided by the human (feature multiple-vaults-duress-password)
- 2026-11-12: Device retest: very large folders (~9,000 files) still took seconds to show. Simulator timing (scratch branch `scratch/large-folder-timing`): a 9,000-file listing ~1.2 s (per-item root-relative path ~650 ms, per-file stat ~265 ms, sort ~245 ms; index decrypt 17 ms); `hasUnencryptedFiles` on that folder ~3 s in one step. Fix now, VaultStore internals only: per-folder work once per listing, prefetched attributes, precomputed sort keys; housekeeping breadth-first, the check in batches of 256 files. Files appearing as they load (contract + Browser change) only if still needed after a retest — decided by the human (feature multiple-vaults-duress-password)
- 2026-11-12: Device retest passed (large folders fast). Design tweaks folded into the feature before acceptance: (1) the lock screen logo gets the rounded corners it was meant to have (the frame was full-width, so its rounded corners fell outside the logo) — LockScreens unit 3; (2) the folder's name at the left of the bar right after the back button, the back button just "<", and on a vault's root the Lock button looks like "< 🔒" after the gear (gear unchanged) — Browser unit 2; (3) Settings: Delete This Vault in its own section at the bottom, and "Note: only one vault can use <Face ID>." under the switch — Settings units 1 and 2. Dark mode dropped (the app already follows the phone). No contract change — decided by the human (feature multiple-vaults-duress-password)
- 2026-11-13: Device retest: the "< 🔒" Lock button still sat in the bar's button group beside the gear; it moves out of that group, with no button background, right before the vault's name; the gear stays at the far left (chosen over moving the gear right or drawing the lock into the title). View-only change in Browser unit 2; no contract change — decided by the human (feature multiple-vaults-duress-password)
- 2026-11-12 (device test): importing a 9,000-JPG folder from Files crashed part-way (memory). Cause: per file the import listed the whole destination (`findItem`) and the store read, re-listed and rewrote the whole folder index, and the import's one long task never released the temporary memory. Fix now: every store operation releases its memory; `findItem` looks up one name; new `VaultStoring.addFiles(_:to:)` writes the index once per batch (contract change, approved with this memo); Import lists the destination once and adds in batches of 64. Move/Copy to Vault stays per file (known issue) — decided by the human (feature multiple-vaults-duress-password)
