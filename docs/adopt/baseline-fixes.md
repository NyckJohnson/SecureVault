# Baseline fixes

Journey tests (KoalaTVaultUITests/Journeys/) first run, 2026-10-24: 80 tests, 68 pass, 12 fail.
Decisions by the human, 2026-10-24.

## App bugs (app ≠ memo): all fixed in the baseline

| # | Journey test | Today | Memo | Status |
| --- | --- | --- | --- | --- |
| 1 | J3 testJourney3_FolderNameWithSlashShowsError | raw system error "The file “b” doesn’t exist." | alert "Names can't contain /" | open |
| 2 | J3 testJourney3_MoveIntoItsOwnFolderDoesNothing | renamed "alpha 1.txt" | nothing changes | open |
| 3 | J3 testJourney3_FolderCannotBeMovedIntoItself | silent failure (`try?`), picker offers the folder itself | alert "A folder can't be moved into itself" | open |
| 4 | J4 testJourney4_PhotoPickerCancelClosesPickerAndImportsNothing | Cancel leaves the picker open | closes, imports nothing | open |
| 5 | J5 testJourney5_UndecryptableFileShowsCantBeOpenedLabel | blank black page | "This file can't be opened." | open |
| 6 | J5 testJourney5_EditorLoadFailureShowsErrorAndIsReadOnly | editable after a failed load | read-only | open |
| 7 | J6 testJourney6_RestoreWithSameNameInFolderGetsNumberSuffix | error alert, item stays in trash (no lock) | restored as "alpha 1.rtf" | open |
| 8 | J9 testJourney9_PriceUnavailableShowsMessageAndUnlockStillPresent | empty price label | "Price unavailable" | open (verify after StoreKit) |

## Environment

- J8 testJourney8_PasswordToBiometricSwitchesImmediately: the simulator has no Face ID enrolled. Decision: the
  test skips itself (XCTSkip with the reason) when biometrics are unavailable; the device check covers Face ID.
- J9 purchase / pending / restore tests, legacy PaywallUITests, StoreKitConfigurationTests: every `SKTestSession`
  call fails with `SKInternalErrorDomain Code=3` under xcodebuild. Decision: investigate and fix the StoreKit test
  setup so they run under the gates.
