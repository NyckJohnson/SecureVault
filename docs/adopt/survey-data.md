# Survey: data layer

STATUS: done
PASS: data

Files: `Model/FileSystem.swift`, `Model/CryptoService.swift`, `Model/PreferencesService.swift`.

## 1. Types

FileSystem.swift (928 lines):
- `VaultDirectory` (struct, Sendable): `name`, `diskURL`, `rootURL`; `static var root` = Documents dir, name
  "KoalaTVault" (:15-24).
- `VaultItem` (struct, Identifiable/Hashable/Sendable): `id: UUID`, `name`, `isDirectory`, `dateModified`,
  `fileSize: Int?`, `deletedAt: Date?`, `diskURL`, `rootURL`, `isEncrypted`. Hash/== by `id` only (:27-45).
  `contents(of:)`/`contentsOfTrash` make a fresh `UUID()` each call: ids unstable across reloads.
- `VaultMapping` (Codable): `originalName` (:48).
- `FileSystemError`: `mappingUnreadable`, `fileLimitReached` (:53); message hardcodes "100".
- `FileSystem` (final class, `static let shared`, private init, no stored mutable state). Nested `TrashEntry`
  (Codable): `originalDiskName`, `originalDirectoryURL` (absolute path string), `deletedAt`, `isEncrypted`,
  `originalName`, `rootURL` (absolute path string, never read) (:491).
- `Notification.Name.fileRestored` (:926); FileSystem never posts it.
- DEBUG: `testForcedMigrationFailureFileName` (`nonisolated(unsafe)`), env `UITEST_FAIL_MIGRATION_FILE` (both
  `migrateFileTo*`), `diagnoseDiskState`, `testTrashMap`, `saveTestTrashMap`, `testMapping`, `TrashEntryForTesting`.

CryptoService.swift (485 lines):
- `CryptoService` (final class, `@unchecked Sendable`, `static let shared`).
- `CryptoError` (Equatable, LocalizedError): `noKeyLoaded`, `noMasterKeyBlob`, `masterKeyAlreadyExists`,
  `wrongPassword`, `encryptionFailed`, `decryptionFailed`, `keychain(OSStatus)`.

PreferencesService.swift (81 lines):
- `LockMode` (String enum): `none`, `password`, `passwordAndBiometrics`.
- `PreferencesService` (Sendable, `static let shared`).
- `SortOption` (`name`, `type`, `dateModified`; `displayName`); `SortDirection` (`ascending`, `descending`).

## 2. Candidate split lines

FileSystem.swift:
- A. Vault types (:14-65).
- B. Mapping/index (:820-888): `authDomain`, `loadEncryptedJSON`, `saveEncryptedJSON`, `loadMapping`, `saveMapping`
  (trash map reuses the JSON helpers).
- C. Browse and sort (:85-126, :890-915); sorting reads `PreferencesService.shared`.
- D. Import (:129-340): `importItems`, `importSingleFile`, `importFolder`, `importFromCameraRoll` (PhotosUI),
  `checkImportAllowed`, `countFiles`, `isDuplicate`, `sha256Hex`. Limit via `EntitlementService.isUnlockedSync` and
  `freeFileLimit` (100).
- E. Open/write/export (:343-415); `exportToCameraRoll` `@concurrent`, PHPhotoLibrary.
- F. Manage (:418-485): `createFolder`, `move`, `copy`, `rename`, `delete` (= `moveToTrash`), `resolvedName` (:793-818).
- G. Trash (:487-628): `trashDirectory`, `moveToTrash`, `restoreFromTrash`, `contentsOfTrash`, `permanentlyDelete`,
  `emptyTrash`, `cleanupExpiredTrashItems`, `loadTrashMap`, `saveTrashMap`.
- H. Migration (:630-723): `filesToMigrate`, `migrateVaultToEncrypted`, `migrateFileToEncrypted`,
  `migrateVaultToDecrypted`, `migrateFileToDecrypted`.
- I. Temp/orphan clean-up (:725-752): `cleanupTempFiles`, `sweepOrphanedEncryptedFiles`; DEBUG `diagnoseDiskState`.

CryptoService: key state (:17-42); master-key blob and KDF (:44-215); chunked file format (:256-459).

PreferencesService `pendingMigrationType` uses `MigrationViewController.MigrationType` (`View/Migration.swift:12`): the
preferences layer depends on a view controller type.

## 3. Callers outside these files

- `wipeKey()`: AppDelegate.swift:24, AuthService.swift:146, :233.
- `wipeMasterKeyBlob()`: AuthService.swift:62.
- `cleanupTempFiles()`: SceneDelegate.swift:37, AuthService.swift:234, FileViewer.swift:275.
- `sweepOrphanedEncryptedFiles(in: .root)`: SceneDelegate.swift:38.
- `cleanupExpiredTrashItems`: **no production caller** (only TrashTests:180, EdgeCaseTests:202,
  FileSystemMappingIntegrityTests:185).
