# Coverage triage: VaultStore (2026-10-28)

Report: 88 uncovered lines in 54 blocks after unit 3. Classified by the coverage analyst.

## Test seams
- Read-only folder (posixPermissions 0o555) → copy/create/rename/move/delete fail with `.io`.
- `MockFileCipher.errorToThrow` (unused by VaultStore tests so far; it also breaks encrypted index reads, so pair it with a plaintext-JSON index or `.noKeyLoaded`).
- `HeaderAwareTestCipher.truncatesNewCopies`, fixture `ghostTrashItem()`, `diskSealedFile`.
- Needed: a test-only `SelectiveFailingCipher` decorator (fail `encrypt(_:context:)` while `encryptFile` works; fail `decryptChunk`/`streamInfo` with `.noKeyLoaded`; make index `encrypt` return `{}`).

## missed (tests to write)
LiveVaultStore 111 (missing trash file not listed), 140-141 (contents of unlistable folder), 161 (date-sort tie → id),
197 (plaintext write read-only), 212 (encrypted write encryption fails); FileOps 23, 69 + 93-96, 79-80, 86-87 (decorator),
173, 185-186, 192-193 (decorator), 222; VaultIndex 69, 96; VaultMigrationSteps 143 + 572-575, 187-188, 211 (decorator),
273-274, 314, 324, 330-332 (decorator), 349-350, 373-374, 397-398 (decorator), 480, 511, 522 + 553 (decorator), 603;
VaultNaming 37 ("a 1.txt" → "a 2.txt"); VaultTempFiles 24; VaultTrash 95 (absolute path inside root re-based), 152,
158-161, 217, 234-235, 245, 267. Full behaviors: see the analyst's per-block notes, copied into the test-writer briefs.

## exempt (markers added)
FileOps 38; VaultIndex 89; VaultMigrationSteps 214-218, 404-406, 530, 538-539, 595-596; VaultNaming 47; VaultTrash 75.

## not-in-spec (human decision)
- VaultIndex 119: `relativePath` falls back to the last path component for a URL outside the root.
- VaultMigrationSteps 30-32: `countFiles` throws `.io` on an unreadable subfolder instead of a partial count.
- VaultMigrationSteps 366: migrating a trash item missing from the trash map throws `.notFound`.
- VaultTrash 297-299: `purgeExpiredTrash` keeps an entry whose file can't be removed, purges the rest, saves the map, then throws the first error.
