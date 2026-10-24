# Survey: module VaultStore

STATUS: done
PASS: module VaultStore

Read only; nothing run. Builds on survey-data and survey-module-Keys §3. Paths under `KoalaTVault/`.

## A. The six claims

1. **Plaintext `.trash_map` unreadable after enabling a password — CONFIRMED.** `saveEncryptedJSON` writes plaintext with no
   key (FileSystem:877-878); with a key, `loadEncryptedJSON` tries three AAD domains, all fail → `mappingUnreadable`
   (:842-863). `.trash` hidden (:488) so never migrated. `moveToTrash` moves first (:510), `loadTrashMap` throws (:512),
   entry (:513-521) and source-map removal (:523-528) never run.
   **Repro:** lock none, delete a.txt → enable password → encrypt migration finishes → delete b.txt → b in
   `.trash/<uuid>` with no entry (dangling `.vault_map` entry if encrypted); `contentsOfTrash` (:553), restore,
   permanentlyDelete all throw; Recently Deleted unusable; only "Empty" (best-effort, :583-602) recovers, wiping all.
   Plaintext trashed files stay plaintext. Mirror after decrypt: encrypted trash map read with no key → throws.
2. **Encrypted `.vault_map` left after "Remove Lock" — CONFIRMED (worst finding).** `migrateFileToDecrypted` saves the map
   with the key loaded (:720-722); `migrateVaultToDecrypted` (deletes it, :693-694) has no caller anywhere.
   `finalizeMigration(.decrypt)` → LM none, `removePassword()`, `wipeKey()` (AuthService:139-147). `contents(of:)` →
   `loadMapping` (:91) with no key → ciphertext isn't JSON (:866) → throws.
   **Repro:** LM password with ≥1 file in root → Settings → Remove Lock → Remove → migration completes → every listing of
   root throws `mappingUnreadable` (subfolders that held encrypted files too). Re-enabling a password doesn't help (master
   key discarded). Import, rename, move, copy, trash fail in that directory. No `UIFileSharingEnabled`, so no Files-app
   access. Only the plaintext files on disk survive.
3. **Orphan sweep — CONFIRMED, narrower trigger.** Runs at launch (SceneDelegate:38), key essentially never loaded then.
   Existing encrypted map → `loadMapping` throws → bails (:739). No map file → `[:]` (:839, :883) → every extensionless
   UUID-shaped file (case-insensitive, :740-748) deleted. Encrypted case needs a directory with encrypted files and no map
   (external deletion / partial restore; no normal path found). **Plaintext case reachable:** lock none, import a file
   named `3F2504E0-4F89-11D3-9A0C-0305E82C3301` (no extension) → deleted at next launch, silently. Same with a plaintext
   map that doesn't list it. Recurses. `.trash` not swept.
4. **Encrypted move with no source entry — CONFIRMED, unusual precondition.** `move` (:425-445): nil `sourceMapping[uuid]`
   → destination map not updated (:433-438), file still moved (:439) → unmapped, shows as plaintext `<UUID>` holding
   ciphertext → swept next launch. Not constructible from normal UI.
   **NEW, reachable: moving an encrypted item into its own directory.** FolderPicker offers the current directory
   (FolderPicker.swift:68-71); `resolvedName` on the UUID gives `<UUID> 1`; destination map saved with the uuid key; file
   renamed `<UUID> 1`; stale `sourceMapping` (loaded at :430) saved with the uuid removed (:440-441) → `<UUID> 1` unmapped,
   ciphertext shown as a plaintext item, unrecoverable in-app; regex doesn't match so not swept. Callers use `try?`
   (FileBrowser:488, :493): no error.
5. **New Document in an encrypted vault — CONFIRMED.** FileBrowser.swift:213-242: `FileManager.createFile(atPath:contents:nil)`,
   result ignored; disk name = user name + `.rtf`, plaintext, empty, never mapped. Listed as `isEncrypted:false`. Not
   swept (not UUID-shaped). Editor: `open` returns the disk URL (:344), `write` plain non-atomic `data.write(to:)` (:365).
   **Content and name stay plaintext on disk permanently in a vault the user believes is encrypted.** Also: (a) no
   existing-file check → **truncates an existing plaintext `Notes.rtf`**; (b) can duplicate a mapped display name; (c)
   Settings' `hasUnencrypted` (SecuritySettings.swift:39) flags it; "Re-encrypt" then hits the shortcut (:670-674) and
   **deletes the plaintext without comparing content** if an encrypted "Notes.rtf" exists → new document lost.
