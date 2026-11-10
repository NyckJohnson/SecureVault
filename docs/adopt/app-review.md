# Whole-app review (adoption stage 6, 2026-11-04)

Two read-only passes by the reviewer (no app run). Decisions on each item: see the decisions log.

## Pass 1: integration, app shell, launch (result: pass, all minor)
1. Memo: build order says LockScreens depends on "VaultLock, SharedUI"; its module entry (and code) also use VaultCrypto, Preferences.
2. Memo: Settings uses Preferences types (`LockMode`, `MigrationKind`) but doesn't list Preferences as a dependency.
3. Memo: "clears thumbnails ... after unlock" — the code clears them on entering the background with a lock (SceneDelegate.swift:94-101), which is safer.
4. App shell: `LegacyStorage` and its "legacy" comments are stale (AppDependencies.swift:103-125, 303, 347); `LegacyStorage.current` is a process-wide static.
5. App shell: the `-uiTesting` / `-unitTestHost` paths (seeds, SlowMigrationVaultStore, in-memory Keychain, InertProUnlock) ship in Release, guarded only by launch arguments (AppDependencies.swift:166-169, 217, 347-355, 445-477); the old app had them DEBUG-only.
6. App shell: `removeAllTemporaryFiles()` runs synchronously on the main thread at launch (SceneDelegate.swift:74), delaying the first frame after a crash that left large temp files.
7. VaultStore: `sweepOrphans` is one synchronous pass inside the store actor (OrphanSweep.swift:14-35); after an unlock with a large vault the grid's listing waits behind it.
8. Media: `ThumbnailProviding.clearCache(for:)` has no caller (MediaContract.swift:15) — contract change to remove.
9. Settings/shell: "no sweep while a migration is pending" relies on main-actor ordering between `prepareToAddLock` and `migrator.start` (SecuritySettingsViewModel.swift:260-282) — correct today; optional hardening.
10. Info: the shell's lifecycle wiring is covered by the journeys only (matches the memo).

## Pass 2: screens (result: fail)
Bugs when screens combine:
- B1 SharedUI/Import/Export: the progress overlay is added to the browser's view, under the navigation bar, so during import/export the bar buttons (Settings, Select, Import, bulk Delete…) stay tappable; not modal for VoiceOver (ProgressOverlayView.swift:30-38, ImportPresenter.swift:386, ExportPresenter.swift:317).
- B2 SharedUI: `topmostPresentedController` doesn't skip a controller being dismissed; an error alert right after a sheet closes can be dropped (UIViewController+Topmost.swift:6-11).
- B3 Export: the export overlay never updates; it shows "Preparing..." with an empty bar throughout (ExportPresenter.swift:315-318).
- B4 Settings: Settings is a form sheet with no Done/Close button; on iPad (the target includes iPad) it may be hard to dismiss (LiveSettingsFactory.swift:36-41).
- B5 Browser: the folder picker shows no title, so "Move Here" applies to a folder the user can't see named (FolderPickerViewController.swift:61-76).
VoiceOver (accessibility):
- A1 Browser bar buttons (Settings, Sort, New Folder, New Document, Import, Delete, Move, Export, Copy) have no labels (FileBrowserViewController.swift:36-68,177-180).
- A2 Viewer video controls (close, export, skip, play/pause, scrubber) have no labels; play/pause state not spoken (FileViewerViewController.swift:344-438).
- A3 Setup wizard option cards have no labels and no selected state: first launch can't be completed with VoiceOver (SetupWizardViewController.swift:73-103).
- A4 Grid cells not one element; kind and selection not spoken (FileCell.swift).
- A5 No announcements anywhere (lock-screen errors, progress, migration status).
- A6 Settings rows: traits replaced, current mode not "selected" (SecuritySettingsViewController.swift:288).
- A7 Viewer bars auto-hide under VoiceOver; image pages have no label; text editor toolbar unlabeled.
- A8 Privacy cover not modal for VoiceOver; sort direction read as "arrow".
Dynamic Type:
- D1 Only 3 labels follow live text-size changes (`adjustsFontForContentSizeCategory`).
- D2 Layouts clip at large sizes: grid cells (fixed height), paywall, setup wizard (fixed 80 pt cards), lock-screen error, migration labels, settings rows (1 line), viewer bars and time labels.
Dark mode / assets:
- K1 Select checkmark sits on a hard white disc in dark mode (FileCell.swift:47).
- K2 Assets: unused `Color` and empty `Image` sets; `AccentColor` points at a png instead of a colour, so it's ignored (app shell).
Fine: semantic colours on lock screen, overlay, sheets; destructive/cancel styles; action names consistent; one size formatter; lock screen presents over sheets.
