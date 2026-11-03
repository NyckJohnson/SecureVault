# KoalaTVault outline

<!-- Adoption memo. The behavior spec describes what the app does today (from docs/adopt/survey-*.md), except where
`## Known issues` says a bug is fixed in the baseline or in a module: there the spec states the corrected behavior.
Contracts are redesigned to the pipeline's standards. -->
- A cached grid thumbnail now arrives one main-actor turn after the cell is configured (async `ThumbnailProviding`), so a cell may flash its kind icon while scrolling — View/LegacyFileCell.swift:110-120 — open: check on device in verify; a fix needs a sync cache accessor (contract change)

## Purpose
KoalaTVault is an offline, encrypted file store for iPhone and iPad. The user keeps files (photos, videos, documents) in
a private vault on the device, browses them in folders, views images and videos, edits rich-text notes, and moves files in
and out. The vault can be left open (no lock), locked with a password, or locked with a password plus Face ID / Touch ID;
with a lock, file names and contents are encrypted on disk (SVC5 format). A one-time "Unlock Pro" purchase lifts the free
limit of 100 files. The app is accepted by App Store Connect (1.2, build 4) but not yet released.

## User journeys
1. **First launch / setup** — a new user wants to protect the vault. The setup wizard appears full-screen over the browser
   with three cards: No Lock (default), Password, "Password + <Face ID|Touch ID>" (disabled without biometrics). Continue
   with No Lock → wizard closes, browser shows the empty vault. Continue with a password mode → "Set Password" alert with
   password and confirm → progress "Setting password…" → wizard closes. Ends when the browser shows and the lock mode is set.
   - Failure path: empty password → "Password cannot be empty"; mismatch → "Passwords do not match"; the alert closes and
     the user retries. A Keychain or biometric failure shows the error, the wizard stays, and nothing is left half set up
     (a created key is rolled back).
   - Failure path: a vault password already exists on the device (e.g. after a reinstall). If the vault is empty (no
     encrypted file, index or trash entry on disk), the stale key and biometric item are deleted and a new key is created.
     Otherwise (e.g. restored from a backup) the typed password must unlock it; a wrong one shows "A vault password already
     exists on this device. Enter that password." and that key is never replaced.
2. **Unlock** — a returning user with a lock wants in. Cold launch or return from background shows the lock screen
   ("KoalaTVault Locked", password field, Unlock, and "Use Face ID/Touch ID" in biometric mode). In biometric mode the
   prompt starts automatically once the app is active. A correct password or biometric match dismisses the lock screen and
   the browser reloads. Ends when the browser shows.
   - Failure path: wrong password → "Incorrect password", field cleared; no lockout, no delay, no wipe.
   - Failure path: biometric cancel → nothing shown; biometric lockout / not enrolled / no passcode → their own message;
     enrolment changed or item missing → "Face ID changed. Use your password." and the next password unlock re-creates the
     biometric item; other failures → "Biometric authentication failed". The password field always stays usable.
   - Failure path: no password blob in the Keychain → "Your vault password is missing from this device." (no way forward
     yet; feature `password-recovery`).
   - Backgrounding with a lock shows a privacy cover at once; entering the background wipes the key and plaintext temp
     files; returning shows the lock screen.
