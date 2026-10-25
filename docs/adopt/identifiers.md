# Accessibility identifiers (adoption Stage 3)

Identifiers added to legacy screens so the journey tests can find their elements.
Names follow `<screen>.<element>`. Identifiers that already existed are kept unchanged and marked "(existing)".

## Setup wizard (`KoalaTVault/View/SetupWizard.swift`)

| element | identifier | journey |
| --- | --- | --- |
| Continue button | `continueButton` (existing) | 1 |
| Title "Welcome to Koala T Vault" | `setupWizard.titleLabel` | 1 |
| No Lock card | `setupWizard.noLockCard` | 1 |
| Password card | `setupWizard.passwordCard` | 1 |
| Password + biometric card | `setupWizard.biometricCard` | 1 |
| "Set Password" alert, password field | `setupWizard.passwordField` | 1 |
| "Set Password" alert, confirm field | `setupWizard.confirmPasswordField` | 1 |

## Lock screen (`KoalaTVault/View/LockScreen.swift`)

| element | identifier | journey |
| --- | --- | --- |
| Password field | `passwordField` (existing) | 2 |
| Unlock button | `unlockButton` (existing) | 2 |
| Title "KoalaTVault Locked" | `lockScreen.titleLabel` | 2 |
| "Use Face ID/Touch ID" button | `lockScreen.biometricButton` | 2 |
| Error label | `lockScreen.errorLabel` | 2 |

## Migration (`KoalaTVault/View/Migration.swift`)

| element | identifier | journey |
| --- | --- | --- |
| Title "Encrypting Files" / "Decrypting Files" | `migration.titleLabel` | 8 |
| Progress bar | `migration.progressBar` | 8 |
| Status label ("Preparing...", "N% complete", "Paused — unlock to continue", "Complete") | `migration.statusLabel` | 8 |

## File browser (`KoalaTVault/View/FileBrowser.swift`)

| element | identifier | journey |
| --- | --- | --- |
| Settings gear (root only, left) | `settingsButton` (existing) | 6, 8, 9 |
| New Folder bar button | `newFolderButton` (existing) | 3 |
| New Document bar button | `browser.newDocumentButton` | 3, 5 |
| Import bar button | `importButton` (existing) | 4 |
| Sort bar button | `sortButton` (existing) | 3 |
| Select bar button | `selectButton` (existing) | 3 |
| Collection view (grid) | `fileGrid` (existing) | 3, 4, 5, 6, 7 |
| Cell for an item | `browser.cell.<name>` (`<name>` = displayed name, extension included) | 3, 4, 5, 6, 7 |
| Cell name label | `browser.cell.<name>.nameLabel` | 3 |
| Cell size label | `browser.cell.<name>.sizeLabel` | 3 |
| Cell checkmark (only exists while selected in select mode) | `browser.cell.<name>.checkmark` | 3 |
| Empty-state label "No files yet" | `browser.emptyStateLabel` | 3 |
| "New Folder" alert, name field | `browser.newFolderNameField` | 3 |
| "New Document" alert, name field | `browser.newDocumentNameField` | 3, 5 |
| "Rename" alert, name field | `browser.renameField` | 3 |
| Context menu Export | `browser.contextMenu.export` | 7 |
| Context menu Move | `browser.contextMenu.move` | 3 |
| Context menu Copy | `browser.contextMenu.copy` | 3 |
| Context menu Rename | `browser.contextMenu.rename` | 3 |
| Context menu Delete | `browser.contextMenu.delete` | 6 |
| Select mode: Cancel (left) | `browser.cancelSelectButton` | 3 |
| Select mode: Delete | `browser.bulkDeleteButton` | 3, 6 |
| Select mode: Move | `browser.bulkMoveButton` | 3 |
| Select mode: Export | `browser.bulkExportButton` | 7 |
| Select mode: Copy | `browser.bulkCopyButton` | 3 |

Notes for the journey tests:
- **Bar-button overflow.** Non-select mode has five right bar buttons (New Folder, New Document, Import, Sort, Select;
  New Folder is rightmost). On narrow simulators iOS collapses some of them into an overflow "More" button
  (`OverflowBarButtonItem`, label "More"). On iPhone 17 Pro (iOS 26.5) exactly New Folder overflows: the bar shows
  `settingsButton`, `selectButton`, `sortButton`, `importButton`, `browser.newDocumentButton` and "More", and
  `newFolderButton` is absent. On narrower devices more of the image buttons (New Document, Import, Sort) can follow. The identifiers are set on the `UIBarButtonItem`s, but UIKit does not reliably
  carry them into the overflow menu, and these items are image-only (no title), so their overflow rows may have no useful
  label either. Tests should look for the identifier first and, if it is missing, tap "More" and pick the row there.
  Select mode's four right buttons can overflow the same way.
- **Context menu actions** carry their identifier as the `UIAction.Identifier`, which XCUITest reports as the menu
  button's identifier. If a given iOS version does not, the titles are "Export", "Move", "Copy", "Rename", "Delete".