6. **Import while locked — not reachable from the UI; reachable as a race.** Lock screen covers the browser.
   `isEncryptionEnabled` (= `isKeyLoaded`, :80-82) is evaluated per file in `importSingleFile` (:188). Background wipe +
   `cleanupTempFiles` (AuthService:230-236) during a running import (global queue, ImportService:96; camera roll
   :263-291) → remaining files **copied plaintext with original names into an encrypted vault**, no error. The in-flight
   file hits `loadMapping` throwing (:195) or writes a plaintext map (Keys §3e). `cleanupTempFiles` deletes camera-roll
   `stableURL` copies mid-import (:272) → failures.

## B. Call sites (FileSystem members used outside FileSystem.swift)

| Member | Callers |
|---|---|
| `contents(of:)` | FileBrowser:162; FolderPicker:53 (`try?`); ThumbnailService:223 (`try?`) |
| `open` | FilePage:58, :108, :149 (`try?`); TextEditor:103; ThumbnailService:125 (`try?`) |
| `write(data:to:)` | TextEditor:128 |
| `createFolder` | FileBrowser:204 |
| `copy` | FileBrowser:291 (`try?`), :457 |
| `move` | FileBrowser:488, :493 (`try?`), :541 |
| `rename` | FileBrowser:354 |
| `delete` | FileBrowser:267 (`try?`, bulk), :373 |
| `importItems` | ImportService:97 |
| `checkImportAllowed` | ImportService:141 |
| `importFromCameraRoll` | ImportService:156 |
| `prepareForExport` | ExportService:73 |
| `exportToCameraRoll` | ExportService:99 |
| `contentsOfTrash` | RecentlyDeleted:44 |
| `restoreFromTrash` | RecentlyDeleted:112 (posts `.fileRestored`, observed FileBrowser:40) |
| `permanentlyDelete` | RecentlyDeleted:122 |
| `emptyTrash` | RecentlyDeleted:73; AppDelegate:23 (DEBUG) |
| `filesToMigrate` | SecuritySettings:39; Migration:149 |
| `migrateFileToEncrypted` / `ToDecrypted` | Migration:155 / :157 |
| `cleanupTempFiles` | SceneDelegate:37; AuthService:234; FileViewer:275 |
| `sweepOrphanedEncryptedFiles` | SceneDelegate:38 |
| `diagnoseDiskState` (DEBUG) | FileBrowser:53 |
| DEBUG test hooks | tests only |
| **No production callers** | `cleanupExpiredTrashItems` (tests only), `migrateVaultToEncrypted`, `migrateVaultToDecrypted`, `trashDirectory` (internal) |

`VaultItem`/`VaultDirectory` are used widely (FileCell, FileIconProvider, FilePage, FileViewer…). Direct CryptoService
file-format callers outside FileSystem: VaultResourceLoaderDelegate (`streamInfo`, `decryptChunk`).

## C. What FileSystem uses

- `CryptoService.shared`: `isKeyLoaded`, `encrypt/decrypt(data:authenticating:)`, `encryptFile`, `decryptFile`; `CryptoError`.
- `EntitlementService.isUnlockedSync`, `freeFileLimit`.
- `PreferencesService.shared.sortOption`/`sortDirection` (types in PreferencesService.swift:64, :78).
- `FileKind` (`exportToCameraRoll`). PhotosUI/Photos.

## D. File-format API (CryptoService:256-485)

- `encryptFile(at:to:)`: needs a key (`noKeyLoaded`); SVC5 32-byte header, 1 MiB chunks, random 16-byte file ID, HKDF
  per-file key, length-prefixed AES-GCM chunks with header+index AAD; staging in itemReplacementDirectory with
  `.complete`, atomic move/replace; `encryptionFailed` over 2 TiB or size mismatch.
- `decryptFile`: validates header and every chunk length; `decryptionFailed` on mismatch or total ≠ header; stages then
  **replaces** an existing destination.
- `streamInfo`/`decryptChunk` used by the AV loader only.

## E. Proposed split (suggestion)

**Must be one module (shared invariants):** vault index (`.vault_map`, `.trash_map` read-modify-write), file operations,
trash, migration engine, orphan sweep. All do unlocked load-modify-save on the same maps and rely on "encrypted iff key
loaded" (:874). Findings 1, 2, 4, 6 violate these. They need one serialized map writer and an explicit store mode instead
of inferring from `isKeyLoaded`.

