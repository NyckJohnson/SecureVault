# Survey: screens (browse side)

STATUS: done
PASS: screens (browse side)

Files: `View/FileBrowser.swift`, `View/FileCell.swift`, `View/FileIconProvider.swift`, `View/FolderPicker.swift`,
`View/RecentlyDeleted.swift`, `View/ProgressOverlay.swift`, `View/UIViewController+Presentation.swift`,
`Model/ErrorPresenting.swift`, `Base.lproj/Main.storyboard`.

All screens are UI: UIKit, built in code. `Main.storyboard` is empty (`<scenes/>`, `Base.lproj/Main.storyboard:7`): no
storyboard scenes, segues or IB identifiers.

## Screen 1: FileBrowserViewController (`View/FileBrowser.swift`)

- **UI technology:** UIKit in code. `UICollectionView` with a compositional layout and a
  `UICollectionViewDiffableDataSource<Int, VaultItem>` (`:16`, `:147`).
- **Purpose:** the home screen and every folder view; root of the app's `UINavigationController`
  (SceneDelegate builds `FileBrowserViewController(directory: .root)`, per API-Memo).
- **Reached:** root of the nav stack; tapping a folder pushes a new instance (`:411-414`); `AuthService` calls
  `reloadAfterAuth()` after unlock (`:179`).
- **Shows:**
  - Grid of `FileCell`s. Columns = `max(2, Int((width-16)/100))`, item height = 1.4 × width, rebuilt on rotation (`:123-144`).
  - Title = `directory.name`.
  - Empty state: "No files yet" background label (`:338`).
  - Non-select nav bar, right (`rightBarButtonItems` order, first = rightmost): New Folder, New Document, Import, Sort, Select.
  - Settings gear on the left, root only (compares `diskURL` with `VaultDirectory.root.diskURL`, `:76`).
  - Select mode: left Cancel; right Delete, Move, Export, Copy; title "Select Items" or "N Selected".
- **Accessibility identifiers (non-select mode):** `settingsButton`, `sortButton`, `newFolderButton`, `importButton`,
  `selectButton` (`:99-103`), `fileGrid` (`:120`). None on New Document, select-mode buttons, cells, empty label.
- **Actions and outcomes:**
  - Tap folder (not select mode): push a new browser.
  - Tap a file with extension `rtf`: present `TextEditorViewController` in a full-screen nav.
  - Tap any other file: present `FileViewerViewController(items: non-directory siblings, startingAt: index)` (`:423-426`).
  - Settings: present `SecuritySettingsViewController` in a form-sheet nav.
  - New Folder: alert with text field → `FileSystem.createFolder(named:in:)` → reload; errors shown; empty name ignored.
  - New Document (`:213-242`): appends `.rtf` if missing; `FileManager.default.createFile(atPath:contents:nil)` directly
    in `directory.diskURL` (no `FileSystem` call); builds `VaultItem(isEncrypted: false, fileSize: 0, …)`; presents the
    editor full-screen, reloads in the completion; empty name ignored.
  - Import: `ImportService.shared.promptImport(into:from:barButtonItem:completion)` → reload. Paywall handled in `ImportService`.
  - Sort: action sheet of `SortOption.allCases` with `PreferencesService.shared.sortOption`/`sortDirection`; current option
    shows ↑/↓; tapping current flips direction, another sets it ascending; reload. Sort is global, not per folder.
  - Select: toggles `isSelectMode`, clears selection; tapping a cell toggles it in `selectedItems`; title updates; checkmark;
    unselected cells alpha 0.6.
  - Bulk Delete (`:260-273`): confirm "Delete N items?" → `FileSystem.delete(item)` (= `moveToTrash`) each with `try?`;
    errors swallowed; exit select mode; reload.
  - Bulk Move: stores `itemsPendingBulkAction`, opens folder picker; on `didSelectFolder` → `FileSystem.move` each with
    `try?`, clears pending, exits select mode, reloads.
  - Bulk Export: `ExportService.exportMultiple(...)`; select mode stays on.
  - Bulk Copy: `FileSystem.copy(item, to: directory)` each with `try?` into the same folder; exit select mode; reload.
  - Context menu (long press, also in select mode):
    - Export: `ExportService.export(item, from:, sourceView: cell)`.
    - Move: sets `itemPendingMove` + `pendingAction`; picker opens after menu dismissal (`willEndContextMenuInteraction`,
      `:467-480`).
    - Copy: into current folder, errors shown.
    - Rename: prefilled alert → `FileSystem.rename`; errors shown; empty ignored.
    - Delete: confirm (folder message says "the folder and all its contents"; nothing mentions Trash) → `FileSystem.delete`.
  - Drag: every cell; provider `NSURL(diskURL)`, `localObject` = `VaultItem` (`:501-513`).
  - Drop: only onto a folder cell moves (`FileSystem.move`, errors shown). Onto a file cell proposed `.move` but
    `performDrop` does nothing. Drops from other apps skipped.
  - `.fileRestored` notification → reload (`:40`, `:298`).
