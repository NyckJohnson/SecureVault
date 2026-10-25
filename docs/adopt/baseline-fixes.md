# Baseline fixes

Journey tests (KoalaTVaultUITests/Journeys/) first run, 2026-10-24: 80 tests, 68 pass, 12 fail.
Decisions by the human, 2026-10-24.

## App bugs (app ≠ memo): all fixed in the baseline

| # | Journey test | Today | Memo | Status |
| --- | --- | --- | --- | --- |
| 1 | J3 testJourney3_FolderNameWithSlashShowsError | raw system error "The file “b” doesn’t exist." | alert "Names can't contain /" | fixed |
| 2 | J3 testJourney3_MoveIntoItsOwnFolderDoesNothing | renamed "alpha 1.txt" | nothing changes | open |
| 3 | J3 testJourney3_FolderCannotBeMovedIntoItself | silent failure (`try?`), picker offers the folder itself | alert "A folder can't be moved into itself" | open |
| 4 | J4 testJourney4_PhotoPickerCancelClosesPickerAndImportsNothing | Cancel leaves the picker open | closes, imports nothing | open |
| 5 | J5 testJourney5_UndecryptableFileShowsCantBeOpenedLabel | blank black page | "This file can't be opened." | open |
| 6 | J5 testJourney5_EditorLoadFailureShowsErrorAndIsReadOnly | editable after a failed load | read-only | open |
| 7 | J6 testJourney6_RestoreWithSameNameInFolderGetsNumberSuffix | error alert, item stays in trash (no lock) | restored as "alpha 1.rtf" | open |
| 8 | J9 testJourney9_PriceUnavailableShowsMessageAndUnlockStillPresent | empty price label | "Price unavailable" | open (confirmed on iOS 18.6) |
| 9 | J9 testJourney9_PendingPurchaseShowsApprovalAlertAndKeepsPaywall | alert "Purchase is pending approval." (EntitlementService.swift:16) | "Purchase pending approval." (the app changes to match the memo) | open |
| 10 | J4 testJourney4_ChooseFolderOpensDocumentPickerAndCancelImportsNothing | iOS 18 only: SIGABRT after Cancel in the folder picker (`DOCWeakProxy`; picker delegate released early, ImportService.swift:62) | Cancel imports nothing | open |

## Environment

- J8 testJourney8_PasswordToBiometricSwitchesImmediately: the simulator has no Face ID enrolled. Decision: the
  test skips itself (XCTSkip with the reason) when biometrics are unavailable; the device check covers Face ID.
- J9 purchase / pending / restore tests, legacy PaywallUITests, StoreKitConfigurationTests: every `SKTestSession`
  call fails with `SKInternalErrorDomain Code=3` under xcodebuild. Decision: investigate and fix the StoreKit test
  setup so they run under the gates. Cause: Apple bug on the iOS 26.x simulators (FB22237318; SKTestSession writes fail under
  xcodebuild). Fix: the gates run on iOS 18.6 (`SIMULATOR_NAME` in .pipeline/config.sh, 2026-10-25); all StoreKit tests
  pass there. iOS 26 is covered by the device check.
