# Legacy-test scan: KoalaTVaultTests/BaselineFix20_23Tests.swift (stage 6 legacy check, 2026-11-04)

Owner: VaultStore (migration steps). Scanner verdict: all 10 cases of `EncryptMigrationSafetyTests` are
covered by the module's own tests; no missed, contradicts or not-in-spec cases.

| Old test | Covered by |
| --- | --- |
| testMigratingAFileEncryptsItAndRemovesThePlaintext | VaultMigrationStepsTests `migrateToEncryptedBasic`, `migrateToEncryptedAll` |
| testMigratingWithoutKeyThrowsKeepsPlaintextAndWritesNoPlaintextIndex | `lockedMigrationOperations`; VaultMigrationRecoveryTests `keyLostDuringEncryptStep` |
| testMigrationWithKeyWipedLeavesNoReadablePlaintextIndexAfterPartialFolder | `lockedMigrationOperations`, `keyLostDuringEncryptStep` |
| testResumeAfterKeyWipeFinishesTheFolder | `lockedMigrationOperations`, `itemsToEncryptSkipsEncrypted`, `migrateToEncryptedAll`, `migrateToEncryptedDifferentContent`; resume logic in LiveLockMigrator*Tests |
| testLegacyPlaintextIndexIsRecoveredAndReEncrypted | `finishEncryptionSealsIndexes`; VaultIndexTests |
| testFinishEncryptionRecursesIntoSubfolders | `finishEncryptionSealsIndexes`, `finishEncryptionSealsTrashedFolderIndex`, `finishEncryptionSealsTrashMap` |
| testFinishEncryptionWithoutKeyThrowsLocked | `finishEncryptionLocked` |
| testRerunDeletesLeftoverPlaintextWhenEncryptedCopyMatchesByteForByte | `migrateToEncryptedDedupes`; `encryptRerunWithIdenticalCopy` |
| testRerunKeepsDifferingSameNamePlaintextAndEncryptsItUnderAFreeName | `migrateToEncryptedDifferentContent`; `encryptRerunWithDifferentContent` |
| testRerunKeepsSameSizeDifferentPlaintextInsteadOfDeletingIt | `migrateToEncryptedDifferentContent` (same size, different bytes) |

Notes from the scan:
- No new test runs the whole migrate → wipe → unlock → finish sequence against the real `LiveVaultStore`;
  the pieces are covered separately (store steps, and the migrator's resume with a fake store).
- The old tests used the real cipher; the new ones use test ciphers whose output is deterministic, so a
  store that compared ciphertext instead of decrypted content would pass them. Whether VaultCrypto's
  tests cover the identical-content comparison was not checked.
- `LegacyCryptoSupport.swift` is used only by this file.
