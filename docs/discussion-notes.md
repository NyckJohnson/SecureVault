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

- Minimum iOS 16.6.
- UI technology: UIKit (23 files import UIKit, 2 storyboards/xibs). _(decision on adopted screens: to discuss)_

## Existing documentation

- `API-Memo.md` (repo root): the public-facing members of each file, a cross-file dependency
  section, and a list of **open observations** (#1-#20, last updated 2026-10-03; some marked
  resolved). The survey checks each open observation against today's code; confirmed ones go to the
  memo's `## Known issues`.
- `REVIEW.md` (repo root): one open item, S2 (no minimum password strength); queued as a feature.

## Fragile areas and known bugs

- **Decryption has always had problems** (the human). _(symptoms: to discuss)_
- Recent commit fixed `wipeOrphanedEntries` wiping all entries: the orphan clean-up is fragile.
- See `API-Memo.md` open observations (trash lookup by name, paywall after picker dismissal,
  privacy screen stuck over lock screen, cold-launch biometric attempt, `changePassword` ordering,
  `.noMasterKeyBlob` dead end, and others). _(more from the human: to discuss)_

## Planned features (queued for after the adoption)

- Minimum password strength (REVIEW.md S2). Queued.

## Out of scope

_(to discuss)_
