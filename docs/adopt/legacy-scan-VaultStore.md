# Legacy-test scan: VaultStore

New tests are Swift Testing (`@Test`) in `KoalaTVaultTests/VaultStore/`. Abbreviations: FO = VaultFileOperationsTests,
LS = LiveVaultStoreTests, VI = VaultIndexTests, VN = VaultNamingTests, VT = VaultTrashTests, OS = OrphanSweepTests,
MS = VaultMigrationStepsTests, TF = VaultTempFilesTests.

Legacy "import" (`importItems`) belongs to the Import module. Where a legacy test only uses import to set up, it is
treated as addFile.

## Pass A: FileSystemTests, EncryptedFileSystemTests, FileSystemMappingIntegrityTests, EdgeCaseTests, AdditionalEdgeCaseTests

| Legacy file | Legacy case | Class | Notes |
|---|---|---|---|
| FileSystemTests | testCreateFolder | covered | FO "createFolder makes a plaintext-named folder in both modes" |
| FileSystemTests | testCreateFolderHandlesNameConflict | covered | VN "A second folder with the same name gets ' 1', a third ' 2'" |
| FileSystemTests | testContentsReturnsCreatedFolder | covered | FO createFolder test, plus LS listing tests |
| FileSystemTests | testContentsIsEmptyInitially | covered | LS "An empty folder lists nothing" |
| FileSystemTests | testImportFile | covered | FO "addFile in plaintext mode copies the file under its name" |
| FileSystemTests | testImportSameFileTwiceDoesNotDuplicate | obsolete | Duplicate detection belongs to Import. VaultStore only numbers conflicts with " 1". |
| FileSystemTests | testImportDifferentFileWithSameNameCreatesConflict | covered | VN "A conflicting file gets the number before the extension" |
| FileSystemTests | testDeleteFile | covered | VT "moveToTrash moves a file into .trash/<uuid> and records an entry" |
| FileSystemTests | testRenameFile | covered | FO "Renaming a plaintext file renames it on disk" |
| FileSystemTests | testMoveFileToFolder | covered | FO "Moving a plaintext file relocates it" |
| FileSystemTests | testOpenFileReturnsReadableContent | covered | LS "Opening a plaintext item returns its disk URL" |
| EncryptedFileSystemTests | testImportFileCreatesEncryptedVersion | covered | FO "addFile in encrypted mode stores a new extensionless UUID file and indexes the name" |
| EncryptedFileSystemTests | testEncryptedFileHasUUIDDiskName | covered | FO addFileEncrypted; LS "An encrypted file's id is its UUID disk path" |
| EncryptedFileSystemTests | testEncryptedFileOpenReturnsCorrectContent | covered | LS "Opening an encrypted item decrypts into a new temp folder as <temp>/<name>" |
| EncryptedFileSystemTests | testEncryptedFileOnDiskIsUnreadable | obsolete | Ciphertext quality belongs to VaultCrypto. The SVC5 header is covered by the createDocument and addFile tests. |
| EncryptedFileSystemTests | testRenameEncryptedFile | covered | FO "Renaming an encrypted file changes only the index entry" |
| EncryptedFileSystemTests | testRenameEncryptedFilePreservesContent | covered | FO renameEncrypted (index only, file untouched) |
| EncryptedFileSystemTests | testMoveEncryptedFile | covered | FO "Moving an encrypted file moves the file and its index entry" |
| EncryptedFileSystemTests | testMoveEncryptedFilePreservesContent | covered | FO moveEncryptedFile / moveFolderWithContents |
| EncryptedFileSystemTests | testDeleteEncryptedFileRemovesFromMapping | covered | VT "moveToTrash removes an encrypted file's entry from its folder index" |
| EncryptedFileSystemTests | testWriteEncryptedFileUpdatesContent | covered | LS "Writing an encrypted item keeps its file and index entry, changes its content, and leaves no plaintext" |
| EncryptedFileSystemTests | testOpenEncryptedFileWithNoKeyThrows | covered | LS "Opening an encrypted item without a key throws locked and leaves no temp file" |
| EncryptedFileSystemTests | testCreateDocumentUnderKeyWritesUUIDNamedSVC5FileAndMapEntry | covered | FO "createDocument in encrypted mode is encrypted and indexed under a UUID file name" |
| EncryptedFileSystemTests | testCreateDocumentWithSameNameUnderKeyGetsNumberSuffix | covered | VN "A document name that conflicts gets ' 1' before .rtf" |
| EncryptedFileSystemTests | testCreateDocumentWithoutLockNeverTruncatesExistingDocument | covered | FO "createDocument never truncates an existing document of the same name" |
| FileSystemMappingIntegrityTests | testAbsentMappingIsTreatedAsEmpty_NotAnError | covered | VI "A folder without an index lists its files under their disk names" |
| FileSystemMappingIntegrityTests | testCorruptedMappingThrows_InsteadOfSilentlyAppearingEmpty | covered | VI "A garbage index throws indexUnreadable and is not overwritten by a write attempt" |
| FileSystemMappingIntegrityTests | testRename_DoesNotOverwriteMapping_WhenExistingMappingIsCorrupted | missed | Rename with an unreadable index throws `.indexUnreadable` and leaves the index bytes unchanged. VI covers only list and addFile. |
| FileSystemMappingIntegrityTests | testMove_DoesNotOverwriteDestinationMapping_WhenDestinationMappingIsCorrupted | missed | Move into a folder with an unreadable index throws `.indexUnreadable`, leaves the destination index bytes unchanged, and the item stays where it was. |
| FileSystemMappingIntegrityTests | testCleanupExpiredTrashItems_DoesNotThrowOrWipe_WhenTrashMapIsCorrupted | contradicts | The old test expects the purge not to throw. The spec says purgeExpiredTrash "throws without writing". The no-write half is covered by VT purgeUnreadableIndex. |
| FileSystemMappingIntegrityTests | testContentsOfTrash_ThrowsOnCorruptedMap_RatherThanReturningEmpty | covered | VT "trashContents with an unreadable trash index throws indexUnreadable" |
| FileSystemMappingIntegrityTests | testFilesToMigrate_ExcludesAlreadyMigratedFiles_OnASecondCall | covered | MS itemsToMigrate skip test; MS "Migrating every plaintext file in order encrypts all of them" |
| FileSystemMappingIntegrityTests | testSweepPreservesEncryptedFilesWhenKeyIsNotLoaded | covered | OS "sweepOrphans does nothing in encrypted mode while no key is loaded" |
| FileSystemMappingIntegrityTests | testSweepPreservesEncryptedFilesInSubdirectoryWhenKeyIsNotLoaded | covered | OS sweepSkipsWithoutKey (the no-key rule is global) |
| FileSystemMappingIntegrityTests | testSweepStillDeletesOrphansAfterKeyIsReloaded | covered | OS sweepDeletesUnlistedUUIDFiles |
| FileSystemMappingIntegrityTests | testSweepDeletesUUIDNamedFileWithNoMappingEntry | covered | OS sweepDeletesUnlistedUUIDFiles; the SVC5-header rule is covered by OS's plaintext-UUID test |
| FileSystemMappingIntegrityTests | testSweepKeepsUUIDNamedFileInFolderWithNoIndex | covered | OS "sweepOrphans leaves folders with no index alone" |
| FileSystemMappingIntegrityTests | testSweepKeepsUnmappedUUIDFileWhenKeyIsNotLoaded | covered | OS sweepSkipsWithoutKey |
| FileSystemMappingIntegrityTests | testSweepKeepsMappedEncryptedFiles | covered | OS sweepDeletesUnlistedUUIDFiles (keeps listed ones) |
| FileSystemMappingIntegrityTests | testSweepDoesNotDeleteNonUUIDNamedFiles | covered | OS "sweepOrphans keeps files that have an extension or a non-UUID name" |
| FileSystemMappingIntegrityTests | testSweepRecursesIntoSubdirectories | covered | OS "sweepOrphans sweeps the root and nested folders that have a readable index" |
| FileSystemMappingIntegrityTests | testSweepKeepsUUIDNamedFileInSubdirectoryWithNoIndex | covered | OS sweepSkipsFoldersWithoutIndex |
| FileSystemMappingIntegrityTests | testContents_ReadsMap_EncryptedWithLastPathComponentDomain | covered | VI "An index encrypted with the accepted context is decoded" (".vault_map") |
| FileSystemMappingIntegrityTests | testContents_ReadsLegacyMap_EncryptedWithEmptyAAD | covered | VI same test, "" argument |
| FileSystemMappingIntegrityTests | testImport_IntoFolderWithLegacyEmptyAADMap_PreservesExistingEntries | possibly missed | Behavior: addFile into a folder whose index is sealed with a fallback context ("" or folder-relative) keeps the existing entries. VI's rewrite test may use only a plaintext index. |
| FileSystemMappingIntegrityTests | testContents_ThrowsMappingUnreadable_ForCompletelyUnrecognizedAADDomain | covered | VI "An encrypted index sealed under an unknown context is unreadable and left untouched" |
| FileSystemMappingIntegrityTests | testMappingRoundTrip_SurvivesSaveAndLoad_ViaRealOperations | covered | VI plaintext rename index test; FO renameEncrypted |
| FileSystemMappingIntegrityTests | testSweepDeletesNothingWhenVaultMapIsUnreadableAndKeyIsLoaded | covered | OS "sweepOrphans leaves a folder with an unreadable index alone and doesn't touch the index" |
| EdgeCaseTests | testEmptyFolderContentsIsEmpty | covered | LS "An empty folder lists nothing" |
| EdgeCaseTests | testEmptyFolderAfterDeletingAllFiles | covered | VT moveToTrash tests; VT moveToTrashRemovesIndexEntry |
| EdgeCaseTests | testImportFileWithLongName | missed (low value) | A 200-character name round-trips through addFile and listing. |
| EdgeCaseTests | testRenameToLongName | missed (low value) | Renaming to a 200-character name works. |
| EdgeCaseTests | testImportFileWithNoExtension | covered | VN no-extension conflict test |
| EdgeCaseTests | testCopyFileWithNoExtension | covered | VN copy numbering; VN no-extension conflict test |
| EdgeCaseTests | testDeleteFileWithNoExtension | covered | VT moveToTrashRecordsEntry, trashContentsFlatList |
| EdgeCaseTests | testMoveFileToSameDirectory | covered | FO "Moving an item into its own folder changes nothing" |
| EdgeCaseTests | testImportFolder | obsolete | Folder import belongs to Import. |
| EdgeCaseTests | testImportNestedFolder | obsolete | Folder import belongs to Import. |
| EdgeCaseTests | testWritePlaintextFile | covered | LS "Writing a plaintext item replaces its content" |
| EdgeCaseTests | testWriteEncryptedFile | covered | LS encrypted write test |
| EdgeCaseTests | testTrashCleanupRemovesExpiredItems | covered | VT "purgeExpiredTrash removes only entries deleted more than 30 days before now" |
| EdgeCaseTests | testRestoreWhenOriginalFolderDeleted | covered | VT "restore recreates the original folder when it is gone" |
| AdditionalEdgeCaseTests | testImportFolderWithConflictingName | covered | VN folder conflict test (folder import itself belongs to Import) |
| AdditionalEdgeCaseTests | testImportMultipleFoldersWithSameName | covered | VN same test |
| AdditionalEdgeCaseTests | testCopyEncryptedFileToSubfolder | covered | FO "Copying an encrypted file into another folder indexes it there" |
| AdditionalEdgeCaseTests | testMoveEncryptedFileThenVerifyContent | covered | FO encrypted move test |
| AdditionalEdgeCaseTests | testImportFileWithSpecialCharacters | missed (low value) | A name with spaces and symbols ("file with spaces & symbols!.txt") is kept verbatim in listings. |
| AdditionalEdgeCaseTests | testRenameToNameWithSpecialCharacters | missed (low value) | Renaming to such a name keeps it verbatim, in both modes. |
| AdditionalEdgeCaseTests | testImportRenameMoveDelete | covered | Composite of FO rename/move, VT moveToTrash and trashContents |
| AdditionalEdgeCaseTests | testEncryptedImportRenameMoveDelete | covered | Composite of FO/VT tests; trash shows the renamed original name |
| AdditionalEdgeCaseTests | testImportLargeFile | obsolete | No size behavior in VaultStore's spec. |
| AdditionalEdgeCaseTests | testEncryptedLargeFile | obsolete | Multi-chunk SVC5 belongs to VaultCrypto. |

Pass A summary:
- missed: rename with an unreadable index (throws `.indexUnreadable`, index bytes unchanged).
- missed: move into a folder with an unreadable index (throws, destination index unchanged, item stays in its source).
- possibly missed: addFile into a folder whose index uses a fallback context keeps the existing entries.
- missed (low value): 200-character names and names with spaces/symbols through addFile, rename and listing.
- contradicts: the old test expects purge with an unreadable trash map not to throw; the spec says it throws without writing.
- not-in-spec: none. Import-owned cases (same file imported twice is deduplicated; folder and nested-folder import) are obsolete here; Import's spec must carry them.