3. **Browse** — the user wants to find and organise files. The browser shows a grid of folders and files (thumbnails,
   name, size), folders first, sorted by the global sort option. Tap a folder → push its browser; back returns. Bar
   buttons: New Folder, New Document, Import, Sort, Select; the settings gear only on the root. Sort sheet: Name, Type,
   Date Modified; tapping the current option flips ↑/↓. Long press: Export, Move, Copy, Rename, Delete. Select mode: tap
   to toggle, "N Selected", bulk Delete, Move, Export, Copy, Cancel. Move opens the folder picker at the root ("Move
   Here", "Cancel"); Copy always copies into the current folder with " 1", " 2" names; drag a cell onto a folder cell to
   move it. Ends when the files are where the user wants them.
   - Failure path: empty folder shows "No files yet"; empty names are ignored; a name with "/" or starting with "." → "Names can't contain / or start with .";
     a move into the item's own folder does nothing; a folder moved into itself or a subfolder → "A folder can't be moved
     into itself"; any failed operation shows its error (bulk operations report how many failed).
4. **Import** — the user wants to add files. Import → sheet "Choose Files", "Choose Folder", "Choose Photos", "Cancel".
   Files/Folder: document picker, multi-select → progress "Importing..." → grid reloads. Photos: photo picker (images and
   videos, unlimited) → "Importing Photos..." → if any failed, "N imported, M failed" → then iOS asks to delete the
   imported originals from the photo library. Same name and same content is skipped; same name, different content gets
   " 1". Ends when the grid shows the new files.
   - Failure path: free tier and the import would pass 100 files (all non-hidden files in the vault, subfolders included,
     trash excluded) → nothing is imported and the paywall opens after the picker closes.
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
   tap → Restore / Delete Permanently / Cancel; "Empty Trash" with a confirm. Items older than 30 days are purged
   automatically when the vault is opened. Ends when the item is restored or gone.
   - Failure path: restoring into a folder that has the same name gives " 1"; restoring when the original folder is gone
     recreates it; a failure shows its error.
7. **Export / share** — the user wants a file outside the vault. Export (context menu, bulk, viewer share) → sheet "Save
   to Files", "Save to Camera Roll" (only when the selection has images or videos), "Cancel". Save to Files → "Exporting..."
   → document picker (copies); decrypted copies are removed when the picker closes. Save to Camera Roll → "N saved, M
   failed". Ends when the copy is saved.
   - Failure path: a failure part-way removes every decrypted copy made so far and shows the error; photo access denied →
     "Allow KoalaTVault to add photos in Settings.".
   - Folders are exported whole: an encrypted folder becomes a decrypted copy of its whole tree with the original names
     (no index files, no UUID names). Encrypted items can't be dragged out to other apps (drags stay inside the app).
8. **Change lock mode** — the user wants more or less protection. Settings ("Security") → Lock Mode: No Lock, Password,
   Password + Face ID, and "Re-encrypt Everything" when a lock is on and some files are still plaintext; Password section:
   Change Password. No Lock → "Remove Lock?" → decrypt migration → lock removed. Password/biometric from No Lock → set a
   password (or enter the existing one) → encrypt migration under Password; for Password + Face ID, Face ID is turned on
   once the migration completes fully. Password ↔ Password + Face ID → immediate switch. Change
   Password → current, new, confirm → "Password changed successfully". The migration screen shows "Encrypting Files" /
   "Decrypting Files", a progress bar and "N% complete". Ends when the new mode is in force and every file (trash
   included) matches it.
   - Failure path: some files fail → "Some Files Failed" listing them, Retry (failed files only) or Skip (the lock mode
     stays as it was for a removal; for an addition the remaining plaintext files show "Re-encrypt Everything").
   - Failure path: backgrounding pauses the migration ("Paused — unlock to continue"); after unlock it resumes. A kill
     resumes it after the next unlock (or launch, without a lock).
   - Failure path: wrong current password → "Current password is incorrect".
   - Failure path: adding Password + Face ID and the migration ends incomplete (Skip, Close or a kill) → the vault stays
     Password; after Skip or Close the alert "Face ID wasn't turned on because some files aren't encrypted yet. Use
     Re-encrypt Everything, then turn on Face ID." A Face ID failure after a full migration shows the error and keeps Password.
9. **Paywall** — a free user wants more than 100 files. Settings "Upgrade to Pro" or the import limit opens the paywall
   ("Unlock Pro", "Store more than 100 files.", price, Unlock, Restore Purchases, X). Unlock → App Store purchase → paywall
   closes, Settings shows "Pro Unlocked". Ends when Pro is unlocked.
   - Failure path: cancel → paywall stays; pending → "Purchase pending approval."; restore with nothing → "No previous
     purchase found to restore."; price unavailable → "Price unavailable" and Unlock still works.

## Screens and navigation
- **Setup wizard**: choose the lock mode on first launch. UI: UIKit. Presented full-screen over the browser at launch when
  setup is not done. Serves journey 1.
- **Lock screen**: unlock by password or biometrics. UI: UIKit. Presented full-screen, unanimated, over the topmost screen
  at launch and on foreground when locked; a privacy cover hides content while inactive. Serves journey 2.
- **File browser**: the vault grid; root of the navigation stack, one instance per folder. UI: UIKit. Serves 3, 4, 6, 7.
- **Folder picker**: choose a move target. UI: UIKit. Form sheet from the browser. Serves 3.
- **File viewer** (with file pages): view images, video, QuickLook kinds. UI: UIKit. Full-screen from the browser. Serves 5, 7.
- **Text editor**: edit `.rtf`. UI: UIKit. Full-screen nav from the browser (or a viewer page). Serves 5.
- **Security settings**: lock mode, password, Pro, storage. UI: UIKit. Form-sheet nav from the browser's gear. Serves 6, 8, 9.
- **Migration**: encrypt/decrypt progress. UI: UIKit. Full-screen from Settings, or from the app shell to resume. Serves 8.
- **Recently Deleted**: the trash. UI: UIKit. Pushed from Settings. Serves 6.
- **Paywall**: Unlock Pro. UI: UIKit. Form sheet from Settings or from an import. Serves 9.
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
  shapes and the UserDefaults keys stay readable as they are.
- Tests never touch the real Keychain, UserDefaults.standard or the real Documents vault: every module takes its
  storage (Keychain access, UserDefaults suite, vault root URL) by injection; the composition root wires the real ones.
- The `-uiTesting` launch argument (replacing today's DEBUG `--uitesting`) starts the app with an empty vault in a
  temporary directory, an in-memory Keychain and a throwaway UserDefaults suite; `UITEST_SEED_FILE_NAME`,
  `UITEST_SEED_FILE_COUNT`, `UITEST_PASSWORD` and `UITEST_FAIL_MIGRATION_FILE` keep their meaning in that mode only.

## Out of scope
- New features: the queued backlog (below) is built after the adoption through `/feature`.
- Moving screens to SwiftUI: later `/feature` work.
- Changing the SVC5 format, the blob format or the Keychain layout.
- Repo-root `art samples/`, `previews/`, `vault_test_files/`: not app code; no module owns them.
- `API-Memo.md` and `REVIEW.md` stay as references; this memo and `docs/api/` replace them for new work.

## Later features
<!-- Already queued in the backlog (ios-pipeline status feature list). -->
- Minimum password strength: REVIEW.md S2.
- iCloud backup: back up the vault to iCloud.
- Password recovery: a way back in when the password (or its Keychain blob) is lost.
- Multiple vaults / duress password.
- Timed lockout for failed passwords.
- Encrypt folder names: folder names, sizes and structure are plaintext on disk today.
- Vault size in Settings: show the current total size of the vault (and file count) in the Storage section.

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

### PendingMigration (UserDefaults `pendingMigrationType` = "encrypt"/"decrypt", `pendingMigrationTargetLockMode`)
| Field | Type | Notes |
| --- | --- | --- |
| kind | MigrationKind | encrypt / decrypt |
| targetLockMode | LockMode? | encrypt only |

### On-disk and Keychain formats (kept as they are)
- **Vault root**: the app's Documents folder; real subfolders with plaintext names. Hidden entries (`.vault_map`, `.trash`,
  `.trash_map`) are never listed.
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
- **UserDefaults**: `hasCompletedSetup` (false), `lockMode` ("none"; unknown → none), `sortOption` ("name"),
  `sortDirection` ("ascending"), `pendingMigrationType`, `pendingMigrationTargetLockMode`, `entitlement.isUnlocked`.

## Build order
1. VaultCrypto (depends on: none)
2. Preferences (depends on: none)
3. Entitlements (depends on: none)
4. VaultStore (depends on: VaultCrypto, Preferences)
5. SharedUI (depends on: VaultStore)
6. VaultLock (depends on: VaultCrypto, Preferences, VaultStore)
7. LockMigration (depends on: VaultStore, VaultLock, Preferences)
8. Media (depends on: VaultStore, VaultCrypto, Preferences)
9. Import (depends on: VaultStore, Entitlements, SharedUI)
10. Export (depends on: VaultStore, SharedUI)
11. LockScreens (depends on: VaultLock, SharedUI)
12. Viewer (depends on: VaultStore, Media, Export, SharedUI)
13. Settings (depends on: VaultLock, LockMigration, VaultStore, Entitlements, SharedUI)
14. Browser (depends on: VaultStore, Preferences, Media, Import, Export, SharedUI, Viewer, Settings)

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
  - encrypt/decrypt(data): round trip with the same context; any listed context that matches decrypts (tried in order); other key or context → `.decryptionFailed`; no key → `.noKeyLoaded`; nonce differs per call.
  - encryptFile: writes SVC5 (layout in Data models) via a staging file with `.complete` protection, then atomically moves/replaces; source == destination works; no key → `.noKeyLoaded` and no output; empty file → header only; exactly 1 MiB → one chunk; over 2 TiB or short read → `.encryptionFailed`.
  - decryptFile: round trip; wrong magic, flipped header byte, swapped or foreign chunk, dropped last chunk, truncation, trailing bytes, or size mismatch → `.decryptionFailed`, an existing destination left untouched; success replaces the destination.
  - streamInfo: reads the header only; bad magic or truncated header → `.decryptionFailed`; chunkSize outside 1…16 MiB or total over 2 TiB → `.decryptionFailed`.
  - decryptChunk: index in range → that chunk's plaintext; out of range → `.decryptionFailed`.
  - errorDescription (logic in `Contracts/`): noKeyLoaded "No encryption key is loaded."; noMasterKeyBlob "No password has been set up."; masterKeyAlreadyExists "A master key already exists."; wrongPassword "Incorrect password."; emptyPassword "Password cannot be empty."; corruptBlob "The stored password data is damaged."; invalidKeyData "The stored key is invalid."; encryptionFailed "Encryption failed."; decryptionFailed "Decryption failed. The data may be damaged."; biometricItemMissing "Face ID key not found. Use your password."; biometricCancelled "Authentication was cancelled."; biometryLockedOut "Too many attempts. Use your password."; biometryNotEnrolled "Face ID is not set up."; passcodeNotSet "Set a device passcode to use Face ID."; keychain(status) "Couldn't access secure storage (error <status>)." (the status number appears in the text).
- Contract: see `docs/api/VaultCrypto.md` (generated; do not edit by hand)
- Legacy files: Model/CryptoService.swift; Model/AuthService.swift (part: biometric Keychain item store/read/delete, legacy password item delete)
- Legacy tests: KoalaTVaultTests/CryptoServiceTests.swift (export/load-key tests obsolete: the raw key never leaves VaultCrypto)
- Callers to repoint: AppDelegate.swift, Model/AuthService.swift, Model/FileSystem.swift, Model/VaultResourceLoaderDelegate.swift, View/Migration.swift

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
  enum MigrationKind: String, Sendable, Codable { case encrypt, decrypt }
  struct PendingMigration: Sendable, Codable, Equatable, Hashable {
      var kind: MigrationKind
      var targetLockMode: LockMode?
  }

  protocol PreferencesStoring: AnyObject, Sendable {
      var hasCompletedSetup: Bool { get set }
      var lockMode: LockMode { get set }
      var sortOption: SortOption { get set }
      var sortDirection: SortDirection { get set }
      var pendingMigration: PendingMigration? { get set }
  }
  ```
- Behavior spec:
  - Defaults on an empty store: `hasCompletedSetup` false, `lockMode` .none, `sortOption` .name, `sortDirection` .ascending, `pendingMigration` nil.
  - Each property round-trips through the injected UserDefaults under the keys in Data models, with raw values "none"/"password"/"passwordAndBiometrics", "name"/"type"/"dateModified", "ascending"/"descending", "encrypt"/"decrypt".
  - Values written by a store are read by a new store on the same suite (persistence).
  - Unknown raw values read as the defaults (an unknown `pendingMigrationType` reads as nil; an unknown or missing target of an encrypt migration reads as a nil target).
  - pendingMigration nil removes both keys; a target is stored only for `.encrypt` and ignored for `.decrypt`.
  - displayName: "Name", "Type", "Date Modified". (Contract logic in `Contracts/PreferencesModels.swift`; unit 1 tests it.)
  - Thread-safe: reads and writes from several threads don't crash or tear.
- Contract: see `docs/api/Preferences.md` (generated; do not edit by hand)
- Legacy files: Model/PreferencesService.swift
- Legacy tests: KoalaTVaultTests/PreferencesServiceTests.swift
- Callers to repoint: AppDelegate.swift, SceneDelegate.swift, Model/AuthService.swift, Model/FileSystem.swift, View/SetupWizard.swift, View/Migration.swift, View/FileBrowser.swift, View/SecuritySettings.swift

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
- Legacy files: Model/EntitlementService.swift
- Legacy tests: KoalaTVaultTests/StoreKitConfigurationTests.swift
- Callers to repoint: AppDelegate.swift, Model/FileSystem.swift, View/SecuritySettings.swift, View/LegacyPaywallViewController.swift

### VaultStore
- Purpose: the vault on disk: folder indexes, browse and sort, open and write, folder and file operations, trash, the
  per-file migration steps, the orphan sweep and temp files. One module because all of these share the index
  read-modify-write and the rule for whether the vault is encrypted.
- Depends on: VaultCrypto, Preferences
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
      case stillEncrypted(count: Int)
      case io(String)
  }
  extension VaultStoreError: LocalizedError { var errorDescription: String? { get } }

  protocol VaultStoring: Sendable {
      var root: VaultDirectory { get }
      func contents(of directory: VaultDirectory, sortedBy option: SortOption, _ direction: SortDirection) async throws -> [VaultItem]
      func open(_ item: VaultItem) async throws -> URL
      func write(_ data: Data, to item: VaultItem) async throws
      func createFolder(named name: String, in directory: VaultDirectory) async throws -> VaultItem
      func createDocument(named name: String, in directory: VaultDirectory) async throws -> VaultItem
      func addFile(from source: URL, named name: String, to directory: VaultDirectory) async throws -> VaultItem
      func findItem(named name: String, in directory: VaultDirectory) async throws -> VaultItem?
      func move(_ item: VaultItem, to directory: VaultDirectory) async throws
      func copy(_ item: VaultItem, to directory: VaultDirectory) async throws -> VaultItem
      func rename(_ item: VaultItem, to name: String) async throws -> VaultItem
      func moveToTrash(_ item: VaultItem) async throws
      func trashContents() async throws -> [VaultItem]
      func restore(_ trashed: VaultItem) async throws -> VaultItem
      func deletePermanently(_ trashed: VaultItem) async throws
      func emptyTrash() async
      func purgeExpiredTrash(now: Date) async throws -> Int
      func countFiles() async throws -> Int
      func itemsToMigrate(toEncrypted: Bool) async throws -> [VaultItem]
      func migrateToEncrypted(_ item: VaultItem) async throws
      func migrateToDecrypted(_ item: VaultItem) async throws
      func finishDecryption() async throws
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
  - Encrypted mode is `lockMode != .none` (read from Preferences at the start of each operation). Each operation captures the key once at its start; in encrypted mode with no key, every operation that reads or writes an index or file content throws `.locked` before changing anything.
  - Index writes are serialized (the live store is an actor): concurrent imports, moves and migration steps never lose an index entry.
  - Index read: absent → empty; encrypted with the key → decoded (AAD ".vault_map", then folder-relative path, then ""); plaintext JSON → decoded in either mode and rewritten encrypted on the next write in encrypted mode; unreadable → `.indexUnreadable(folder:)` and the index is never overwritten.
  - Index write: encrypted in encrypted mode, plaintext JSON in plaintext mode; never plaintext in encrypted mode.
  - contents: non-hidden entries; mapped files show their original name with `isEncrypted` true; unmapped files and folders show the disk name; folders first, then by option and direction (name: case-insensitive; type: by extension then name; dateModified); ids are root-relative paths and equal across listings.
  - open: plaintext item → its disk URL; encrypted → decrypted into a new temp folder as `<temp>/<name>`; failure → `.io` / `.locked` and no temp file left.
  - write: encrypted item → plaintext staged in temp, encrypted, atomically replaces the file, plaintext removed; plaintext item → atomic write; key missing → `.locked`, file unchanged.
  - Names: any other name is valid and kept exactly as given (long names up to 200 characters, spaces and symbols such as "&" and "!") through addFile, createFolder, createDocument, rename and contents, in both modes.
  - createFolder: plaintext name on disk in both modes, conflict → " 1"; empty, containing "/", or starting with "." → `.invalidName`.
  - createDocument: empty `.rtf` (".rtf" added if missing) through the same path as addFile, so it is encrypted and indexed in encrypted mode; conflict → " 1" (an existing document is never truncated); empty, containing "/", or starting with "." → `.invalidName`.
  - addFile: encrypted mode → encrypted as a new `<UUID>` and indexed in one serialized step; plaintext mode → copied with its name; name conflict → " 1"; key missing → `.locked`, nothing written; source unreadable → `.io`.
  - findItem: the item with that display name (encrypted or plaintext), or nil.
  - move: encrypted file → index entry moved and file moved, conflicts on the display name resolved with " 1"; plaintext → moved with " 1" on conflict; into its own folder → no change; a folder into itself or a descendant → `.moveIntoItself`; a failure part-way leaves the item findable in exactly one place.
  - copy: new item in the target with " 1", " 2" names; encrypted copies stay encrypted and decrypt to the same content; a folder into itself or a descendant → `.moveIntoItself`, nothing copied.
  - rename: encrypted → index only; plaintext → disk rename; conflict → " 1"; a name that differs from the item's own only in letter case is not a conflict (renamed in place, both modes); empty, containing "/", or starting with "." → `.invalidName`.
  - moveToTrash: moves into `.trash/<newUUID>` and records a TrashEntry (relative original folder, deletedAt now, encryption state, original names) in one serialized step; a failure leaves the item where it was; folders keep `isDirectory` true.
  - trashContents: one flat list of trash items with `deletedAt`; unreadable trash index → `.indexUnreadable`; a trash file whose header can't be read is still listed with its stored flag (listing and restore never fail because of one unreadable file; migration steps stay strict).
  - restore: back to the original folder (recreated if missing; older absolute paths re-based onto the current root; a target outside the root, through `..`, a hidden folder or a symlink, or a bad disk name → `.io`, nothing moved, entry kept); name conflict → " 1"; encrypted items re-indexed; unknown trash item → `.notFound`.
  - deletePermanently: removes the file and its entry; unknown → `.notFound`.
  - emptyTrash: removes everything in `.trash` and its index, best-effort.
  - purgeExpiredTrash: removes entries with `deletedAt` more than 30 days before `now` and returns how many; unreadable index → throws without writing; a file that can't be removed keeps its entry (retried on the next purge) while the other expired items are still removed, the map is saved, and then the first error is thrown.
  - countFiles: non-hidden files under the root, subfolders included, trash and indexes excluded; a subfolder that can't be read → `.io` (never a partial count).
  - itemsToMigrate(toEncrypted: true): every plaintext file under the root and in the trash; (false): every encrypted file under the root and in the trash.
  - migrateToEncrypted: plaintext file → encrypted `<UUID>`, indexed, plaintext removed (in that order); if an encrypted entry with the same original name already holds identical content, only the plaintext is removed; different content → kept as a new " 1" item. Trash items are re-encrypted in place and their entry updated. Interrupt-safe at every step: a rerun finds a plaintext file whose identical encrypted copy is already indexed and only removes the plaintext; an incomplete encrypted copy is dropped with its entry; a trash item's real form is read from the file's SVC5 header (not the entry's flag), so a conversion killed between the map update and the file replace is corrected on the next itemsToMigrate / migrate / finishDecryption and any leftover hidden `.migrating` staging file is finished or removed. A plaintext file is skipped as already migrated only if it really is an SVC5 file.
  - migrateToDecrypted: encrypted file → plaintext with its original name (" 1" on conflict), entry removed, encrypted file removed (in that order); decrypt failure leaves the encrypted file and its entry. A rerun after an interrupted decrypt (matching plaintext already there) finishes without a duplicate. Trash items are decrypted in place by the same header rule. Either migration step on a trash item that has no trash entry → `.notFound`, nothing changed.
  - finishDecryption: any encrypted file left (judged by its SVC5 header, trash included) → `.stillEncrypted(count:)`; otherwise every `.vault_map` is deleted and `.trash_map` is rewritten as plaintext, so the vault lists with no key afterwards.
  - finishEncryption: the last step of an encrypt migration; in encrypted mode with the key, every `.vault_map` under the root (folders inside `.trash` included) that is still plaintext JSON is rewritten encrypted (".vault_map" context) with the same entries, and a plaintext `.trash/.trash_map` likewise (".trash_map"); indexes that are already encrypted or are unreadable are left byte-for-byte as they are; no key → `.locked` before anything is written; plaintext mode → no change.
  - hasUnencryptedFiles: true if any plaintext file is under the root or in the trash.
  - keyMatchesVault: true when the loaded key decrypts the root index, or when there is no encrypted index to check; false otherwise.
  - sweepOrphans: only in encrypted mode with the key loaded; in each folder whose index exists and reads, deletes extensionless UUID-named files the index doesn't list and that carry an SVC5 header (a plaintext file with such a name is kept); folders with no index, an unreadable index, and the trash are never swept.
  - Temp files: `makeTempDirectory` creates a unique folder under the app temp folder; `removeTemporary` removes one; `removeAllTemporaryFiles` removes everything the store created.
  - Contract logic (in `Contracts/VaultStoreModels.swift`; unit 1 tests it): `FileKind(extension:)` maps every extension in Data models › FileKind (one case per extension, also upper and mixed case); an empty or unknown extension → `.other`. `VaultItem.kind` comes from the display name's extension (an encrypted item's original name, not its UUID disk name). `asDirectory`: a folder → `VaultDirectory` with the item's name, diskURL and rootURL; a file → nil.
  - errorDescription (logic in `Contracts/VaultStoring.swift`, next to `VaultStoreError`; tested in a reopened VaultStore change, one asserting test per case): indexUnreadable "Couldn't read the vault's file index. It may still be locked, or a file may have become corrupted."; locked → the text of `VaultCryptoError.noKeyLoaded` ("No encryption key is loaded."); invalidName "Names can't contain / or start with ."; notFound "This item no longer exists."; moveIntoItself "A folder can't be moved into itself"; stillEncrypted(1) "1 file is still encrypted.", stillEncrypted(n) "<n> files are still encrypted."; io(message) → the message itself. Alerts show `localizedDescription`, so this is the text the user sees.
- Contract: see `docs/api/VaultStore.md` (generated; do not edit by hand)
- Legacy files: Model/FileSystem.swift (part: vault types, index, browse/sort, open/write, create/move/copy/rename/delete, trash, migration steps, orphan sweep, temp files); Model/LegacyFileKind.swift; Model/EncryptedCopyChecker.swift (split out of the old CryptoService in VaultCrypto's switch-over: complete-encrypted-copy and same-content checks for copy and the migration steps)
- Legacy tests: KoalaTVaultTests/VaultTestCase.swift, KoalaTVaultTests/FileSystemTests.swift, KoalaTVaultTests/EncryptedFileSystemTests.swift, KoalaTVaultTests/FileSystemMappingIntegrityTests.swift, KoalaTVaultTests/TrashTests.swift, KoalaTVaultTests/SortTests.swift, KoalaTVaultTests/CopyTests.swift, KoalaTVaultTests/ConflictResolutionTests.swift, KoalaTVaultTests/VaultDirectoryTests.swift, KoalaTVaultTests/VaultItemTests.swift, KoalaTVaultTests/FileKindTests.swift, KoalaTVaultTests/EdgeCaseTests.swift, KoalaTVaultTests/AdditionalEdgeCaseTests.swift
- Callers to repoint: AppDelegate.swift, SceneDelegate.swift, Model/AuthService.swift, Model/ExportService.swift, Model/ImportService.swift, Model/ThumbnailService.swift, View/FileBrowser.swift, View/LegacyFileCell.swift, View/FileIconProvider.swift, View/FilePage.swift, View/FileViewer.swift, View/FolderPicker.swift, View/Migration.swift, View/RecentlyDeleted.swift, View/SecuritySettings.swift, View/TextEditor.swift

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
  - ProgressOverlayView: title, progress bar, status "Preparing...", optional Cancel; `update(progress:status:)` and `dismiss()` are main-actor and safe to call repeatedly. (View; covered by journey tests.)
  - UIViewController+Topmost: `topmostPresentedController` follows `presentedViewController` to the end. (View.)
- Contract: see `docs/api/SharedUI.md` (generated; do not edit by hand)
- Legacy files: View/ProgressOverlay.swift, Model/ErrorPresenting.swift, View/UIViewController+Presentation.swift, View/FileIconProvider.swift
- Legacy tests: none
- Callers to repoint: SceneDelegate.swift, Model/AuthService.swift, Model/ExportService.swift, Model/ImportService.swift, Model/ThumbnailService.swift, View/FileBrowser.swift, View/LegacyFileCell.swift, View/Migration.swift, View/LegacyPaywallViewController.swift, View/RecentlyDeleted.swift, View/SecuritySettings.swift, View/SetupWizard.swift, View/TextEditor.swift

### VaultLock
- Purpose: the key lifecycle and lock state: set up a lock, unlock, lock on background, change password, switch between
  password and biometric modes, add a lock (before an encrypt migration), and remove the keys after a decrypt migration.
- Depends on: VaultCrypto, Preferences, VaultStore
- Files: LockState.swift, BiometricInfo.swift, LiveVaultLock.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import Foundation

  enum LockState: Sendable, Equatable { case open, locked, unlocked }
  enum BiometricKind: Sendable, Equatable { case none, faceID, touchID }

  enum VaultLockError: Error, Equatable, Sendable {
      case wrongPassword, existingPasswordRequired, emptyPassword, passwordMissing, notUnlocked
      case biometricsUnavailable, biometricCancelled, biometryLockedOut, biometryNotEnrolled, passcodeNotSet
      case biometricChanged, keychain(Int32)
  }
  extension VaultLockError: LocalizedError { var errorDescription: String? { get } }

  @MainActor
  protocol VaultLocking: AnyObject, Sendable {
      var state: LockState { get }
      var lockMode: LockMode { get }
      var biometricKind: BiometricKind { get }
      var biometricsAvailable: Bool { get }
      func stateUpdates() -> AsyncStream<LockState>
      func setUp(mode: LockMode, password: String?) async throws
      func unlock(password: String) async throws
      func unlockWithBiometrics() async throws
      func appWillResignActive() -> Bool
      func appDidEnterBackground()
      func appWillEnterForeground()
      func changePassword(current: String, new: String) async throws
      func switchMode(to mode: LockMode) async throws
      func prepareToAddLock(mode: LockMode, password: String) async throws
      func removeKeysAfterDecryption() async throws
  }
  ```
- Behavior spec:
  - state: lockMode .none → `.open`; a lock and no key → `.locked`; a lock and key loaded → `.unlocked`; every change is published once on `stateUpdates`. Only changes are published (the current state is not replayed): subscribers read `state` first, then follow `stateUpdates`; there is no "vault unlocked" notification.
  - Launch: with a lock, starts `.locked`; with none, `.open`.
  - setUp(.none): lockMode .none; nothing in the Keychain changes.
  - setUp(password modes): no blob → key created; blob exists and the vault holds no encrypted data (no index, encrypted file or trash entry) → the stale blob and biometric item are deleted and a new key created; blob exists otherwise → the password must unlock it (`.existingPasswordRequired` on a wrong one; that blob is never replaced); then (biometric mode) the biometric item is stored; then lockMode is written; any failure after a key was created deletes that blob and biometric item, wipes the key, leaves lockMode unchanged and rethrows; empty password → `.emptyPassword`; biometric mode without biometrics → `.biometricsUnavailable`. Ends `.unlocked`.
  - unlock(password): right → key loaded, `.unlocked`; in biometric mode the biometric item is then refreshed and a failure there is reported in the log only; wrong → `.wrongPassword`, stays `.locked`; no blob → `.passwordMissing`; empty → `.emptyPassword`.
  - unlockWithBiometrics: item read → key loaded; key not matching the vault (`VaultStoring.keyMatchesVault` false) → key wiped, item deleted, `.biometricChanged`; cancel → `.biometricCancelled`; missing/invalidated → `.biometricChanged`; lockout → `.biometryLockedOut`; not enrolled → `.biometryNotEnrolled`; no passcode → `.passcodeNotSet`; lockMode not biometric → `.biometricsUnavailable`.
  - appWillResignActive: returns true (show the privacy cover) when a lock is set and the state is `.unlocked`; nothing is wiped.
  - appDidEnterBackground: with a lock → key wiped, all store temp files removed, `.locked`; with none → nothing.
  - appWillEnterForeground: with none → `.open`; otherwise the state is unchanged (the lock screen shows if `.locked`).
  - changePassword: current verified then blob rewrapped; afterwards the new password unlocks and the old one gives `.wrongPassword`; wrong current → `.wrongPassword`, blob unchanged; empty new → `.emptyPassword`; files stay readable (same key).
  - switchMode(.passwordAndBiometrics) from .password: key required (`.notUnlocked`); biometric item stored, then lockMode; failure → lockMode unchanged and error thrown.
  - switchMode(.password) from .passwordAndBiometrics: lockMode written, then the biometric item deleted (a delete failure is thrown after lockMode is set; the item is harmless).
  - switchMode to or from .none is not allowed here (those go through LockMigration) → `.notUnlocked`.
  - prepareToAddLock(mode, password) from .none: no blob → key created; blob exists → as in setUp (empty vault: replaced; otherwise the password must unlock it, `.existingPasswordRequired`); biometric item stored for biometric mode (failure → rollback as in setUp); then lockMode = mode. Ends `.unlocked`.
  - removeKeysAfterDecryption: in order: biometric item deleted, lockMode .none, blob deleted, key wiped; each step is safe to repeat; a failure throws and leaves the later steps for the next call. Ends `.open`.
  - removeKeysAfterDecryption also deletes the legacy plaintext "com.KoalaTVault.password" Keychain item (through `KeychainAccessing.delete(account:)`, errors ignored), so a device that never password-unlocked since upgrading doesn't keep it.
  - errorDescription (logic in `Contracts/VaultLockContract.swift`, next to `VaultLockError`; tested with one asserting test per case): wrongPassword "Incorrect password"; existingPasswordRequired "A vault password already exists on this device. Enter that password."; emptyPassword "Password cannot be empty"; passwordMissing "Your vault password is missing from this device."; notUnlocked "Unlock the vault first."; biometricsUnavailable "Biometric authentication isn't available on this device."; biometricCancelled, biometryLockedOut, biometryNotEnrolled, passcodeNotSet, biometricChanged "Biometric authentication failed"; keychain(status) "A Keychain error occurred (<status>)." (the status number appears in the text). Screens show `localizedDescription` for errors they don't map themselves, so this is the text the user sees.
- Contract: see `docs/api/VaultLock.md` (generated; do not edit by hand)
- Legacy files: Model/AuthService.swift (part: lock mode, password create/verify/change/remove, biometric enable/remove/authenticate, isLocked/hasAuthenticated, scene lifecycle wipe and temp clean-up)
- Legacy tests: KoalaTVaultTests/AuthServiceTests.swift (part: AuthServiceTests, AuthServiceForegroundTests)
- Callers to repoint: AppDelegate.swift, SceneDelegate.swift, View/FileBrowser.swift, View/LockScreen.swift, View/Migration.swift, View/SecuritySettings.swift, View/SetupWizard.swift

### LockMigration
- Purpose: encrypt or decrypt the whole vault when a lock is added or removed, with pause, resume, retry, skip and a
  persisted pending record so a kill never leaves the lock and the files disagreeing.
- Depends on: VaultStore, VaultLock, Preferences
- Files: MigrationProgress.swift, LiveLockMigrator.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  enum MigrationPhase: Sendable, Equatable {
      case idle
      case running(done: Int, total: Int)
      case paused(done: Int, total: Int)
      case failed(names: [String])
      case completed(fully: Bool)
  }

  @MainActor
  protocol LockMigrating: AnyObject, Sendable {
      var phase: MigrationPhase { get }
      var pending: PendingMigration? { get }
      func phaseUpdates() -> AsyncStream<MigrationPhase>
      func start(_ kind: MigrationKind, target: LockMode?) async
      func resumeIfPending() async
      func retryFailed() async
      func skipFailed() async
  }
  ```
- Behavior spec:
  - start: writes the pending record before the first file, lists `itemsToMigrate`, then migrates one file at a time; phase goes `.running(0, n)` … `.completed`; a second `start` or `resumeIfPending` while running does nothing (one runner).
  - Encrypt: the caller has already added the lock (VaultLock.prepareToAddLock); every plaintext file, trash included, is encrypted; on completion the pending record is cleared and (with a target) lockMode equals the target.
  - Decrypt: lockMode stays as it was while running; every encrypted file, trash included, is decrypted; then the list is re-scanned and any new encrypted file migrated; then `finishDecryption`, then `removeKeysAfterDecryption`, then the pending record is cleared (last). A kill at any point leaves a state that `resumeIfPending` completes.
  - Key wiped (app backgrounded) → the file in progress either finishes or fails without being counted as failed; phase `.paused`; the next unlock's `resumeIfPending` continues from the remaining files.
  - A file that fails → collected; at the end `.failed(names)` with the files' display names.
  - retryFailed: migrates only the failed files again.
  - skipFailed: `.completed(fully: false)`; the pending record is cleared; decrypt → the lock and keys are kept; encrypt → lockMode stays at the target (the remaining plaintext files show "Re-encrypt Everything").
  - resumeIfPending: with a pending record and (for a lock) the key loaded → continues; nothing pending → no change; locked → `.paused`.
  - `UITEST_FAIL_MIGRATION_FILE` (UI-test mode only) makes that file fail.
  - Encrypt's closing `finishEncryption` failing with the key loaded is logged and the migration still completes (as the legacy app; a folder index may stay plaintext).
  - A listing or closing-step failure with the key loaded (not a lock) → `.failed(names: [])`; the error text is logged only; Retry redoes that step, Skip completes not fully. Settings shows the failure generically when `names` is empty.
  - Files still encrypted after a decrypt (`VaultStoreError.stillEncrypted(count:)` from `finishDecryption`) → `.failed(names: [])`; Retry re-lists and migrates them; Skip keeps the lock and keys.
  - While failures await Retry or Skip, `resumeIfPending` does nothing (the screen doesn't return after every unlock).
  - Skip after an encrypt always completes, even if switching to the target lock mode fails (logged).
  - Encrypt with a target calls `switchMode(to: target)` only if the current mode differs; the target is never `.none`, and an encrypt pending with lockMode `.none` is the launch recovery's job, not the migrator's.
  - `resumeIfPending` while locked goes straight to `.paused` (no `.running` published first).
  - `start` while a run exists (running, paused or failed) does nothing; a new migration starts only from `.idle` or `.completed`.
- Contract: see `docs/api/LockMigration.md` (generated; do not edit by hand)
- Legacy files: View/Migration.swift (part: migration state machine; it still reads `LegacyStorage.current.masterKeyStore.isKeyLoaded` directly); Model/AuthService.swift (part: `LegacyMigrationCompletion.finalize`)
- Legacy tests: KoalaTVaultTests/MigrationTests.swift; KoalaTVaultTests/LockMigration/MigrationFinalizationTests.swift (a legacy XCTest moved there in VaultLock's switch-over, not a spec test; delete in the switch-over)
- Callers to repoint: SceneDelegate.swift, View/SecuritySettings.swift (the launch recovery must run before `resumeIfPending`)

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
- Legacy files: Model/ThumbnailService.swift, Model/VaultResourceLoaderDelegate.swift
- Legacy tests: KoalaTVaultTests/MediaPipelineTests.swift (part: VaultResourceLoaderDelegateTests, ThumbnailServiceTests)
- Callers to repoint: SceneDelegate.swift, Model/AuthService.swift, View/LegacyFileCell.swift, View/FilePage.swift

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
  - importItems: counts every file in the selection (folders recursively) and checks the limit before importing anything (all or nothing); folders are recreated with their structure; a picked folder (or subfolder) whose name matches an existing folder in the destination is merged into it rather than getting " 1", and if the name belongs to a file the folder gets a free name; each file goes through `VaultStoring.addFile`; same name and same SHA-256 as an existing item → skipped and counted in `skippedDuplicates`; same name, different content → " 1"; progress reported from 0 to 1; a failure part-way keeps the earlier files and rethrows; security-scoped URLs are opened and closed.
  - importPhotos: checks the limit for the count first; imports one at a time; returns the asset IDs that were imported or were already in the vault, and the failure count; temp copies are removed.
  - A photo is stored under its real name: the name iOS gives for it plus its type's extension, kept as is if the name already has an extension of that type (a dot alone doesn't make one: "Photo 2024.10.01" → "Photo 2024.10.01.heic"; JPEGs use ".jpg"); "photo" only when iOS gives no name.
  - Duplicate check in an encrypted vault decrypts the existing same-name file to a temp folder to hash it and removes it afterwards.
  - Names starting with ".": `VaultStoring.addFile` accepts them, but in a no-lock vault they would be hidden from listings (and a root ".trash" would clash with the trash), so Import handles them. A file or folder picked directly, or a photo's `suggestedName`, has its leading dots removed before it is stored (".env" → "env", ".trash" → "trash"), and the duplicate check uses the new name; it counts toward the limit. A name that is only dots counts as `failed` (`importPhotos`: in `failed`, with nothing imported for it). Hidden files and folders inside a picked folder are skipped: not imported, not counted toward the limit, not reported in `ImportResult`.
  - ImportError text: `.unreadableSource(name)` → `Couldn't read "<name>".`; `.fileLimitReached(limit)` → `This vault has reached its limit of <limit> files.`
  - ImportPresenter (view): sheet "Choose Files", "Choose Folder", "Choose Photos", "Cancel" anchored to the Import button on iPad; document pickers (multi-select); photo picker (images and videos, no limit, requests read-write access first); Cancel in any picker closes it; limit → picker closes then the caller's `onLimitReached` runs (the paywall); "Importing..." / "Importing Photos..." overlays with progress; "N imported, M failed" when any failed; then the camera-roll delete for the imported asset IDs (iOS shows its own confirmation); other errors shown after the picker closes.
- Contract: see `docs/api/Import.md` (generated; do not edit by hand)
- Legacy files: Model/ImportService.swift; Model/FileSystem.swift (part: importItems, importSingleFile, importFolder, importFromCameraRoll, checkImportAllowed, countFiles, isDuplicate, sha256Hex)
- Legacy tests: KoalaTVaultTests/ImportServiceTests.swift, KoalaTVaultTests/FileImportLimitTests.swift
- Callers to repoint: View/FileBrowser.swift

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
  - ExportPresenter (view): sheet "Save to Files", "Save to Camera Roll" (when allowed), "Cancel"; "Exporting..." overlay; document picker for export as copies, `cleanUp` on pick or cancel; after a camera-roll save, "N item(s) saved to Camera Roll" ("1 item", "4 items") when nothing failed and "N saved, M failed" when any failed, skipped items not mentioned; `.nothingToExport` → "Nothing to export."; a camera-roll save shows a title-only "Saving to Camera Roll..." overlay; a picker that can't open removes the copies and shows "Couldn't open the Files picker."; a picker closed by anything, the user or the app, removes the copies; the caller's `completion` runs exactly once however the export ends, Cancel included; access denied → "Allow KoalaTVault to add photos in Settings."; errors shown.
- Contract: see `docs/api/Export.md` (generated; do not edit by hand)
- Legacy files: Model/ExportService.swift; Model/FileSystem.swift (part: prepareForExport, needsDecryptedCopy, copyDecrypted, exportToCameraRoll; `needsDecryptedCopy` is not replaced: the drag rule below takes its place)
- Legacy tests: KoalaTVaultTests/ExportServiceTests.swift
- Callers to repoint: View/FileBrowser.swift, View/FileViewer.swift

### LockScreens
- Purpose: the setup wizard, the lock screen, the privacy cover, and presenting the lock over whatever is on screen.
- Depends on: VaultLock, VaultCrypto, Preferences, SharedUI
- Files: SetupWizardViewModel.swift, LockScreenViewModel.swift, AppLockCoordinator.swift | Views/SetupWizardViewController.swift, Views/LockScreenViewController.swift, Views/PrivacyCoverView.swift, Views/LockPresenter.swift
- Protocol (draft; lives in `Contracts/`):
  ```swift
  import UIKit

  @MainActor
  protocol AppLockCoordinating: AnyObject {
      func sceneDidConnect(window: UIWindow, needsSetup: Bool)
      func sceneWillResignActive()
      func sceneDidEnterBackground()
      func sceneDidBecomeActive()
      var onUnlocked: (() -> Void)? { get set }
  }
  ```
- Behavior spec:
  - SetupWizardViewModel: three options (none, password, password + `biometricKind` name: Face ID, Touch ID, or "Biometrics" when the kind is none), none selected by default, the biometric one disabled without biometrics; continue with none → `setUp(.none)` and done; password modes → asks for password + confirm; `cancelPasswordPrompt()` hides the prompt; empty → "Password cannot be empty"; mismatch → "Passwords do not match"; `.existingPasswordRequired` → "A vault password already exists on this device. Enter that password."; other errors → their message; busy while setting up; done marks `hasCompletedSetup`.
  - LockScreenViewModel: biometric button shown for biometric mode with biometrics available, titled "Use <`biometricKind` name>"; auto biometric attempt once the scene is active (biometric mode only); otherwise focus the password field; empty password ignored; busy while unlocking (button disabled); wrong → "Incorrect password"; every error, and a successful unlock, clears the field; `.passwordMissing` → "Your vault password is missing from this device."; biometric errors mapped: cancel → nothing, lockout → "Too many attempts. Use your password.", not enrolled → "Face ID is not set up.", passcode → "Set a device passcode to use Face ID.", changed → "Face ID changed. Use your password.", other → "Biometric authentication failed"; the error clears when typing starts.
  - AppLockCoordinator: at connect, needs setup → wizard full-screen unanimated; with a lock → lock screen; resign active with an unlocked lock → privacy cover over the window; background → `appDidEnterBackground`; active → `appWillEnterForeground`, then lock screen if locked (presented on the topmost controller, once; a scene reconnecting gets a fresh lock screen); the cover is hidden either way, so it never sits over the lock screen; after unlock → dismiss only the lock screen and, once that dismissal has completed, hide the cover and call `onUnlocked` (so `onUnlocked` can present a screen). `LockPresenting`, the coordinator's presentation seam, stays in AppLockCoordinator.swift: it names module-internal view models and no other module uses it. `LockPresenter` in `Views/` is its real implementation, thin like the other views.
  - Launch recovery (AppLockCoordinator, at connect, before anything that resumes a migration): a pending encrypt with no password blob can never finish, so the record is dropped, `lockMode` becomes .none, the lock is told `appWillEnterForeground` to refresh its state, and the app opens with no lock screen; a pending encrypt with a blob asks for the password even if `lockMode` is .none, and keeps the record; a Keychain error reading the blob counts as a blob (keep everything, ask for the password); no pending encrypt → the normal rule.
  - LockScreenViewModel, unlocking with `lockMode` .none and a pending encrypt: first `unlock(password:)`, so a wrong password shows "Incorrect password", adds no lock and never replaces the blob; then `prepareToAddLock(mode: .password, password:)`, whatever the record's target (the migration switches to the target at its end). `onUnlocked` runs only after both succeed; a failure in the second step shows its message and stays on the lock screen.
  - Views: identifiers `continueButton`, `passwordField`, `unlockButton`, `lockScreen.titleLabel`, `lockScreen.biometricButton`, `lockScreen.errorLabel`, `setupWizard.titleLabel`, `setupWizard.noLockCard`, `setupWizard.passwordCard`, `setupWizard.biometricCard`, `setupWizard.passwordField`, `setupWizard.confirmPasswordField`, `privacyCover`. (Views; covered by journey tests.)
- Contract: see `docs/api/LockScreens.md` (generated; do not edit by hand)
- Legacy files: View/SetupWizard.swift, View/LockScreen.swift; Model/AuthService.swift (part: privacy screen, showLockScreen, handleInitialLaunch with `resolveUnfinishableEncryption` (an encrypt pending with no password is dropped and the app opens; with a password the lock screen shows and the record is kept), didAuthenticate, reloadFileBrowser, afterLockScreenDismissed; `BiometricKind.legacyDisplayName` and `VaultLockError.legacyMessage` stay in AuthService.swift for SecuritySettings; Settings deletes that file)
- Legacy tests: KoalaTVaultTests/BaselineFix20_23Tests.swift (part: PendingEncryptionLaunchTests)
- Callers to repoint: SceneDelegate.swift

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
- Legacy files: View/FileViewer.swift, View/FilePage.swift, View/TextEditor.swift
- Legacy tests: KoalaTVaultTests/MediaPipelineTests.swift (part: FileViewerViewControllerTests)
- Callers to repoint: View/FileBrowser.swift

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
  - SecuritySettingsViewModel rows: Pro ("Upgrade to Pro" / "Pro Unlocked", live from `unlockedUpdates`); Lock Mode (No Lock, Password, Password + <biometric name> disabled without biometrics, "Re-encrypt Everything" only with a lock and unencrypted files); Password ("Change Password", hidden without a lock); Storage ("Recently Deleted").
  - Choosing the current mode does nothing.
  - No Lock from a lock → confirm "Remove Lock?" → decrypt migration.
  - A lock from No Lock → password + confirm (or, with an existing blob, the existing password) → `prepareToAddLock(.password)` → encrypt migration under `.password`; for Password + biometric, a full migration then calls `switchMode` (a failure shows the error and keeps Password), and an incomplete one (Skip, Close) shows "Face ID wasn't turned on because some files aren't encrypted yet. Use Re-encrypt Everything, then turn on Face ID."
  - Password ↔ Password + biometric → `switchMode`; errors shown; the row reflects the real mode afterwards.
  - Re-encrypt Everything → encrypt migration with no target, keeping a pending encrypt's target.
  - A store that can't be read (locked or failing) hides Re-encrypt Everything rather than showing an error.
  - The view model records the kind (`.decrypt` after Remove Lock, `.encrypt` after adding a lock or re-encrypting) of the migration it starts, for the Migration screen.
  - Changing the lock mode or re-encrypting is refused during a migration (running, paused, failed or pending): "A migration is still in progress. Let it finish, then try again."
  - Change Password: empty → "Password cannot be empty"; mismatch → "Passwords do not match"; wrong current → "Current password is incorrect"; success → "Password changed successfully"; busy while working.
  - MigrationViewModel: title "Encrypting Files" / "Decrypting Files"; status "Preparing…", "N% complete", "Paused — unlock to continue", "Complete"; failures → "Some Files Failed" with "These files couldn't be migrated: a, b" and Retry / Skip; finished → dismiss after 0.5 s and report whether it completed fully; `wantsBackgroundTime` is true while running and false when paused, failed or completed.
  - PaywallViewModel: "Store more than 100 files."; price or "Price unavailable"; Unlock → `.unlocked` → close and `onUnlock`; `.cancelled` → stays; `.pending` → "Purchase pending approval."; Restore → unlocked → close, else "No previous purchase found to restore."; StoreKit cancel → silent; busy state.
  - RecentlyDeletedViewModel: rows, most recently deleted first, with name, icon and "Deletes in N days" (N = 30 − whole days since deletion, at least 0; "1 day" singular); empty → "No recently deleted files" and Empty Trash disabled; Restore → item back and the browser refreshed; Delete Permanently → confirm first; Empty Trash → confirm; errors shown.
  - Views: identifiers `upgradeToProCell`, `lockModeNoneCell`, `lockModePasswordCell`, `lockModeBiometricCell`, `reencryptCell`, `changePasswordCell`, `recentlyDeletedCell`, `paywallUnlockButton`, `restoreButton`, `paywallCloseButton`, `migrationStatusLabel`, `emptyTrashButton`. (Views.)
- Contract: see `docs/api/Settings.md` (generated; do not edit by hand)
- Legacy files: View/SecuritySettings.swift, View/LegacyPaywallViewController.swift, View/RecentlyDeleted.swift, View/Migration.swift (part: the view)
- Legacy tests: KoalaTVaultTests/SecuritySettingsProTests.swift, KoalaTVaultTests/SecuritySettingsViewControllerTests.swift
- Callers to repoint: SceneDelegate.swift, View/FileBrowser.swift

### Browser
- Purpose: the file browser grid and the folder picker: browsing, sorting, selection, folder and file operations, drag and
  drop, and starting import, export, viewing and settings.
- Depends on: VaultStore, Preferences, Media, Import, Export, SharedUI, Viewer, Settings
- Files: FileBrowserViewModel.swift, FolderPickerViewModel.swift, FileCellModel.swift | Views/FileBrowserViewController.swift, Views/FileCell.swift, Views/FolderPickerViewController.swift
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
  - Sort: current option flips direction; another option → ascending; saved in Preferences; reload.
  - Open: folder → push a browser; `.rtf` → editor; other files → viewer with the folder's non-folder items starting at the tapped one.
  - New Folder / New Document: names trimmed; empty ignored; through the store (New Document opens the editor on the created item).
  - Select mode: toggle, "Select Items" / "N Selected", Cancel clears; bulk Delete (confirm "Delete N items?"), Move (picker), Copy (into the current folder), Export; bulk results report "N of M failed" when any fail.
  - Move: one pending move at a time; cancelling the picker clears it; the picker's choice moves exactly the pending items.
  - Context menu: Export, Move, Copy, Rename (prefilled), Delete (confirm; message mentions Recently Deleted).
  - Drag a cell onto a folder cell → move; onto a file cell → not a drop target; drops from other apps ignored.
  - A drag stays inside the app when `lockMode != .none`, `pendingMigration` is set, or the item `isEncrypted`; only a no-lock vault with no migration pending can drag items out (the on-disk file of an encrypted item is ciphertext). This rule lives in a tested view model, with a test for each case and an unknown drag item (stays in).
  - Refresh after restore, import, editor close and unlock.
  - FolderPickerViewModel: lists subfolders of the current folder, starting at the root; excludes the items being moved (and so their subfolders); "Move Here" returns the current folder; load error shown.
  - FileCellModel: name, size text (`ByteCountFormatter` file style; empty for folders), icon from `FileIconMapping`, thumbnail requested and cancelled on reuse, and ignored if the cell now shows another item.
  - Views: identifiers `fileGrid`, `settingsButton`, `sortButton`, `newFolderButton`, `newDocumentButton`, `importButton`, `selectButton`, `bulkDeleteButton`, `bulkMoveButton`, `bulkExportButton`, `bulkCopyButton`, `fileCell_<name>`, `emptyStateLabel`, `folderPickerMoveHere`, `folderPickerCancel`. (Views.)
- Contract: see `docs/api/Browser.md` (generated; do not edit by hand)
- Legacy files: View/FileBrowser.swift, View/LegacyFileCell.swift, View/FolderPicker.swift
- Legacy tests: none
- Callers to repoint: SceneDelegate.swift

## Legacy code
- App shell: AppDelegate.swift, SceneDelegate.swift, AppDependencies.swift, Info.plist, Assets.xcassets, Base.lproj/LaunchScreen.storyboard
- Legacy folders: Model/, View/, Base.lproj/Main.storyboard (empty; deleted in the baseline if nothing references it)
- Renames: VaultItem → LegacyVaultItem, VaultDirectory → LegacyVaultDirectory, FileKind → LegacyFileKind, LockMode → LegacyLockMode, SortOption → LegacySortOption, SortDirection → LegacySortDirection, CameraRollDeleting → LegacyCameraRollDeleting, FileCell → LegacyFileCell, FileBrowserViewController → LegacyFileBrowserViewController, FolderPickerViewController → LegacyFolderPickerViewController, FileViewerViewController → LegacyFileViewerViewController, FilePageViewController → LegacyFilePageViewController, TextEditorViewController → LegacyTextEditorViewController, SecuritySettingsViewController → LegacySecuritySettingsViewController, MigrationViewController → LegacyMigrationViewController, PaywallViewController → LegacyPaywallViewController, RecentlyDeletedViewController → LegacyRecentlyDeletedViewController, LockScreenViewController → LegacyLockScreenViewController, SetupWizardViewController → LegacySetupWizardViewController
- Obsolete tests: KoalaTVaultTests/KoalaTVaultTests.swift (empty template); KoalaTVaultUITests/KoalaTVaultUITests.swift, KoalaTVaultUITests/AdditionalUITests.swift, KoalaTVaultUITests/PaywallUITests.swift, KoalaTVaultUITests/KoalaTVaultUITestsLaunchTests.swift, KoalaTVaultUITests/VaultUITestCase.swift (deleted in the baseline, 2026-10-26; superseded by the baseline journey tests, which carry over their useful cases: browse flows, migration failure Retry/Skip, paywall purchase and restore)
- Shell responsibilities after adoption: `AppDependencies` builds every live service once (real Keychain, UserDefaults.standard, Documents root; in `-uiTesting` mode the in-memory and temporary ones and the seeds); SceneDelegate wires `AppLockCoordinator`, the root browser, purges expired trash and sweeps orphans after unlock (never while a migration is pending: the sweep would delete encrypted copies not yet indexed; the post-unlock steps live in a small unit-tested shell helper), clears thumbnails and resumes a pending migration after unlock (presenting the Migration screen).
- `Model/FileSystem.swift` now holds only `Notification.Name.fileRestored` (RecentlyDeleted posts it, FileBrowser observes it); the Settings and Browser switch-overs replace the notification and delete the file.

## Known issues
- "Remove Lock" leaves an encrypted `.vault_map` in every folder and then deletes the key, so every listing fails afterwards — FileSystem.swift:720-722, :693 (`migrateVaultToDecrypted` has no caller) — fixed in baseline (the decrypt migration now ends with a cleanup that decrypts leftovers by the plaintext " N" rule and deletes every `.vault_map`; a cleanup failure shows "Some Files Failed" with the error, Retry / Skip, and Skip keeps the key. LockMigration's spec reports leftovers as `.stillEncrypted(count:)` instead: the module decides deliberately)
- A plaintext `.trash_map` (written with no lock) can't be read once a lock is on: delete moves the file into `.trash` then fails, Recently Deleted errors — FileSystem.swift:510-512, :842-863, :874-879 — fixed in baseline (a legacy plaintext map is read once a key is loaded and saved encrypted; the entry is written before the file moves; restore rejects entries whose target is outside the vault root)
- Moving an encrypted item into its own folder renames it `<UUID> 1` unmapped (ciphertext shown as a plain file); moving with no source index entry leaves an unmapped file the sweep deletes — FileSystem.swift:425-445, FolderPicker.swift:68-71 — fixed in baseline
- New Document writes an unencrypted, unindexed file in an encrypted vault and truncates an existing same-name document — FileBrowser.swift:213-242 — fixed in baseline
- The 30-day trash purge never runs (`cleanupExpiredTrashItems` has no caller) — FileSystem.swift:604 — fixed in baseline
- The migration screen starts a second migration loop when the lock screen is dismissed over it (spurious "Some Files Failed") — Migration.swift:66-69, :216-221 — fixed in baseline
- Cancelling the folder picker keeps the pending bulk move, so a later single move moves the old selection — FileBrowser.swift:17-21, :485-497 — fixed in baseline
- The text editor saves an empty document over the original after a failed load — TextEditor.swift:116-132 — fixed in baseline
- Photo picker Cancel doesn't close the picker; a non-limit error alerts under the open picker — ImportService.swift:135-151 — fixed in baseline
- The orphan sweep deletes extensionless UUID-named plaintext files in folders with no index — FileSystem.swift:733-752 — fixed in baseline (sweeps only folders with a readable index, with the key loaded; runs after unlock instead of at launch; two legacy tests that asserted the old behaviour were updated)
- Adding a lock while the screen auto-locked: the key wipe made the in-flight file's index save as plaintext, every later file in that folder failed, and each launch stuck on "Preparing...". The encrypt step is now interrupt-safe (encrypt → verify → encrypted index → read back → verify again → delete plaintext; leftovers deleted only on a byte-for-byte match), the migration pauses on lock and resumes after unlock, a scan failure offers Retry/Close, launch recovers a pending encrypt, and the orphan sweep waits while a migration is pending — FileSystem.swift, CryptoService.swift, Migration.swift, AuthService.swift — fixed in baseline
- Paging onto a video in the viewer let a preloaded neighbour take the shared player, paused the wrong player on leaving, and computed neighbours from a stale index — FilePage.swift, FileViewer.swift — fixed in baseline
- Exporting a folder from an encrypted vault handed out the encrypted tree (UUID names, `.vault_map`); dragging encrypted items to other apps handed out ciphertext. Folders now export as a decrypted copy; encrypted drags stay in the app — FileSystem.swift (prepareForExport), FileBrowser.swift (drag) — fixed in baseline
- On iOS 18, cancelling the document picker could crash (SIGABRT in DOCWeakProxy: the picker was released before a late XPC message); the service now holds the last picker until the next one replaces it — ImportService.swift — fixed in baseline
- The pending-purchase alert read "Purchase is pending approval." instead of the specified "Purchase pending approval." — EntitlementService.swift:16 — fixed in baseline
- The paywall showed a blank price on a load failure (now "Price unavailable"; the rest of the minor-UX line stays with its modules) — PaywallViewController.swift:83-90 — fixed in baseline
- Restoring into a folder with a same-named item failed (no lock) or duplicated the visible name (encrypted); now suffixed " 1" — FileSystem.swift (restoreFromTrash) — fixed in baseline
- A viewer page that failed to load showed a blank page (QuickLook previewed the encrypted file) instead of "This file can't be opened." — FilePage.swift — fixed in baseline
- Moving a folder into itself failed silently (`try?` in the picker delegate); other move errors were swallowed too — FileBrowser.swift (FolderPickerDelegate), FileSystem.swift (move) — fixed in baseline
- A name with "/" (new folder, new document, rename) showed a raw system error instead of "Names can't contain /" — FileBrowser.swift:213-242, FileSystem.swift (createFolder, rename) — fixed in baseline
- A key wipe (backgrounding) between an index load and save writes the index in plaintext, exposing names and making the folder unreadable after unlock — FileSystem.swift:669-680, :716-722, :874-879 — fixed in module VaultStore
- Encryption is decided per call by "key loaded", so a background wipe mid-import stores the rest of the import as plaintext — FileSystem.swift:80, :188-201 — fixed in module VaultStore
- Index read-modify-write has no serialization; concurrent imports, moves and migration can lose entries — FileSystem.swift:190-197, :430-441, :512-521 — fixed in module VaultStore
- The trash is never migrated: after "Remove Lock" trashed files stay under a deleted key — FileSystem.swift:88, :631-642 — fixed in module VaultStore and LockMigration
- Migration resume deletes a plaintext file whenever an indexed file has the same name, without comparing content — FileSystem.swift:670-674 — fixed in module VaultStore
- Trash entries store absolute paths; restore after a container move targets a stale path — FileSystem.swift:494-497, :536 — fixed in module VaultStore
- Restore and permanent delete of an unknown trash item succeed silently; encrypted restore doesn't resolve name conflicts; trashed folders show as files — FileSystem.swift:531-581, :545, :559-561 — fixed in module VaultStore
- `VaultItem.id` is a new UUID on every listing (thumbnail cache misses) — FileSystem.swift:27-45 — fixed in module VaultStore
- Setup or adding a lock that fails after creating the key leaves a blob with lock mode none; retrying fails forever with "master key already exists" (also after a reinstall) — SetupWizard.swift:218-232, SecuritySettings.swift:216-229, CryptoService.swift:62 — fixed in module VaultLock (the reinstall case, which blocked first-time setup, fixed in baseline: an empty vault replaces the stale key)
- `hasPassword()` is true on a Keychain error, so adding a lock can skip the password and the migration — AuthService.swift:57-59, SecuritySettings.swift:230-243 — fixed in module VaultLock
- `removePassword` stops at a blob-delete error and leaves the raw-key biometric item; finalize clears the pending record before it runs, so a kill leaves plaintext files under a password lock — AuthService.swift:61-65, :127-148, Migration.swift:161-176 — fixed in module VaultLock and LockMigration
- Biometric unlock loads any 32 bytes without checking them against the vault; enabling biometrics deletes the old item before adding the new one and callers swallow the failure — AuthService.swift:71-115, :172-207 — fixed in module VaultLock
- The lock screen's lockout / not-enrolled / passcode messages can never show (the service only passes nil or `keychainError`) — LockScreen.swift:185-203, AuthService.swift:195-204 — fixed in module LockScreens
- Skip with failures keeps the pending record, so the migration screen reappears after every unlock; a load failure on the migration screen has no way out — Migration.swift:112-116, :192-198 — fixed in module LockMigration
- Plaintext temp files: viewer close deletes every temp file (including exports in progress); a failed export leaves earlier decrypted copies; decrypts run on the main thread — FileViewer.swift:272-277, ExportService.swift:73-90, FilePage.swift:57-58 — fixed in module VaultStore, Export and Viewer
- `cleanupTempFiles` and `wipeKey` are called from view code and services directly — AuthService.swift:230-236, FileViewer.swift:275 — fixed in module VaultLock
- No accessibility identifiers on most screens; existing UI tests find elements by text — View/*.swift — fixed in baseline (identifiers step)
- `--uitesting` wipes the real Documents vault and Keychain blob; tests share the real Keychain and UserDefaults — AppDelegate.swift:18-48, KoalaTVaultTests/VaultTestCase.swift — fixed in baseline (clean-launch step) and by injection in every module
- API-Memo observations #1, #4, #8, #9, #10, #13 are stale (already fixed or no longer apply); #6/#7 are covered by build settings (the Info.plist typo `NSFaceIDUsageDscription` is a harmless leftover) — fixed in baseline (Info.plist tidy)
- Bulk delete and bulk copy swallow errors (`try?`), so a failed item shows nothing — FileBrowser.swift:~286 — fixed in module Browser
- iPad popover anchors for bulk Export and Import point at the wrong bar buttons; "Delete Permanently" has no confirmation; the editor saves twice on Done — FileBrowser.swift:285, :385, RecentlyDeleted.swift:119-127, TextEditor.swift:39-48 — fixed in module Browser, Settings and Viewer
- Minor UX: no progress during PBKDF2 on the lock screen; the paywall shows a blank price on a load failure; camera-roll export has no progress and an unhelpful denial message; the photo import overlay never updates; keyboard inset ignores the safe area — LockScreen.swift:136-166, PaywallViewController.swift:83-90, ExportService.swift:97-104, ImportService.swift:155-172, TextEditor.swift:136-140 — fixed in modules LockScreens, Settings, Export, Import, Viewer (as specced)
- Case-only rename of a plaintext item ("a.txt" → "A.txt"): the tests pass in both modes, but `rename`'s conflict check calls `fileExists` on a case-insensitive volume, which by reading should give "A 1.txt"; why the tests pass is unexplained. Check on device (verify) and, if it misnumbers, apply the case-insensitive self-match fix — VaultFileOperations.swift (rename) — open, VaultStore
- Folder names, sizes and structure are plaintext on disk in an encrypted vault — FileSystem.swift:418-422 — feature encrypt-folder-names
- No way back in when the password blob is missing — AuthService.swift:48, LockScreen.swift:~158 — feature password-recovery
- No lockout after failed passwords — LockScreen.swift:136-166 — feature timed-lockout-for-failed-passwords
- No minimum password strength — SetupWizard.swift:206-213, SecuritySettings.swift:255-262 — feature minimum-password-strength
- `FileIcon` → UIImage/UIColor helper (`iconImageAndTint`, `tintColor(named:)`) is copied in two legacy files during the SharedUI switch-over — View/LegacyFileCell.swift, View/RecentlyDeleted.swift — open; Settings (first to replace one of them) moves it into SharedUI's views, and Browser reuses it
- Locking the device with the app in the foreground during a migration can fail one file with an I/O error before the background key wipe (the legacy screen paused on protected-data-unavailable; the engine pauses only on a lock); the file shows under Retry/Skip — LiveLockMigrator.swift (`isInterruption`), SceneDelegate.swift — open; candidate fix: treat a data-protection error as an interruption, or pause on `sceneWillResignActive`
- Settings has no unit test for which migration it starts (encrypt with `.password`, decrypt with `nil`, re-encrypt keeping a pending target), and the Migration screen has no test that `onComplete` fires once after paused → running → completed — SecuritySettings.swift, MigrationScreenTests.swift — open; Settings' module (which replaces both screens) tests them
- A cancelled photo import carries on through its remaining photos (`importPhotos` counts `CancellationError` as a failure); nothing can cancel an import today, since the overlays have no Cancel — LiveVaultImporter.swift — open, matters only if a Cancel is added
- Camera-roll photos were stored under random (UUID) names since 2026-10-07, so re-imports were never detected as duplicates — FileSystem.swift:166 — fixed in module Import; photos already imported keep those names
- If the "N imported, M failed" alert is torn down without OK (a lock screen dismissing it), that import's camera-roll delete prompt never appears and its flow stays suspended; originals stay in the library — ImportPresenter.swift — open, rare
- Dismissing the import sheet or photo picker without a handler firing (tap outside on iPad, swipe down) keeps the flow's model and the screen it captures until the next import — ImportPresenter.swift — open, minor
- A folder emptied in an encrypted vault exports as its disk URL with its hidden `.vault_map` (folders are never `isEncrypted`, and the index is sealed and lists nothing, so no data leaves) — LiveVaultExporter.swift — open, cosmetic
- Backgrounding with a lock while the export picker is open removes the copies it is reading (the spec's background rule), so tapping Save afterwards fails inside Files with no message from the app — ExportPresenter.swift — open, safe but unhelpful
- If the app (not the user) closes the export picker, copies are removed after a 30 s grace for a late pick report; a pick reporting later than that would lose its source and fail with no message, and no plaintext leaks — ExportPresenter.swift — open, rare
- Viewer close called `removeAllTemporaryFiles`, deleting export copies in progress — FileViewer.swift:303 — fixed in module Viewer
- The drag-out rule trusts `lockMode` and `pendingMigration` to match the disk; no path in the app reaches a no-lock vault still holding ciphertext, only something outside it (a restored backup) could — FileBrowser.swift — open, accepted
- `VaultLockError` had no user-facing text of its own, so "other errors → their message" would read "The operation couldn't be completed" for `.keychain` and `.notUnlocked` — VaultLock/Contracts — fixed during LockScreens unit 1 (`errorDescription`, approved 2026-11-02)
- `onUnlocked` can still run if the app backgrounds and relocks during the lock screen's dismissal animation (the coordinator's completion doesn't recheck the state; the code-writer reports legacy doesn't guard this either) — AppLockCoordinator.swift — open, minor
- Adding a lock when nothing is encrypted: if `deleteMasterKeyBlob` succeeds and `createMasterKey` then fails, the blob is gone with no rollback; a retry says the password is missing until relaunch, which drops the pending record and leaves the vault without a lock (nothing lost, Keychain write failure only) — LiveVaultLock.swift:134-146 — open, rare
- After `unlock` succeeds and `prepareToAddLock` fails on the lock screen, the key stays loaded with `lockMode` .none until the process ends (`appDidEnterBackground` wipes nothing with no lock; only the lock screen is reachable meanwhile) — LiveVaultLock.swift:212-217 — open, minor
- The setup wizard's option cards are title-less buttons whose labels sit in a non-interactive stack, so VoiceOver has nothing to read (same as legacy) — SetupWizardViewController.swift:75-81 — open, accessibility
- `SetupWizardViewController.showBusy` decides in the view whether the overlay shows (`selectedOption != .none`), a small view decision with no test (same as legacy) — SetupWizardViewController.swift:175 — open, minor
- The first on-screen check of the lock screens is the journey run after LockScreens' switch-over; layout, dark mode and Dynamic Type are unverified until then — LockScreens/Views — open until unit 3
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
- After Add Lock, the browser's items still hold the plaintext `VaultItem` (`isEncrypted` false, old URL), so opening a video fails with "This file can't be opened." until the grid reloads, same as today — FileBrowser.swift — open until Browser or Settings
- The viewer checks for a refused editor present one main-queue turn later (seen working on iOS 18.6 only); if UIKit scheduled it later while the viewer opens on an `.rtf`, which no browser path does, the viewer could stay on a blank page — FileViewerViewController.swift:249-262 — open, theoretical
- The under-lock `.rtf` page journeys assume the created document is encrypted rather than checking the file — J5ViewEditJourneyTests.swift — open, minor
- `VaultLockError.legacyMessage` duplicates the new `errorDescription` wording; SecuritySettings still uses it, so it survives LockScreens' switch-over — AuthService.swift:31 — open until module Settings

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