- `wipeOrphanedEntries`: no longer exists.

## 4. On-disk layout

- Root = Documents (`VaultDirectory.root`), real subfolders.
- Folder names always plaintext on disk; folders never in the mapping.
- Plaintext mode: real names (conflicts → "name 1.ext").
- Encrypted mode: each file stored as `<UUID string>` (no extension). Each directory has hidden `.vault_map`: JSON
  `[uuidString: {originalName}]`. Browse treats a file as encrypted if its disk name is a key in that map; everything
  else shows as plaintext (mixed state during migration).
- `.vault_map` encryption: AES-256-GCM with the **master key directly**; nonce(12) | ciphertext | tag(16). AAD = bare
  file name ".vault_map" (same for every folder; `authDomain` comment about per-folder binding is wrong). Written
  `.atomic`, no explicit protection. Read fallbacks: AAD file name → relative path → "" (legacy) → `mappingUnreadable`.
  **No key loaded: reads as plaintext JSON, and a save writes plaintext JSON.** Missing file = empty map; present but
  unreadable throws.
- Trash: `<root>/.trash/` with items renamed to a new UUID + `.trash_map` (same scheme, AAD ".trash_map",
  `[trashUUID: TrashEntry]`). Absolute paths stored. Items keep their encryption state. `trashDirectory(for:)` creates
  the folder on every call. Hidden folders skipped by `contents`, `countFiles`, migration.
- Temp (`FileManager.temporaryDirectory`): `open`/`prepareForExport` → `tmp/<UUID>/<name>`; encrypted `write` →
  plaintext `tmp/<UUID>` (no protection); camera-roll import → `tmp/<UUID>.<ext>`; `isDuplicate` → `tmp/<UUID>`.
  `cleanupTempFiles` deletes everything in tmp.
- Staging: `CryptoService.makeStagingFile` in `.itemReplacementDirectory` on the destination volume, created with
  `FileProtectionType.complete`, dir removed by `defer`.
- File protection: only staging files (→ encrypted/decrypted outputs) are `.complete`. Mappings, plaintext-mode files,
  `write()` temps, imported plaintext use the default class. No data-protection entitlement found.
