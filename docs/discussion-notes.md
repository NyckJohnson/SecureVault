# KoalaTVault: discussion notes (adoption)

Adoption of an existing app. Stack: iOS (detected; see `docs/adopt/detection.md`).
The project is `KoalaTVault.xcodeproj`; "SecureVault" (the folder name) is an old name for the app.

## Purpose and users

An encrypted file store: the user keeps files in a private vault, with built-in image and video
viewing and a basic text editor. _(users / App Store status: to confirm)_

## Core journeys as they work today

_(to discuss)_

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

- Recent commit fixed `wipeOrphanedEntries` wiping all entries: the orphan clean-up is fragile.
- See `API-Memo.md` open observations (trash lookup by name, paywall after picker dismissal,
  privacy screen stuck over lock screen, cold-launch biometric attempt, `changePassword` ordering,
  `.noMasterKeyBlob` dead end, and others). _(more from the human: to discuss)_

## Planned features (queued for after the adoption)

- Minimum password strength (REVIEW.md S2). Queued.

## Out of scope

_(to discuss)_
