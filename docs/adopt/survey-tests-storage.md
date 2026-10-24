# Survey: tests (storage, crypto, vault types)

STATUS: done
PASS: tests

All 14 files are **XCTest** (no Swift Testing). Read only, not run.

## Isolation (all files)

- `VaultTestCase` (VaultTestCase.swift:12-32): `setUp` makes `tmp/<UUID>` and a `VaultDirectory(name:"test", diskURL:tmp,
  rootURL:tmp)`; trash in `<tmp>/.trash`; real Documents not used. `tearDown`: `CryptoService.shared.wipeKey()`,
  `try? wipeMasterKeyBlob()`, remove temp dir, `FileSystem.shared.cleanupTempFiles()` (wipes all of tmp).
- **Real Keychain**: encrypted tests call `createMasterKey(wrappedBy:)` on the single real item ("com.KoalaTVault"); a
  leaked blob makes the next create throw `masterKeyAlreadyExists`. `CryptoServiceTests` creates it in `setUpWithError`
  (one leak fails the class). `EncryptedFileSystemTests.setUp` uses `try?` before `super.setUp` (silent). A simulator
  with a real app vault would lose its blob (guess).
- Singletons `CryptoService.shared`, `FileSystem.shared`, `PreferencesService.shared` (SortTests): tests must run serially.
- Fixed temp names (`tmp/test.txt`, `tmp/noextension`, `tmp/large.txt`, `tmp/TestFolder`) removed with `defer`;
  parallel runs would collide.
- Real Documents touched only by `FileSystemMappingIntegrityTests.testMove_DoesNotOverwriteDestinationMapping...`
  (~:125, creates `Destination-<UUID>` in `.root`) and `VaultDirectoryTests` (root exists).
- No-key mapping tests rely on "no key → plaintext JSON".
- Flaky/weak: `SortTests` date tests (50ms sleep, weak `<=`/`>=`).

## Per file

1. **VaultTestCase.swift** (33): base class only.
2. **CryptoServiceTests.swift** (458) — crypto/key:
   - Key lifecycle: `isKeyLoaded` after create/wipe; unwrap restores the same key; wrong password → `.wrongPassword`;
     no blob → `.noMasterKeyBlob`; `hasMasterKeyBlob` true/false; create with existing blob → `.masterKeyAlreadyExists`.
   - Rewrap: new password unwraps; without key throws; preserves the encryption key (regression).
   - `encrypt`/`decrypt(authenticating:)`: round trip, differs, nonce randomness, empty, 1 MB, other key fails, no key throws.
   - `encryptFile`/`decryptFile`: round trip; unreadable; larger. SVC5: empty file, exact 1 MiB, multi-chunk,
     `streamInfo` sizes; `decryptChunk` by index; out of range (-1, 1) throws; no key → `.noKeyLoaded`, no output.
     Tamper: header flips at 8 and 20; wrong magic (decrypt, `streamInfo`); swapped chunks; chunk from another file;
     dropped last chunk; mid-chunk truncation leaves no output. In-place encrypt/decrypt. Failed decrypt leaves an
     existing destination; success replaces it.
   - `exportMasterKeyData` 32 bytes / `.noKeyLoaded`. `loadMasterKey(from:)` restores; 16/0/33 bytes → `.decryptionFailed`.
   - `CryptoError` descriptions; `.keychain` includes status.
   - Layout hardcoded (header 32, chunk 1 MiB, overhead 4+28): pins SVC5.
   - Not covered: corrupt blob / bad iteration count; KDF params (600k); `decryptChunk` bound checks beyond index; 2 TiB
     and chunk-size limits; trailing garbage; empty password; `wipeMasterKeyBlob` errors; Keychain attributes;
     concurrency; `loadMasterKey` not zeroing caller data.