- Backup: no `isExcludedFromBackup` anywhere; Documents (vault, maps, trash) is in device backups (API-Memo #16 confirmed).
- Plaintext on disk: folder names, file count, approximate sizes and dates (always); plaintext-mode files; maps saved
  with no key; decrypted temp copies until cleanup; `.trash_map` written in plaintext mode.

## 5. Encrypted file format — the code says **SVC5**, not SVC4

- `CryptoService.swift:258`: magic `53 56 43 35` = "SVC5". No SVC4 reader; other magic → `decryptionFailed`.
- Header 32 bytes: magic(4) | chunkSize UInt32 LE (1 MiB on write) | totalPlaintextSize UInt64 LE | fileID(16,
  `SecRandomCopyBytes`).
- Body: repeated [length UInt32 LE | AES-GCM combined (nonce 12 | ct | tag 16)]; full chunks except the last; empty
  file = header only.
- Per-file key: HKDF-SHA256(IKM = master key, salt = fileID, info = "file-key", 32 bytes).
- Chunk AAD = 32-byte header + chunk index UInt64 LE. Random 12-byte nonce per chunk.
- Limits: chunkSize 1...16 MiB, total ≤ 2 TiB (`1 << 41`). `decryptFile` checks chunk length bounds and bytes written
  vs header total (rejects trailing garbage). `decryptChunk` offset = 32 + index*(4 + chunkSize + 28), checks sizes.
  `streamInfo` reads the header only.

## 6. Key lifecycle and primitives

- Master key: `SymmetricKey(size: .bits256)` in `createMasterKey(wrappedBy:)`; throws `masterKeyAlreadyExists` if a
  blob exists (check and store not atomic).
- Wrap: PBKDF2-HMAC-SHA256, 600,000 iterations (CommonCrypto), 32-byte random salt, 32-byte output; password NFC-normalised,
  UTF-8; empty password → `encryptionFailed`. AES-256-GCM, AAD = 37-byte header.
- Blob: version(1 = 0x01) | iterations UInt32 LE | salt(32) | AES-GCM combined(master key 32).
- Unwrap: iterations 100,000...10,000,000, version 1; bad blob/CryptoKit error → `decryptionFailed`; auth failure →
  `wrongPassword`. Unwrapped length not checked to be 32 (`loadMasterKey` does check).
- Keychain: kSecClassGenericPassword, service "com.KoalaTVault", account "com.KoalaTVault.masterKeyBlob",
  `kSecAttrAccessibleWhenUnlocked` (not ThisDeviceOnly), no access group, not synchronizable. Write = `SecItemUpdate`,
  fallback `SecItemAdd` on not-found; a failed rewrap leaves the old blob (API-Memo #13, CryptoService side, confirmed).
  `hasMasterKeyBlob()` throws on Keychain errors; `wipeMasterKeyBlob()` throws on anything but success/not-found.
- `unwrapMasterKey(with:)`: loads key, zeroes temp Data; `noMasterKeyBlob` if no blob.
- `rewrapMasterKey(with:)`: requires loaded key; doesn't verify the old password.
- `loadMasterKey(from:)` (biometric unlock): doesn't zero caller's Data. `exportMasterKeyData()` returns a raw copy.
- In memory: `OSAllocatedUnfairLock<SymmetricKey?>`; `isKeyLoaded`, `wipeKey()` thread-safe. Ongoing
  `encryptFile`/`decryptFile`/`decryptChunk` copy the key at start; a mid-operation wipe doesn't stop them.
- **`FileSystem.isEncryptionEnabled` is simply `isKeyLoaded`**: whether the vault behaves as encrypted depends on
  whether the key is in memory. A locked vault looks like "no encryption" to `importSingleFile`/`isDuplicate`.
- Key read at: `exportMasterKeyData`, `rewrapMasterKey`, `encrypt`, `decrypt`, `encryptFile`, `decryptFile`, `decryptChunk`.
- `encrypt(data:authenticating:)`/`decrypt` used only for the map JSONs.

## 7. File operation failure paths

- `encryptFile`/`decryptFile`: staging → `synchronize` → `replaceItemAt` or `moveItem`. Failure leaves destination
  untouched. Count checks before commit. Plaintext read failure → `encryptionFailed`.
- `importSingleFile` (encrypted): `encryptFile` to new UUID → `loadMapping` → `saveMapping`. Failure between leaves an
  orphan (swept next launch). Source not lost. No rollback of earlier files in a multi-file import. Duplicate (same name
  AND hash) silently skipped but counted as succeeded; duplicate check by name only; same name/different content → "name 1".
- `importItems` limit counts sources (incl. duplicates) against `countFiles(root)` (skips hidden; trash not counted).
  `importFromCameraRoll` has no limit check (caller must call `checkImportAllowed`).
- `move` (encrypted): save destination map → `moveItem` → save source map. `moveItem` failure → stale destination entry.
  Source save failure → stale source entry. No source entry → file moved unmapped → **swept (deleted) next launch**.
  Folder move = plain `moveItem`.
- `copy` (encrypted): `copyItem` to new UUID → map save; failure → orphan (swept). Same fileID/key and nonces (harmless).
- `rename` (encrypted): map only. Plaintext: `moveItem`, throws on conflict.
- `moveToTrash`: `moveItem` to `.trash/<newUUID>` → load/save trash map → remove source map entry. `loadTrashMap` throw
  after the move → item invisible in trash, dangling source entry. Folders trashable (shown `isDirectory = false`).
- `restoreFromTrash`: lookup by trash UUID (`diskURL.lastPathComponent`), silent return if no entry; creates the absolute
  `originalDir`; `moveItem` (throws if destination exists); encrypted restore writes the map entry with no name-conflict
  resolution. Doesn't post `.fileRestored`.
- `permanentlyDelete`: by trash UUID; silent return if no entry (file left); else remove file → save map.
- `emptyTrash`: best-effort, ignores errors; always succeeds.
- `cleanupExpiredTrashItems`: 30 days; swallows read errors (can't wipe). **No production caller: auto-purge never runs.**
- `sweepOrphanedEncryptedFiles`: recursive; deletes non-hidden UUID-named files (case-insensitive) not in that
  directory's map. Bails if the map is unreadable (launch with no key works because the encrypted map fails as plaintext
  JSON). **A directory with no map file reads as empty: extensionless UUID-named plaintext user files, and encrypted files
  whose map was lost, are deleted.** `.trash` never swept.
- `migrateVaultToEncrypted`: **`guard total > 0 else { return }` (:648) before recursing**: subfolders of a directory
  with no plaintext files are never migrated. Progress resets per directory.
- `migrateFileToEncrypted`: `encryptFile` → save map → remove plaintext. Resume: a plaintext whose name is in the map is
  **deleted without verifying the encrypted copy** (:670-674).
- `migrateVaultToDecrypted`: per encrypted item → then deletes `.vault_map` (`try?`) → recurses (skips `.trash`).
  Progress denominator `mapping.count`.
- `migrateFileToDecrypted`: decrypt to `resolvedName` → remove encrypted → load map → remove entry → save. A crash before
  the save leaves a stale entry; a later encrypt migration then deletes that plaintext with no encrypted copy (narrow
  data-loss path). Decrypt failure leaves the original.
- **Trash is not migrated** either way: after decrypt migration + `wipeKey` + blob removal, trashed encrypted items stay
  under a key no longer stored. After encrypt migration a plaintext `.trash_map` stays plaintext.
- `open`/`prepareForExport`: decrypt to new temp subdir; caller must clean up.
- `write` (encrypted): plaintext temp → `encryptFile` to temp2 → `replaceItemAt` (atomic). Plaintext: `data.write(to:)`
  non-atomic.
- `exportToCameraRoll`: `.addOnly`; failures counted per item; non-media filtered and not counted.

## 8. PreferencesService (UserDefaults.standard)

| Key | Property | Default |
|---|---|---|
| `hasCompletedSetup` | Bool | false |
| `lockMode` | LockMode raw | `.none` (also on unknown) |
| `sortOption` | SortOption | `.name` |
| `sortDirection` | SortDirection | `.ascending` |
| `pendingMigrationType` | `MigrationViewController.MigrationType?` ("encrypt"/"decrypt") | nil |
| `pendingMigrationTargetLockMode` | LockMode? | nil |

- Target only meaningful for `encrypt`; nil removes the key. No schema/versioning key; no Core Data/SwiftData.
  Persistent stores: Documents files, UserDefaults, one Keychain item.
- Reinstall or UserDefaults loss: `lockMode` → `.none` while the blob and encrypted files remain (reverse of memo #18;
  not verified in AuthService).

## 9. API-Memo observations

- #1 trash lookup by name: **stale**; both look up by trash UUID (:533, :574). Only the restore name collision remains.
- #2 hardcoded "100": confirmed (:62).
- #13 CryptoService half: confirmed. #14 resolved: confirmed. #16 backup: confirmed (blob not ThisDeviceOnly, nothing
  excluded). #19: consistent on the CryptoService side. #20 `isDuplicate` decrypts the whole file on a name match:
  confirmed (:310-317); failures return false.

## Suspected issues

- FileSystem.swift:838-870, :621-628 — with a key loaded `loadEncryptedJSON` has no plaintext fallback. A `.trash_map`
  written plaintext in no-lock mode (:872-880) becomes unreadable after enabling a password: Recently Deleted fails, and
  `moveToTrash` moves the file (:510) then throws at `loadTrashMap` (:512) → invisible file, dangling map entry.
  **Likely data-loss path**; confirm with a test.
- FileSystem.swift:648 — early return skips subfolders in encrypt migration (root with only folders isn't migrated).
- FileSystem.swift:683-706 — progress inconsistent between directions; not monotonic.
- FileSystem.swift:670-674 — resume deletes plaintext on a name match without verifying the encrypted copy; with a stale
  entry (:719-722) this loses the only copy.
- FileSystem.swift:872-880, :80-82 — `saveEncryptedJSON` writes plaintext when no key is loaded. A lock between load and
  save in a background operation (move, copy, migration) overwrites an encrypted map with plaintext → unreadable after
  unlock; also leaks names.
- FileSystem.swift:80 — encryption decided per call by `isKeyLoaded`: import while locked in password mode would store
  plaintext (UI reachability not checked).
- FileSystem.swift:733-752 — orphan sweep deletes UUID-named plaintext user files and encrypted files whose map is missing.
- FileSystem.swift:425-445 — `move` of an encrypted item with no source entry → deleted next launch; stale entries on failure.
- FileSystem.swift:491-498, :536-540 — absolute paths in trash entries break restore after a container path change (guess).
- FileSystem.swift:604-619 — `cleanupExpiredTrashItems` never called.
- FileSystem.swift:572-581, :531-550 — silent success when the trash entry is missing.
- FileSystem.swift:545 — encrypted restore doesn't resolve name collisions.
- FileSystem.swift:820-831, :844 — `authDomain` comment misleading.
- FileSystem.swift:353-361 — `write()` plaintext temp with default protection.
- FileSystem.swift:726-729 — `cleanupTempFiles` deletes files in use by an open viewer/share sheet.
- CryptoService.swift:272 (guess) — `.complete` staging may fail while the device is locked during a background migration.
- CryptoService.swift:95 — unwrapped key length unchecked.
- CryptoService.swift:62-65 — `createMasterKey` check/store not atomic.
- Notes say SVC4; code writes/reads only **SVC5** (:258). The memo must name SVC5 as the format to keep.
- PreferencesService.swift:41 — depends on a view controller's nested enum.
- FileSystem.swift:27-45, :92-125 — `VaultItem.id` regenerated per listing.

NOT READ: FileKind.swift (not needed); AuthService and UI callers (out of scope).
