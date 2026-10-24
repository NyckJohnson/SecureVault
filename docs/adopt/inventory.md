Sources: 28 files, 6128 lines (outside Modules/)
  KoalaTVault/AppDelegate.swift (75 lines, UIKit)
      declares: AppDelegate (used by 0)
      uses: AuthService, EntitlementService
  KoalaTVault/Model/AuthService.swift (341 lines, UIKit)
      declares: AuthError (used by 3), AuthService (used by 11)
      uses: FileBrowserViewController, LockScreenViewController, MigrationViewController
  KoalaTVault/Model/CryptoService.swift (485 lines)
  KoalaTVault/Model/EntitlementService.swift (141 lines, Combine, UIKit)
      declares: EntitlementError (used by 0), EntitlementService (used by 8)
  KoalaTVault/Model/ErrorPresenting.swift (32 lines, UIKit)
      declares: ErrorPresenting (used by 8)
      extends: ErrorPresenting
  KoalaTVault/Model/ExportService.swift (138 lines, UIKit)
      declares: ExportCleanupDelegate (used by 0), ExportService (used by 2)
      uses: ProgressOverlay
  KoalaTVault/Model/FileKind.swift (28 lines)
  KoalaTVault/Model/FileSystem.swift (928 lines)
      declares: VaultMapping (used by 1), FileSystemError (used by 3)
      extends: Notification
      uses: EntitlementService
  KoalaTVault/Model/ImportService.swift (192 lines, UIKit)
      declares: ImportService (used by 2), CameraRollDeleting (used by 1), PhotoLibraryCameraRollDeleter (used by 0)
      extends: ImportService
      uses: ErrorPresenting, FileSystemError, PaywallViewController, ProgressOverlay
  KoalaTVault/Model/PreferencesService.swift (81 lines)
      uses: MigrationViewController
  KoalaTVault/Model/ThumbnailService.swift (300 lines, UIKit)
  KoalaTVault/Model/VaultResourceLoaderDelegate.swift (83 lines)
  KoalaTVault/SceneDelegate.swift (88 lines, UIKit)
      declares: SceneDelegate (used by 0)
      uses: AuthService, FileBrowserViewController, MigrationViewController, SetupWizardViewController
  KoalaTVault/View/FileBrowser.swift (550 lines, UIKit)
      declares: FileBrowserViewController (used by 2)
      extends: FileBrowserViewController
      uses: AuthService, ErrorPresenting, ExportService, FileCell, FileViewerViewController, FolderPickerDelegate, FolderPickerViewController, ImportService, SecuritySettingsViewController, TextEditorViewController
  KoalaTVault/View/FileCell.swift (127 lines, UIKit)
      declares: FileCell (used by 1)
  KoalaTVault/View/FileIconProvider.swift (59 lines, UIKit)
  KoalaTVault/View/FilePage.swift (184 lines, UIKit)
      declares: FilePageViewController (used by 1)
      extends: FilePageViewController
      uses: FileViewerViewController, TextEditorViewController
  KoalaTVault/View/FileViewer.swift (486 lines, UIKit)
      declares: FileViewerViewController (used by 3)
      extends: FileViewerViewController
      uses: ExportService, FilePageViewController
  KoalaTVault/View/FolderPicker.swift (96 lines, UIKit)
      declares: FolderPickerDelegate (used by 1), FolderPickerViewController (used by 1)
      extends: FolderPickerViewController
  KoalaTVault/View/LockScreen.swift (218 lines, UIKit)
      declares: LockScreenViewController (used by 1)
      extends: LockScreenViewController
      uses: AuthError, AuthService
  KoalaTVault/View/Migration.swift (250 lines, UIKit)
      declares: MigrationViewController (used by 5)
      uses: AuthService, ErrorPresenting
  KoalaTVault/View/PaywallViewController.swift (146 lines, UIKit)
      declares: PaywallViewController (used by 3)
      uses: EntitlementService, ErrorPresenting
  KoalaTVault/View/ProgressOverlay.swift (115 lines, UIKit)
      declares: ProgressOverlay (used by 4)
  KoalaTVault/View/RecentlyDeleted.swift (134 lines, UIKit)
      declares: RecentlyDeletedViewController (used by 1)
      extends: RecentlyDeletedViewController
      uses: ErrorPresenting
  KoalaTVault/View/SecuritySettings.swift (330 lines, Combine, UIKit)
      declares: SecuritySettingsViewController (used by 3)
      extends: SecuritySettingsViewController
      uses: AuthError, AuthService, EntitlementService, ErrorPresenting, MigrationViewController, PaywallViewController, ProgressOverlay, RecentlyDeletedViewController
  KoalaTVault/View/SetupWizard.swift (245 lines, UIKit)
      declares: SetupWizardViewController (used by 1)
      uses: AuthService, ErrorPresenting, ProgressOverlay
  KoalaTVault/View/TextEditor.swift (252 lines, UIKit)
      declares: TextEditorViewController (used by 2)
      extends: TextEditorViewController
      uses: ErrorPresenting
  KoalaTVault/View/UIViewController+Presentation.swift (24 lines, UIKit)
      extends: UIViewController
