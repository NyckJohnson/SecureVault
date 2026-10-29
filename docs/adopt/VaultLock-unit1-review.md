# VaultLock unit 1 review follow-ups (reviewer pass, 2026-10-29)

To handle in coverage triage (test-writer, from the spec):
- setUp / prepareToAddLock rollback with an EXISTING blob over encrypted data (biometric store fails): blob must not be deleted; key wiped; biometric item gone; lockMode unchanged.
- switchMode(.passwordAndBiometrics) with biometrics unavailable → .biometricsUnavailable, nothing stored; switchMode to the current mode (no-op); changePassword when rewrap fails after a successful verify.
- Log-only paths: rollback blob-delete failure; unlockWithBiometrics mismatch with item delete failing (still .biometricChanged); stale biometric item delete failure in setUp (setUp still succeeds).
- lockError(from:) fallbacks: corruptBlob/invalidKeyData/encryptionFailed/decryptionFailed → .keychain(errSecDecode); masterKeyAlreadyExists → .keychain(errSecDuplicateItem); non-VaultCryptoError → .keychain(errSecInternalError).
- VaultEncryptedDataCheck.holdsEncryptedData fixtures: empty root, .vault_map, SVC5 file, plain file, non-empty .trash, unreadable root.

Optional, not acted on: log the original VaultCryptoError in lockError(from:) fallbacks; set `trailing_comma: mandatory_comma: true` in .swiftlint.yml to drop the suppressions.