| Module | Purpose | Owns | Depends on |
|---|---|---|---|
| **VaultStore** (core) | Index, file ops, trash, migration, sweep, temp files | `contents`, `open`, `write`, `createFolder`, `move`, `copy`, `rename`, `delete`; trash members + `TrashEntry`; `filesToMigrate`, `migrateFile*`, `migrateVault*`; `sweepOrphanedEncryptedFiles`; `cleanupTempFiles`; private map/JSON/name helpers; `FileSystemError`, `VaultMapping`; a new add-file operation for import. Could split internally later via a shared index contract. | Keys/Crypto contract; sort passed in |
| **VaultImport** | Files, folders, camera roll; limit; dedup | `importItems`, `checkImportAllowed`, `importFromCameraRoll`, `countFiles`, `isDuplicate`, `sha256Hex`, `importSingleFile`, `importFolder` | VaultStore (`addFile(from:to:)` owning encrypt + map + naming; today `importSingleFile` touches the map directly, :190-197), Entitlements, PhotosUI |
| **VaultExport** | Decrypt for sharing; camera roll export | `prepareForExport`, `exportToCameraRoll` | VaultStore (`open`), Photos, FileKind |

- File format stays in Keys/Crypto (also used by the AV loader).
- Temp files: a temp service inside VaultStore (`makeTempDir`, `cleanup`) instead of wiping all of tmp.
- Types: `VaultItem`, `VaultDirectory` are VaultStore contract types. `SortOption`/`SortDirection` are UI preferences;
  `contents(of:)` should take them as parameters (not read `PreferencesService.shared`, :891). `FileKind` → a small
  shared type in VaultStore's contracts.
- `.fileRestored` (:926-928) is a UI notification; belongs with the UI.

## F. Behavior-spec notes (today)

- `contents(of:)`: non-hidden entries → load map (throws `mappingUnreadable`) → omit `.vault_map` → mapped files get the
  original name and `isEncrypted:true`, unmapped files/folders the disk name → new random UUID per call → folders first,
  then the sort option.
- Encrypted `move`/`copy`/`rename` change maps and UUID names only; plaintext uses FileManager with " N" conflict names;
  plaintext rename doesn't resolve conflicts (throws).
- `delete` = `moveToTrash`: move into `.trash/<newUUID>`, entry with absolute paths.
- `emptyTrash` best-effort.
- Free tier 100 files: counts non-hidden files under root including subfolders; not trash or maps.
- `isDuplicate`: same name + SHA-256 → skip; encrypted vault decrypts the existing file to hash it; only the first map
  entry with that name is checked.

## Suspected issues (new, plus headlines)

- FileSystem:720-722, :693 — decrypt leaves an encrypted map; `migrateVaultToDecrypted` dead (item 2, highest impact).
- FileSystem:501-502, :622, RecentlyDeleted — plaintext trash map unreadable once a key is loaded (item 1).
- FileSystem:670-674 — migration shortcut deletes plaintext on a name match with no content comparison (data loss with item 5).
- FileSystem:604 — `cleanupExpiredTrashItems` never called: no 30-day expiry in production.
- FileSystem:494-497, :519-520, :536 — absolute paths in `TrashEntry` (guess about container path changes).
- FileSystem:188-201 — per-file encrypt decision: mid-import wipe imports the rest plaintext (item 6).
- FileSystem:425-445 — move into the same directory orphans an encrypted file (item 4); folder into itself/descendant
  unguarded (fails at `moveItem`, callers `try?`).
- **No lock around map read-modify-write**: import (global queue), camera import (serial queue), migration (`@concurrent`),
  UI ops can interleave and lose map updates (:190-197, :430-441, :512-521, :669-680).
- FileSystem:353-366 — plaintext `write` non-atomic; encrypted `write` throws `noKeyLoaded` after a wipe with the editor
  open → edits lost.
- FileSystem:726-729 — `cleanupTempFiles` deletes everything in tmp (open viewer copies, camera-import copies).
- FileSystem:559-561 — trashed folders shown `isDirectory:false` (hard-coded).
- Folder names, sizes and structure plaintext on disk even when encrypted (`createFolder`, :418-422): should be a stated decision.
- Rename (FileBrowser:354, FileSystem:464-477) accepts "/": encrypted `open` then fails; plaintext may move/throw.
- FileBrowser:267, :291, :488, :493 — bulk ops `try?`.
- FileSystem:75-77, :663-667 — DEBUG test hooks in production code (not in release).
- Guess: ExportService may pass folders to `prepareForExport` → directory URL of UUID-named ciphertext (not verified).

NOT READ: ExportService internals (call sites only); unit tests beyond a grep.