- **Alert and action-sheet buttons** (`UIAlertAction`: New Folder/Rename "Create"/"Rename"/"Cancel", the delete
  confirmations, the Sort sheet's "Name"/"Type"/"Date Modified" with an optional " ↑"/" ↓") cannot take an identifier
  through public UIKit API; find them by label in `app.alerts` / `app.sheets`.
- The navigation title ("<folder name>", "Select Items", "N Selected") is the nav bar's identifier/label:
  `app.navigationBars["N Selected"]`.

## Progress overlay (`KoalaTVault/View/ProgressOverlay.swift`)

Shared HUD shown over the browser (import, export), settings, setup wizard and migration callers.

| element | identifier | journey |
| --- | --- | --- |
| Overlay (dimmed full-screen view) | `progressOverlay` | 1, 4, 7, 8 |
| Title ("Importing...", "Exporting...", "Setting password…", …) | `progressOverlay.titleLabel` | 1, 4, 7, 8 |
| Progress bar | `progressOverlay.progressBar` | 4, 7 |
| Status label ("Preparing...", …) | `progressOverlay.statusLabel` | 4, 7 |
| Cancel button (hidden unless cancellable) | `progressOverlay.cancelButton` | 4, 7 |

## Folder picker (`KoalaTVault/View/FolderPicker.swift`)

| element | identifier | journey |
| --- | --- | --- |
| Cancel (left) | `folderPicker.cancelButton` | 3 |
| Move Here (right) | `folderPicker.moveHereButton` | 3 |
| Folder table | `folderPicker.folderList` | 3 |
| Folder row | `folderPicker.row.<name>` | 3 |

Each nested folder pushes a new picker with the same identifiers; query the topmost (`.firstMatch` after the push settles).

## Privacy cover (`KoalaTVault/Model/AuthService.swift`, `showPrivacyScreen`)

| element | identifier | journey |
| --- | --- | --- |
| Privacy cover (full-window view with lock icon, shown while inactive) | `privacyCover` | 2 |

## File viewer (`KoalaTVault/View/FileViewer.swift`)

| element | identifier | journey |
| --- | --- | --- |
| Viewer root view (full-screen, black) | `viewer` | 5, 7 |
| Paging container (`UIPageViewController` view; swipe here) | `viewer.pager` | 5 |
| Top bar (X, title, share; tap the pager toggles its alpha) | `viewer.topBar` | 5 |
| Close (X) button | `viewer.closeButton` | 5 |
| Title label (current item's name) | `viewer.titleLabel` | 5 |
| Share button | `viewer.shareButton` | 7 |
| Video controls bar (hidden unless the current item is a video) | `viewer.videoControls` | 5 |
| Play/pause button | `viewer.playPauseButton` | 5 |
| Skip back 10 s button | `viewer.skipBackButton` | 5 |
| Skip forward 10 s button | `viewer.skipForwardButton` | 5 |
| Scrubber (slider) | `viewer.scrubber` | 5 |
| Current time label ("0:00") | `viewer.currentTimeLabel` | 5 |
| Total time label | `viewer.totalTimeLabel` | 5 |
| Buffer indicator track | `viewer.bufferIndicator` | 5 |
| Buffering spinner (only while stalled) | `viewer.bufferingSpinner` | 5 |

## File page (`KoalaTVault/View/FilePage.swift`)

`<name>` = the item's displayed name, extension included (same as `browser.cell.<name>`).

| element | identifier | journey |
| --- | --- | --- |
| Page root view (image, QuickLook and rtf pages; also the black page left on failure) | `filePage.<name>` | 5 |
| Image page: zoom scroll view (pinch / double-tap here) | `filePage.<name>.scrollView` | 5 |
| Image page: image view | `filePage.<name>.imageView` | 5 |
| Video page: page root view hosting the `AVPlayerLayer` (replaces `filePage.<name>` once the player is installed) | `filePage.<name>.videoPlayer` | 5 |
| QuickLook page: embedded `QLPreviewController` view | `filePage.<name>.quickLook` | 5 |

Notes for the journey tests:
- **Neighbour pages.** `UIPageViewController` may keep the previous/next pages loaded, so several `filePage.*`
  elements can exist at once. Query by the name you expect (`viewer.titleLabel` tells you the current item).
- **Video pages** have no player view (the video is a layer), so the page root carries `filePage.<name>.videoPlayer`
  instead of `filePage.<name>`. Match any page with `identifier BEGINSWITH "filePage.<name>"`.
- **Failure label not in the app yet.** The memo's "This file can't be opened." does not exist today: a decrypt failure
  leaves a blank black page (`filePage.<name>` with no `.imageView` image / no `.videoPlayer`). There is no
  page-position label and no loading indicator other than `viewer.bufferingSpinner`.
- **rtf pages** present the text editor from the page; after Done, the page is black (`filePage.<name>`, no content).
- The viewer has no Edit or Delete buttons.

## Text editor (`KoalaTVault/View/TextEditor.swift`)

| element | identifier | journey |
| --- | --- | --- |
| Editor root view | `textEditor` | 3, 5 |
| Text view | `textEditor.textView` | 3, 5 |
| Done (right bar button) | `textEditor.doneButton` | 3, 5 |
| Formatting toolbar (keyboard accessory; only while the keyboard is up) | `textEditor.formattingToolbar` | 5 |
| Bold | `textEditor.boldButton` | 5 |
| Italic | `textEditor.italicButton` | 5 |
| Underline | `textEditor.underlineButton` | 5 |
| Decrease font size | `textEditor.decreaseFontSizeButton` | 5 |
| Increase font size | `textEditor.increaseFontSizeButton` | 5 |
| Align left | `textEditor.alignLeftButton` | 5 |
| Align centre | `textEditor.alignCenterButton` | 5 |
| Align right | `textEditor.alignRightButton` | 5 |

Notes for the journey tests:
- There is no Cancel button; Done saves and dismisses. The navigation title is the item's name:
  `app.navigationBars["<name>"]`.
- A load failure shows an alert (find its OK button by label); the memo's read-only mode does not exist yet.