3. **FileSystemMappingIntegrityTests.swift** (487; own tmp root, plain XCTestCase) — mapping, orphan sweep, migration:
   - Absent map → empty plaintext listing; corrupt map → `contents` throws `.mappingUnreadable`; `rename`/`move`
     (destination) don't overwrite a corrupt map; `cleanupExpiredTrashItems` with corrupt `.trash_map` doesn't write;
     `contentsOfTrash` throws on corrupt.
   - `filesToMigrate(toEncrypted:)` fresh after `migrateFileToEncrypted` of one file.
   - Orphan sweep: key wiped → mapped files in root and subfolder survive; key loaded → orphan deleted, mapped kept;
     unmapped UUID file deleted; non-UUID untouched; recurses.
   - AAD chain: ".vault_map" AAD reads; empty AAD reads; import into a legacy empty-AAD map keeps entries; unknown AAD →
     `.mappingUnreadable`. Relative-path fallback untested; comment at ~:395 misnumbers it.
   - Encrypted save/load round trip via `rename`.
4. **FileSystemTests.swift** (136) — file ops, plaintext: `createFolder` + conflict ("TestFolder 1"); `contents` empty/with
   folder; import; same file twice not duplicated; same name/different content → "test 1.txt"; `delete`, `rename`,
   `move` to subfolder, `open`.
5. **EncryptedFileSystemTests.swift** (172) — file ops, encrypted: import `isEncrypted`, disk name 36-char UUID, open
   returns content, bytes don't contain plaintext; rename; move; delete removes item and disk file; `write` updates;
   `open` with no key throws.
6. **TrashTests.swift** (223) — trash: delete → trash shows original name (1 or 2 items); restore reappears with content;
   `permanentlyDelete`; `emptyTrash`; `cleanupExpiredTrashItems` keeps recent; encrypted trash and restore. Plaintext
   cases have a plaintext `.trash_map`.
7. **SortTests.swift** (176) — sort/browse: folders first; name asc/desc; type grouping and desc; date asc/desc (weak);
   option and direction persist; `SortOption.allCases` = 3; `displayName`.
8. **CopyTests.swift** (152) — copy: duplicate kept; "test 1.txt", "test 2.txt"; content; to subfolder; encrypted copy
   keeps `isEncrypted`, content, conflict naming.
9. **ConflictResolutionTests.swift** (136) — import dedup ×2/×3; "name 1"; no-extension variants; folder conflicts
   ("MyFolder 1", "MyFolder 2"); encrypted variants; different extensions don't conflict.
10. **VaultDirectoryTests.swift** (41) — `VaultDirectory.root` exists, is dir, named "KoalaTVault", stable; initializer.
11. **VaultItemTests.swift** (102) — `==`/hash by `id` only; Set/dict use; field storage; `name` mutable.
12. **FileKindTests.swift** (68) — every extension group, "other" (xyz, empty, bin, html), case insensitivity.
13. **EdgeCaseTests.swift** (228) — empty folder; 200-char names (import, rename); no-extension import/copy/delete; move to
    same directory doesn't throw (no outcome check); folder and nested-folder import; plaintext and encrypted `write`;
    **expired-trash cleanup removes a 31-day-old entry** (only real removal test; DEBUG helpers `testTrashMap`,
    `saveTestTrashMap`, `TrashEntryForTesting`); `testRestoreWhenOriginalFolderDeleted` (vacuous, see below).
14. **AdditionalEdgeCaseTests.swift** (212) — folder import conflicts; encrypted copy to subfolder and move with content
    checks; special characters in import/rename; sequential import→rename→move→delete flows (plaintext, encrypted);
    1 MB import both modes.

## Candidate areas

- crypto/key: 2. mapping: 3 (+ encrypted parts of 5, 8, 9, 13, 14). file ops: 4, 5, 8, 9, 13, 14. trash: 6, parts of 13,
  3 (corrupt trash map). sort/browse: 7. vault types: 10, 11, 12. orphan sweep: 3. migration: one test in 3 (rest in
  MigrationTests). import limit: none here (FileImportLimitTests). temp files: only the tearDown call.

## Suspected issues: pinned vs not

