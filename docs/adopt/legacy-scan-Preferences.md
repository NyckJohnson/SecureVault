# Legacy-test scan: Preferences (2026-10-27)

Legacy: KoalaTVaultTests/PreferencesServiceTests.swift. New: KoalaTVaultTests/Preferences/.

| Legacy case | Result | Covered by |
| --- | --- | --- |
| testHasCompletedSetupDefaultsFalse | covered | defaultsOnEmptyStore |
| testHasCompletedSetupCanBeSetTrue | covered | hasCompletedSetupRoundTrip |
| testHasCompletedSetupPersists | covered | persistenceAcrossStores, readsDocumentedKeys |
| testLockModeDefaultsToNone | covered | defaultsOnEmptyStore |
| testLockModeCanBeSetToPassword | covered | lockModeRoundTrip |
| testLockModeCanBeSetToPasswordAndBiometrics | covered | lockModeRoundTrip |
| testLockModeCanBeResetToNone | covered | lockModeRoundTrip (.none row) |
| testLockModePersists | covered | persistenceAcrossStores |
| testPendingMigrationTypeRoundTrips | obsolete (split properties replaced by `pendingMigration`) | encryptMigrationWithTarget, decryptMigration, nilPendingMigrationRemovesKeys |
| testPendingMigrationTargetLockModeRoundTrips | obsolete (a target without a type is not a spec state) | encryptMigrationWithTarget, encryptMigrationWithoutTarget, nilPendingMigrationRemovesKeys |

No missed, contradicting or not-in-spec cases.
