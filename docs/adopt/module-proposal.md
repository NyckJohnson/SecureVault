# Proposed module boundaries (for agreement before the memo)

From the survey reports in this folder. Build order is foundational first. "Legacy files" are the files each module
takes over (split files say which part). Paths are relative to `KoalaTVault/`.

## Modules

| # | Module | Purpose | Legacy files | Legacy tests | Depends on |
|---|---|---|---|---|---|
| 1 | **VaultCrypto** | Master key in memory, password wrap/unwrap (PBKDF2 600k, blob v1), Keychain store for the blob and the biometric key item, SVC5 file format (encrypt/decrypt file, chunk, stream info), small-data encrypt for maps | `Model/CryptoService.swift`; `Model/AuthService.swift` (part: biometric Keychain item store/read/delete) | `CryptoServiceTests.swift` | none |
| 2 | **Preferences** | Typed settings in UserDefaults: setup done, lock mode, sort, pending-migration record. Owns `LockMode`, `SortOption`, `SortDirection`, `MigrationKind` (moved out of the Migration view controller) | `Model/PreferencesService.swift` | `PreferencesServiceTests.swift` | none |
| 3 | **Entitlements** | StoreKit 2 "Unlock Pro": product, purchase, restore, transaction listener, cached unlocked state, free limit 100 | `Model/EntitlementService.swift` | `StoreKitConfigurationTests.swift` | none |
| 4 | **VaultStore** | The vault on disk: types (`VaultItem`, `VaultDirectory`, `FileKind`), per-folder index (`.vault_map`), browse/sort, open/write, create folder, move/copy/rename, trash (`.trash_map`, restore, purge), per-file migration steps, orphan sweep, temp files. One module because all of these share the index read-modify-write and the "encrypted or not" rule | `Model/FileSystem.swift` (all but import and export parts); `Model/FileKind.swift` | `VaultTestCase`, `FileSystemTests`, `EncryptedFileSystemTests`, `FileSystemMappingIntegrityTests`, `TrashTests`, `SortTests`, `CopyTests`, `ConflictResolutionTests`, `VaultDirectoryTests`, `VaultItemTests`, `FileKindTests`, `EdgeCaseTests`, `AdditionalEdgeCaseTests` | VaultCrypto |
| 5 | **VaultLock** | The key lifecycle and lock state: create vault (password / biometric), unlock by password or biometrics, lock on background, change password, switch password ↔ biometric, observable lock state. No UI | `Model/AuthService.swift` (part: everything except the Keychain item code and the UI presentation) | `AuthServiceTests.swift` (part: AuthServiceTests, AuthServiceForegroundTests) | VaultCrypto, Preferences |
| 6 | **LockMigration** | Encrypt/decrypt the whole vault when the lock is added or removed: file list, per-file loop, pause when locked, resume, retry/skip, the persisted pending record, finalize (lock mode, remove password, wipe key) | `View/Migration.swift` (part: state machine); `Model/AuthService.swift` (part: `finalizeMigration`) | `MigrationTests.swift`; `AuthServiceTests.swift` (part: MigrationFinalizationTests) | VaultStore, VaultLock, Preferences |
| 7 | **Media** | Thumbnails (in-memory cache, QuickLook, video frame) and streaming decrypted video to AVPlayer | `Model/ThumbnailService.swift`; `Model/VaultResourceLoaderDelegate.swift` | `MediaPipelineTests.swift` (part: resource loader, thumbnails) | VaultStore, VaultCrypto |
| 8 | **Import** | Import from Files, folders and Photos: limit check, duplicate detection, camera-roll delete offer. Logic only; pickers move to the browser screen | `Model/ImportService.swift`; `Model/FileSystem.swift` (part: import) | `ImportServiceTests.swift`, `FileImportLimitTests.swift` | VaultStore, Entitlements |
| 9 | **Export** | Prepare decrypted copies for sharing and their clean-up; save to camera roll | `Model/ExportService.swift`; `Model/FileSystem.swift` (part: export) | `ExportServiceTests.swift` | VaultStore |
| 10 | **SharedUI** | UIKit pieces used by several screens: progress overlay, error/success alerts, presentation helpers, file icon mapping | `View/ProgressOverlay.swift`, `Model/ErrorPresenting.swift`, `View/UIViewController+Presentation.swift`, `View/FileIconProvider.swift` | none | VaultStore (FileKind) |
| 11 | **LockScreens** | Setup wizard, lock screen, privacy cover, and presenting the lock over the app (moved out of AuthService). `UI: UIKit` | `View/SetupWizard.swift`, `View/LockScreen.swift`; `Model/AuthService.swift` (part: privacy screen, lock-screen presentation, `didAuthenticate`) | none | VaultLock, SharedUI |
| 12 | **Browser** | File browser grid, file cell, folder picker; New Folder/Document, sort, select mode and bulk actions, context menu, drag-drop; starts import and export (pickers and share sheets move here from the services). `UI: UIKit` | `View/FileBrowser.swift`, `View/FileCell.swift`, `View/FolderPicker.swift` | none | VaultStore, Media, Import, Export, Preferences, SharedUI |
| 13 | **Viewer** | File viewer (pager, video controls), file page, text editor. `UI: UIKit` | `View/FileViewer.swift`, `View/FilePage.swift`, `View/TextEditor.swift` | `MediaPipelineTests.swift` (part: FileViewerViewController) | VaultStore, Media, Export, SharedUI |
| 14 | **Settings** | Security settings, migration screen, paywall, Recently Deleted. `UI: UIKit` | `View/SecuritySettings.swift`, `View/PaywallViewController.swift`, `View/RecentlyDeleted.swift`, `View/Migration.swift` (part: the view) | `SecuritySettingsProTests.swift`, `SecuritySettingsViewControllerTests.swift` | VaultLock, LockMigration, VaultStore, Entitlements, SharedUI |

## App shell (never a module)

`AppDelegate.swift`, `SceneDelegate.swift`, new `AppDependencies.swift` (composition root: builds the services once and
hands them to screens instead of `.shared` singletons), `Info.plist`, `Assets.xcassets`, `Base.lproj/LaunchScreen.storyboard`.
`Base.lproj/Main.storyboard` is empty: proposed for deletion in the baseline (if Info.plist doesn't reference it).
The DEBUG `--uitesting` reset in AppDelegate becomes the stack's `-uiTesting` clean-state launch (in-memory/temp
storage instead of wiping the real Documents vault and Keychain).

## Old tests marked obsolete

- `KoalaTVaultTests.swift` (empty template test).
- UI tests in `KoalaTVaultUITests/` (`KoalaTVaultUITests`, `AdditionalUITests`, `PaywallUITests`, `LaunchTests`,
  `VaultUITestCase`): superseded by the baseline journey tests (stage 3), which keep their useful cases (paywall purchase
  and restore, migration failure Retry/Skip, browse flows). Template tests (`testExample`, `testLaunchPerformance`,
  `testLaunch`) dropped.

## Points for the human

1. Boundaries above, especially VaultStore as one module and LockMigration separate from VaultLock.
2. How to treat the bugs (see `## Known issues` draft in the memo): fix data-loss bugs in the baseline, harden the
   key-lifecycle failure paths through the VaultLock/LockMigration contracts, queue the rest.
3. The vault format in code is **SVC5**, not SVC4 as the notes say.
4. Folder names, sizes and folder structure are plaintext on disk even in an encrypted vault (today's behavior; keep as
   a stated decision?).
