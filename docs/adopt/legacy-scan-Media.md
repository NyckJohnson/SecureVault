# Legacy test scan: Media (2026-10-30)
Legacy: KoalaTVaultTests/MediaPipelineTests.swift — VaultResourceLoaderDelegateTests, ThumbnailServiceTests (FileViewerViewControllerTests belongs to Viewer).
No `contradicts`, no `not-in-spec`.

- VaultResourceLoaderDelegateTests.testInitSucceedsForValidEncryptedFile — covered (EncryptedVideoLoaderTests.encryptedAssetUsesStreamScheme, encryptedAssetDelegatesToLoader)
- testInitSucceedsForEmptyEncryptedFile — **missed**: asset(for:) on an encrypted item with zero-byte plaintext returns a vault-stream asset; content length 0 → test-writer
- testInitSucceedsForLargeMultiChunkFile — covered (rangeAcrossChunks, requestToEnd, contentLengthAndRanges)
- testInitWithUnrecognisedExtensionFallsBackWithoutCrash — covered (contentTypeDefault)
- testInitFailsForPlainTextFile / TruncatedBeforeEndOfHeader / CorruptMagicBytes — covered (invalidHeaderThrows; real header parsing is VaultCrypto's)
- testInitFailsForNonExistentFile — covered by the invalid-header rule (the cipher's `streamInfo` fails on an unreadable file; at Media level this is the same mock throw as invalidHeaderThrows). Orchestrator: no extra test.
- ThumbnailServiceTests.testClearAllCacheDoesNotCrash / testClearCacheForSpecificItemDoesNotCrash — obsolete (smoke; behavior covered by clearCacheRegenerates, clearCacheForItem)
- testCorruptNonVideoEncryptedFileDeliversNilCompletion / testCorruptVideoFileDeliversNilCompletion / testTruncatedEncryptedFileDeliversNilCompletion — covered (corruptGivesNil, encryptedVideoInvalidHeader)
- testCancellingThumbnailBeforeDecryptionPreventsCompletion — covered (cancelBeforeWorkStarts)
- testSecondThumbnailRequestForSameItemUsesCache — covered (secondRequestHitsCache)