- **Failure paths:** `loadContents` errors shown only if `AuthService.shared.hasAuthenticated`, else dropped and `items`
  keeps old value (`:165-167`). Single Move and bulk Move/Delete/Copy swallow errors. `fatalError` on unregistered reuse
  ID (`:150`) and `init(coder:)`.
- **Services:** `FileSystem.shared` (contents, createFolder, delete, copy, move, rename, `diagnoseDiskState` in DEBUG),
  `AuthService.shared.hasAuthenticated`, `PreferencesService.shared`, `ImportService.shared`, `ExportService.shared`,
  `NotificationCenter.default`, `FileManager.default` (New Document, temp-dir scan).
- **Logic a view model should own:** loading/sorting, select-mode state, pending move state (`itemPendingMove`,
  `itemsPendingBulkAction`, `pendingAction`), new-document creation, extension routing, sort toggle, bulk loops, drop
  handling, root vs subfolder.
- `viewDidAppear` (`:43-55`) scans the temp directory in release builds too; result printed only under DEBUG.

## FileCell (`View/FileCell.swift`, component)

- Icon (80pt), name (2 lines), size label, top-right checkmark (hidden by default). Folders: empty size; files:
  `ByteCountFormatter` `.file`; nil size → "".
- Icon from `FileIconProvider` (files 50pt symbol; folders image as is). Requests a 40×40 thumbnail from
  `ThumbnailService.shared.thumbnail(for:size:)`; replaces icon with `.scaleAspectFit`.
- `setSelected`: checkmark only in select mode and selected; alpha 0.6 in select mode and not selected.
- `prepareForReuse`: nils `thumbnailRequest` (no cancel), clears image, resets content mode.
- No identifiers. Dead code (`:54`, `:73-85`, `:104-107`); `gridMode` unused. Calls `ThumbnailService` directly.

## FileIconProvider (`View/FileIconProvider.swift`)

- `nonisolated enum`, stateless: `FileKind(extension:)` → SF Symbol + tint.
- Folders use asset `nej_FolderIconB` if bundled (tint `.clear`), else `folder.fill` (`.systemYellow`).
- `hasCustomFolderAsset` (`:13`) cached, but `iconColor` re-checks the asset on every call (`:43`).

## Screen 3: FolderPickerViewController + FolderPickerDelegate (`View/FolderPicker.swift`)

- UIKit, `UITableView` plain. Reached from `FileBrowserViewController.presentFolderPicker` (`:302-308`); always starts at
  `VaultDirectory.root`; form-sheet nav. `item` parameter unused.
- Shows only subfolders of `currentDirectory` (yellow `folder.fill`, disclosure). No title, no empty state, no identifiers.
  Left "Cancel", right "Move Here".
