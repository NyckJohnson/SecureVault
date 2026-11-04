# Legacy-test scan: KoalaTVaultTests/BaselineFix24Tests.swift (stage 6 legacy check, 2026-11-04)

Owner: VaultLock (`VaultEncryptedDataCheck`). VaultLock's own tests (`VaultEncryptedDataCheckTests` in
LiveVaultLockCoverageTests.swift) have two cases, `unreadableSubdirectory` and `trashFolder`; the rest of
VaultLock's tests stub the check with a flag.

| Old test | Verdict |
| --- | --- |
| testVaultWithOnlyPlaintextFilesCountsAsEmpty | missed: only plaintext (top level, nested, empty file) → false |
| testIndexAloneCountsAsEncryptedData | missed: a `.vault_map` alone, in a subfolder, any content → true |
| testTrashEntryCountsAsEncryptedData | covered by `trashFolder` |
| testEncryptedFileWithoutIndexCountsAsEncryptedData | missed: an SVC5-header file, no index → true |
| testUnreadableRootCountsAsEncryptedData | missed: missing root → true |
| testEmptyRootHoldsNoEncryptedData | missed: completely empty root → false |
| testPermissionDeniedRootCountsAsEncryptedData | missed: root with permissions 0o000 → true (the up-front listing guard, not the enumerator's error handler) |
| testMayBeEncryptedFileIsTrueOnlyForTheEncryptedFormat | missed: plain, empty, 2-byte file → false; SVC5 header → true |
| testMayBeEncryptedFileIsTrueWhenTheFileCannotBeRead | missed: unreadable (0o000) file → true |

No contradicts or not-in-spec cases once the VaultLock spec states what counts as encrypted data (added
2026-11-04, describing today's behavior). The 8 missed cases move into VaultLock's tests; the old file is deleted.
