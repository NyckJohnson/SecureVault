# Baseline fixes

Journey tests (KoalaTVaultUITests/Journeys/) first run, 2026-10-24: 80 tests, 68 pass, 12 fail.
Decisions by the human, 2026-10-24.

## App bugs (app ≠ memo): all fixed in the baseline

| # | Journey test | Today | Memo | Status |
| --- | --- | --- | --- | --- |
| 1 | J3 testJourney3_FolderNameWithSlashShowsError | raw system error "The file “b” doesn’t exist." | alert "Names can't contain /" | fixed |
| 2 | J3 testJourney3_MoveIntoItsOwnFolderDoesNothing | renamed "alpha 1.txt" | nothing changes | fixed |
| 3 | J3 testJourney3_FolderCannotBeMovedIntoItself | silent failure (`try?`), picker offers the folder itself | alert "A folder can't be moved into itself" | fixed |
| 4 | J4 testJourney4_PhotoPickerCancelClosesPickerAndImportsNothing | Cancel leaves the picker open | closes, imports nothing | fixed |
| 5 | J5 testJourney5_UndecryptableFileShowsCantBeOpenedLabel | blank black page | "This file can't be opened." | fixed |
| 6 | J5 testJourney5_EditorLoadFailureShowsErrorAndIsReadOnly | editable after a failed load | read-only | fixed |
| 7 | J6 testJourney6_RestoreWithSameNameInFolderGetsNumberSuffix | error alert, item stays in trash (no lock) | restored as "alpha 1.rtf" | fixed |
| 8 | J9 testJourney9_PriceUnavailableShowsMessageAndUnlockStillPresent | empty price label | "Price unavailable" | fixed |
| 9 | J9 testJourney9_PendingPurchaseShowsApprovalAlertAndKeepsPaywall | alert "Purchase is pending approval." (EntitlementService.swift:16) | "Purchase pending approval." (the app changes to match the memo) | fixed |
| 10 | J4 testJourney4_ChooseFolderOpensDocumentPickerAndCancelImportsNothing | iOS 18 only: SIGABRT after Cancel in the folder picker (`DOCWeakProxy`; picker delegate released early, ImportService.swift:62) | Cancel imports nothing | fixed |
| 11 | (planned in memo Known issues) | "Remove Lock" leaves encrypted `.vault_map`s, then deletes the key | listings work after Remove Lock | fixed |
| 12 | (planned) | plaintext `.trash_map` unreadable once a lock is on | delete / Recently Deleted work after adding a lock | fixed |
| 13 | (planned) | New Document writes an unencrypted, unindexed file in an encrypted vault; truncates a same-name document | encrypted + indexed, name conflict resolved (move the "/" check into FileSystem too) | fixed |
| 14 | (planned) | 30-day trash purge never runs | purged after unlock (shell responsibility) | fixed |
| 15 | (planned) | migration screen starts a second loop when the lock screen is dismissed over it | one loop | fixed |
| 16 | (planned) | folder picker Cancel keeps the pending (bulk) move; Move Here double-tap calls the delegate twice | Cancel clears it; one call | fixed |
| 17 | (planned) | orphan sweep deletes extensionless UUID-named plaintext files in folders with no index | only sweeps encrypted, indexed folders | fixed |
| 18 | (planned) | Info.plist leftovers (`NSFaceIDUsageDscription` typo) | tidy | fixed |
| 19 | (planned, § Legacy code) | empty Base.lproj/Main.storyboard | deleted if nothing references it | fixed |
| 20 | (device check) | export from an encrypted vault writes the encrypted bytes, not the decrypted file | exports are decrypted (journey 7) | fixed |
| 21 | (device check) | videos don't play correctly when scrolled onto in the viewer | the video page plays as the memo says (journey 5) | fixed |
| 22 | (device check) | Face ID usage text "Unlocking with FaceID" | "Unlock with Face ID" (human, 2026-10-26) | fixed |
| 23 | (device check) | encrypting the vault (No Lock → Password) with the screen auto-locking mid-way: many files fail, Retry fails, and the app is stuck on the migration screen at launch ("preparing to encrypt") | the migration pauses on lock and resumes after unlock; a stuck vault can always finish or get out (journey 8) | fixed |
| 24 | (device, fresh install) | setup's encrypted modes fail with "master key already exists" after a reinstall (the Keychain blob outlives the app); known issue planned for VaultLock, moved to the baseline because it blocks first-time setup | setup creates a new vault key when the vault is fresh | open |
| 25 | (device) | No Lock → Password + Face ID fails with "no encryption key is loaded" (No Lock → Password works) | adding Password + Face ID from No Lock works like Password, then enables Face ID | open |
Row 4 also covers "a non-limit error alerts under the open picker".

## Environment

- J8 testJourney8_PasswordToBiometricSwitchesImmediately: the simulator has no Face ID enrolled. Decision: the
  test skips itself (XCTSkip with the reason) when biometrics are unavailable; the device check covers Face ID.
- J9 purchase / pending / restore tests, legacy PaywallUITests, StoreKitConfigurationTests: every `SKTestSession`
  call fails with `SKInternalErrorDomain Code=3` under xcodebuild. Decision: investigate and fix the StoreKit test
  setup so they run under the gates. Cause: Apple bug on the iOS 26.x simulators (FB22237318; SKTestSession writes fail under
  xcodebuild). Fix: the gates run on iOS 18.6 (`SIMULATOR_NAME` in .pipeline/config.sh, 2026-10-25); all StoreKit tests
  pass there. iOS 26 is covered by the device check.

## Device check (2026-10-26)

Found by the human on a device: rows 20-22. The legacy UI tests (marked obsolete in the memo) are deleted now that the
journey tests replace them (human, 2026-10-26).