Pinned:
- Corrupt map → `mappingUnreadable`, not overwritten by rename/move; `contents`, `contentsOfTrash`, cleanup cases.
- AAD chain (".vault_map", empty, unknown).
- Orphan sweep bails with no key; deletes unmapped UUID files; skips non-UUID; recurses. **The `…NoMappingEntry` and
  `…Recurses` tests plant the file with no `.vault_map` at all, so they pin "no map = empty = delete"** (the risky behavior).
- `cleanupExpiredTrashItems` removes 31-day-old, keeps recent (still no production caller).
- Trash by trash UUID via flows; plaintext and encrypted round trips.
- `VaultItem` equality by `id` (nothing asserts id stability).
- `filesToMigrate` recomputed; dedup end state.

Gaps:
- **Trash map plaintext → encrypted** (likely data-loss path): never exercised.
- Migration `total > 0` early return (FileSystem.swift:648) and progress.
- Resume deleting plaintext on a name match without verifying.
- `migrateVaultToDecrypted`; stale entry after crash; trash not migrated.
- `saveEncryptedJSON` plaintext when no key.
- `move` of encrypted item with no source entry; partial-failure stale entries.
- `restoreFromTrash` conflict; encrypted restore name collision; silent return on missing entry (restore,
  `permanentlyDelete`); trashing a folder.
- `fileLimitReached` / "100" message; `importFromCameraRoll`; `checkImportAllowed` (maybe in FileImportLimitTests).
- `isEncryptionEnabled == isKeyLoaded`.
- Absolute-path trash entries.
- `cleanupTempFiles`, `open`/`prepareForExport`/`write` temp clean-up; staging protection; `.fileRestored`.
- Hidden files skipped (implicit only); `emptyTrash` errors; plaintext rename conflict; encrypted duplicate rename;
  sweep UUID case; `.trash` never swept.

## Obsolete, duplicated or weak

- Duplicates: `FileSystemTests.testImportSameFileTwiceDoesNotDuplicate` and `testImportDifferentFileWithSameNameCreatesConflict`
  = ConflictResolutionTests versions; `EdgeCaseTests.testEmptyFolderContentsIsEmpty` = `FileSystemTests.testContentsIsEmptyInitially`;
  `testEmptyFolderAfterDeletingAllFiles` ≈ `testDeleteFile`; `EdgeCaseTests.testWrite*` ≈
  `EncryptedFileSystemTests.testWriteEncryptedFileUpdatesContent`; trash round trips re-walked in AdditionalEdgeCaseTests.
- `EdgeCaseTests.testRestoreWhenOriginalFolderDeleted` (:206-227): `guard … else { return }` makes it vacuous; may restore
  the folder (trash shows folders `isDirectory = false`).
- `EdgeCaseTests.testMoveFileToSameDirectory`: no outcome check.
- `AdditionalEdgeCaseTests.testImportMultipleFoldersWithSameName`: same URL twice; pins "folders get no dedup".
- `SortTests.testSortByTypeDescending`: awkward NSString cast. `testSortByDateModified*`: nearly vacuous.
- `VaultItemTests` initializer-only tests (low value; "ByDefault" misnomer).
- `VaultDirectoryTests`: real-FS dependency.
- `CryptoServiceTests` error-description tests: trivial.

## Suspected issues

- EdgeCaseTests.swift:206-227 — vacuous restore test.
- EdgeCaseTests.swift:187-200 — depends on DEBUG-only helpers.
- FileSystemMappingIntegrityTests.swift ~:125 — writes into the real Documents vault.
- CryptoServiceTests.swift:19-23, VaultTestCase.swift:16 — shared real Keychain item; order/leak sensitive; can delete a
  real blob on the same simulator. New Swift Testing suites need `.serialized` (or an injected Keychain/store).
- EncryptedFileSystemTests.swift:6-9 — `try?` swallows a leaked-blob error.
- FileSystemTests.swift:1-6 — header says "Untitled.swift".
- FileSystemMappingIntegrityTests.swift ~:395 — fallback misnumbered; relative-path fallback untested.
- SortTests.swift:119-151 — date tests pass in any order.

NOT READ: nothing from the brief skipped. Out of scope: MigrationTests, FileImportLimitTests, PreferencesServiceTests, others.
