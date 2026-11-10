Git
  🔧 on branch adopt/main, not the trunk main
       → git switch main
  🔧 uncommitted changes
       → commit or stash them; the adoption starts from a clean tree
  🔧 refs that clash with pipeline names: branch adopt/main
       → rename them (git branch -m / delete and recreate the tag)
  ℹ️  trunk: main

ios (confidence 1.0): KoalaTVault.xcodeproj: app target KoalaTVault (Swift 5.0), 28 Swift files, 6128 lines; unit tests KoalaTVaultTests, UI tests KoalaTVaultUITests
  APP_PROJECT="KoalaTVault.xcodeproj"
  APP_MODULE="KoalaTVault"
  APP_SCHEME="KoalaTVault"
  APP_SOURCE_DIR="KoalaTVault"
  UNIT_TEST_TARGET="KoalaTVaultTests"
  APP_TEST_DIR="KoalaTVaultTests"
  UI_TEST_TARGET="KoalaTVaultUITests"
  🔧 Default Actor Isolation is MainActor
       → set it to nonisolated during setup; legacy code may show new warnings, which aren't gated
  ℹ️  Swift language version 5.0
       → stays as it is until Stage 6; adopted code must be free of Swift 6 warnings
  ℹ️  minimum iOS 16.6
  ℹ️  Swift packages: https://github.com/SimplyDanny/SwiftLintPlugins
  ℹ️  UIKit: 23 Swift files import UIKit, 2 storyboards/xibs
       → the pipeline's agents favor SwiftUI; decide in the discussion whether these views stay UIKit when adopted
  ℹ️  no -uiTesting launch argument
       → added during the baseline stage