Tests: 25 files
  KoalaTVaultTests/AdditionalEdgeCaseTests.swift (212 lines) uses: no app types
  KoalaTVaultTests/AuthServiceTests.swift (318 lines) uses: AuthError, AuthService
  KoalaTVaultTests/ConflictResolutionTests.swift (136 lines) uses: no app types
  KoalaTVaultTests/CopyTests.swift (152 lines) uses: no app types
  KoalaTVaultTests/CryptoServiceTests.swift (458 lines) uses: no app types
  KoalaTVaultTests/EdgeCaseTests.swift (228 lines) uses: no app types
  KoalaTVaultTests/EncryptedFileSystemTests.swift (172 lines) uses: no app types
  KoalaTVaultTests/ExportServiceTests.swift (103 lines) uses: no app types
  KoalaTVaultTests/FileImportLimitTests.swift (108 lines) uses: EntitlementService, FileSystemError
  KoalaTVaultTests/FileKindTests.swift (68 lines) uses: no app types
  KoalaTVaultTests/FileSystemMappingIntegrityTests.swift (487 lines) uses: FileSystemError, VaultMapping
  KoalaTVaultTests/FileSystemTests.swift (136 lines) uses: no app types
  KoalaTVaultTests/ImportServiceTests.swift (53 lines) uses: CameraRollDeleting, ImportService
  KoalaTVaultTests/KoalaTVaultTests.swift (18 lines) uses: no app types
  KoalaTVaultTests/MediaPipelineTests.swift (424 lines) uses: FileViewerViewController
  KoalaTVaultTests/MigrationTests.swift (125 lines) uses: AuthService, MigrationViewController
  KoalaTVaultTests/PreferencesServiceTests.swift (84 lines) uses: no app types
  KoalaTVaultTests/SecuritySettingsProTests.swift (77 lines) uses: AuthService, EntitlementService, PaywallViewController, SecuritySettingsViewController
  KoalaTVaultTests/SecuritySettingsViewControllerTests.swift (45 lines) uses: AuthService, EntitlementService, SecuritySettingsViewController
  KoalaTVaultTests/SortTests.swift (176 lines) uses: no app types
  KoalaTVaultTests/StoreKitConfigurationTests.swift (78 lines) uses: EntitlementService
  KoalaTVaultTests/TrashTests.swift (223 lines) uses: no app types
  KoalaTVaultTests/VaultDirectoryTests.swift (41 lines) uses: no app types
  KoalaTVaultTests/VaultItemTests.swift (102 lines) uses: no app types
  KoalaTVaultTests/VaultTestCase.swift (33 lines) uses: no app types
Interface Builder: KoalaTVault/Base.lproj/LaunchScreen.storyboard, KoalaTVault/Base.lproj/Main.storyboard