- Tap row: push a picker for that folder (delegate passed on; `rootDirectory` unused). Move Here:
  `delegate.folderPicker(_:didSelectFolder: currentDirectory)` then dismiss. Cancel: dismiss only (does NOT clear the
  browser's pending-move state).
- `contents(of:)` errors swallowed → empty list. Calls `FileSystem.shared` directly.
- No exclusion of the moved folder, its descendants or the current folder.
- The delegate (`FileBrowser.swift:485-497`) does the move with `try?`, then reloads.

## Screen 4: RecentlyDeletedViewController (`View/RecentlyDeleted.swift`)

- UIKit, `UITableView` `.insetGrouped`, title "Recently Deleted". Pushed from `SecuritySettingsViewController`
  (`SecuritySettings.swift:177-179`, `.trash` row); not reachable from the browser.
- Rows from `FileSystem.contentsOfTrash(for: .root)` (flat, no location): name, icon/colour, "Deletes in N day(s)".
  N = `30 - Int(now - (deletedAt ?? dateModified)) / 86400`, clamped ≥ 0 for display; plural test uses unclamped value.
- Empty label "No recently deleted files". Red "Empty Trash" button, disabled when empty. No identifiers.
- Row tap → action sheet Restore / Delete Permanently / Cancel (iPad popover from cell).
  - Restore: `FileSystem.restoreFromTrash(item)`, reload, post `.fileRestored`. Errors shown.
  - Delete Permanently: `permanentlyDelete(item)`, reload; errors shown; **no confirmation**.
- Empty Trash: confirm → `FileSystem.emptyTrash(for: .root)` → reload.
- Load error → `items = []` + alert.
- View-model logic: days-left, loading, restore/delete, empty/enabled state.
- 30 days hardcoded in UI (`:94`) and separately in `FileSystem.swift:609` (`-30 * 24 * 60 * 60`).

## Support: ProgressOverlay (`View/ProgressOverlay.swift`)

- UIKit `UIView` HUD. `show(in:title:cancellable:onCancel:)`: full-bounds dim view, 300pt container with title,
  `UIProgressView`, status "Preparing...", Cancel (hidden unless `cancellable`).
- `update(progress:status:)` and `dismiss()` hop to main via `DispatchQueue.main.async`; dismiss fades 0.2s.
- `cancelTapped` → `onCancel` then `dismiss`. Not modal: covers `viewController.view` only (not the nav bar).
- Used by Export, Import, SecuritySettings, SetupWizard (per API-Memo).

## Support: UIViewController+Presentation

- Stateless extension: `presentationChain` and `topmostPresented`. Used by SceneDelegate and AuthService.

## Support: ErrorPresenting (`Model/ErrorPresenting.swift`)

- Protocol with defaults: `showError(Error)` (localizedDescription), `showError(String)` (alert "Error", OK),
  `showSuccess(String)` (no title, OK). Presents from `self`; fails silently if something is already presented.

## Navigation (browse side)

Root nav: `FileBrowser(root)` → push `FileBrowser(subfolder)`. Modals: `SecuritySettings` (form sheet; pushes
`RecentlyDeleted`), `TextEditor` (full-screen nav), `FileViewer` (default modal), `FolderPicker` (form sheet; nested
pushes), import/export UI. Unlock → `reloadAfterAuth()`. `.fileRestored` reloads all live browsers.

## Journeys checked against the code

### Journey 3 (Browse)
- Agree: folders/files with thumbnails; sort sheet with toggleable direction persisted in `PreferencesService`; folder
  picker for move.
- Differ: Copy never uses the picker; it always copies into the current folder (`:290-292`, `:454-461`). The picker is
  only for Move. Notes omit select mode with bulk ops, rename, drag-and-drop onto a folder, New Folder, New Document.

### Journey 4 (Import, paywall)
- Browser side only: Import → `ImportService.promptImport` → reload. Limit and paywall in `ImportService`/`FileSystem`.
- New Document bypasses `FileSystem.importItems`/`checkImportAllowed`, so it bypasses the free-tier limit (guess).

### Journey 6 (Delete / restore)
- Agree: delete → `moveToTrash` (`FileSystem.swift:479-481`); Recently Deleted with days left, Restore, Delete
  Permanently, Empty Trash; purge at 30 days (`FileSystem.swift:609`).
- Differ: delete confirmations don't mention Recently Deleted; Recently Deleted only via Settings (root only); one flat
  trash for `.root`; single permanent delete unconfirmed; bulk delete swallows per-item errors; restore gives no
  location feedback.

### Journey 7 (Export)
- Context menu Export → `ExportService.export(item, from:, sourceView: cell)` (`:444-448`); bulk →
  `exportMultiple`, anchored to `rightBarButtonItems?.first` (see issues).

## API-Memo open observations on these files

- Obs #1 (trash lookup by `originalName`): not confirmed here (lives in `FileSystem.swift`); `RecentlyDeleted` passes
  the whole `VaultItem` (`:112`, `:122`).
- Obs #3, #4, #5 (ImportService): not confirmed here.
- FolderPicker "leftover `print()`": NOT CONFIRMED, no prints exist (stale memo).
- RecentlyDeleted entry: current code matches.
- `UIViewController+Presentation`: matches; whether AuthService still hand-rolls the loop not checked.

## Suspected issues

- `FileBrowser.swift:17,21,302-308,485-497` **stale pending-move state**: cancelling the picker doesn't clear
  `itemsPendingBulkAction`/`itemPendingMove`. After a cancelled bulk Move, a later single Move + "Move Here" runs the
  bulk branch first and moves the earlier selection (errors swallowed). Cause: `FolderPicker.swift:58` cancel has no callback.
- `FileBrowser.swift:223-224` **New Document**: `createFile` overwrites a same-named file (no collision check, result
  ignored); bypasses `FileSystem`; `isEncrypted: false` in a possibly encrypted vault; bypasses free-tier count; `/` in
  name not validated.
- `FileBrowser.swift:525` (guess) unchecked `items[destinationIndexPath.item]` in `dropSessionDidUpdate`/`performDropWith`.
- `FileBrowser.swift:285` bulk Export iPad anchor uses `rightBarButtonItems?.first` (Delete).
- `FileBrowser.swift:385` Import iPad anchor uses `rightBarButtonItems?.last` (Select).
- `FileBrowser.swift:267,291,488,493` silent failures with `try?`; picker doesn't prevent moving into itself.
- `FileBrowser.swift:162-168` load error dropped before auth.
- `FileBrowser.swift:45-54` temp scan on every appear in release.
- `FileBrowser.swift:302` `item` unused; picker always starts at root.
- `FileBrowser.swift:529-531` drop on file cell proposes `.move` but does nothing.
- `FileBrowser.swift:508` drag provider vends on-disk `diskURL` (encrypted UUID file) (guess, low impact).
- `FileBrowser.swift:436,525` items captured from live `items`; may be gone after a reload.
- `FileCell.swift:99-108,121-126` stale thumbnail on reuse (no cancel, no item-ID check) (guess).
- `FileCell.swift:54,73-85,104-107` dead code; `gridMode` unused (`:88`).
- `FolderPicker.swift:53` errors swallowed; `:17` `rootDirectory` unused; no title/empty state.
- `RecentlyDeleted.swift:119-127` Delete Permanently unconfirmed.
- `RecentlyDeleted.swift:94-95` vs `FileSystem.swift:609` duplicated 30-day figure.
- `RecentlyDeleted.swift:44,73` only `.root` trash.
- `FileBrowser.swift:40`, `RecentlyDeleted.swift:114` restore refresh via global notification.
- `FileIconProvider.swift:13,43` inconsistent asset caching (minor).
- `Main.storyboard` is empty (candidate dead file; not checked against Info.plist).

NOT READ: nothing skipped. Read only `SecuritySettings.swift:170-185`, `FileSystem.swift:425-510`, `:609` and
`ThumbnailService.swift:45-75` to follow references.
