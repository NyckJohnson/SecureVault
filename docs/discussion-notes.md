# KoalaTVault: discussion notes (adoption)

Adoption of an existing app. Stack: iOS (detected; see `docs/adopt/detection.md`).
The project is `KoalaTVault.xcodeproj`; "SecureVault" (the folder name) is an old name for the app.

## Purpose and users

An encrypted file store: the user keeps files in a private vault, with built-in image and video
viewing and a basic text editor. Accepted by App Store Connect (version 1.2, build 4) but **not yet
released**: there are no real users' vaults to protect yet, but the on-disk vault format (SVC4) and
Keychain layout should still be kept as they are.

## Core journeys as they work today

Confirmed by the human (details and failure paths are checked against the code by the survey):

1. **First launch / setup wizard**: pick a lock mode: none, password, or password + Face ID/Touch ID.
   With a password, files are encrypted.
2. **Unlock**: lock screen asks for the password or biometrics. A wrong password shows an error;
   **no lockout and no wipe** after repeated failures.
3. **Browse**: folders and files with thumbnails, sorting; folder picker for move/copy.
4. **Import** from Photos and Files. Free tier: 100 files; going past it shows the paywall.
5. **View / edit**: image and video viewer (paging), basic text editor for text files.
6. **Delete / restore**: deleted items go to Recently Deleted and are **purged automatically after
   30 days** (`FileSystem.swift`).
7. **Export / share** files out of the vault.
8. **Change lock mode** in Security Settings: a migration encrypts or decrypts every file, with
   progress, pause/resume and a short background continuation.
9. **Paywall**: one-time "Unlock Pro" purchase (StoreKit 2, `nej.KoalaTVault.unlockpro`) lifts the
   100-file limit; Restore Purchases.

## Constraints

- Minimum iOS 16.6. iPhone and iPad, all orientations.
- **Fully offline**: no accounts, no server, no sync. The only network use is StoreKit. iCloud backup
  is a planned feature. (Device backups may already include the vault files and the wrapped key blob,
  per `API-Memo.md` observation #16; the survey checks this.)
- UI technology: UIKit (23 files import UIKit, 2 storyboards/xibs). **Decision: every adopted screen
  stays `UI: UIKit`**, its logic in a tested view model and its view controller a thin view. Moving a
  screen to SwiftUI (fine on iOS 16, with `ObservableObject` rather than `@Observable`) is later
  `/feature` work. Why: the adoption keeps behavior; changing UI technology at the same time doubles
  the risk.

## Existing documentation

- `API-Memo.md` (repo root): the public-facing members of each file, a cross-file dependency
  section, and a list of **open observations** (#1-#20, last updated 2026-10-03; some marked
  resolved). The survey checks each open observation against today's code; confirmed ones go to the
  memo's `## Known issues`.
- `REVIEW.md` (repo root): one open item, S2 (no minimum password strength); queued as a feature.

## Fragile areas and known bugs

- **Key handling around encryption/decryption is the most fragile area** (the human): a history of
  the master key being lost, replaced, or not used correctly. The human's goal for the adoption is
  that the pipeline's checks make this robust. So the memo must spec the key lifecycle precisely
  (create, unlock, wrap/rewrap on password change, biometric copy, wipe, migration encrypt/decrypt,
  lock on background) and the contract, unit and journey tests must cover each transition and its
  failure paths, including: a failure part-way never loses the key or leaves files under a key that
  is no longer stored.
- Recent commit fixed `wipeOrphanedEntries` wiping all entries: the orphan clean-up is fragile.
- See `API-Memo.md` open observations (trash lookup by name, paywall after picker dismissal,
  privacy screen stuck over lock screen, cold-launch biometric attempt, `changePassword` ordering,
  `.noMasterKeyBlob` dead end, and others).

## Planned features (queued for after the adoption)

- Minimum password strength (REVIEW.md S2). Queued.
- iCloud backup. Queued.
- Password recovery. Queued.
- Multiple vaults / duress password. Queued.
- Timed lockout for failed passwords. Queued.

## Out of scope (for the adoption)

- New features (the four above come after it, through `/feature`).
- Moving screens to SwiftUI.
- Changing the on-disk vault format (SVC4) or the Keychain layout, except where a bug fix needs it
  (agreed by the human).
- Repo-root folders `art samples/`, `previews/`, `vault_test_files/`: not app code and not used by
  tests (`vault_test_files/` was for manual testing). They stay where they are; no module owns them.
- `API-Memo.md` and `REVIEW.md` stay as references (agreed); the pipeline memo (`docs/outline.md`) and
  `docs/api/` replace them for new work.
