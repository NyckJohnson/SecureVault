# App settings for the iOS Agent Pipeline. Plain KEY="value" lines only: this file is
# read by both bash and Python. Paths are relative to the app folder.
#
# Defaults live in the pipeline's workflow/defaults.sh and stacks/<stack>/defaults.sh.
# To override one for this app only, copy its line here (e.g. REVIEW_MODE="split").
# Write KEY="value" or KEY='value': no spaces around =, no $VARIABLES (they are not expanded).

# The stack this app is built with (`ios-pipeline stacks` lists them). Chosen during /discuss
# with `ios-pipeline stack select <name>`, which also adds the stack's settings below.
STACK="ios"

# --- iOS stack: the Xcode project (created by hand during /setup) ---
APP_PROJECT="KoalaTVault.xcodeproj"
APP_SCHEME="KoalaTVault"
# Swift module name of the app (what tests `@testable import`); usually the same as the scheme.
APP_MODULE="KoalaTVault"
# Folder Xcode synchronizes with the app target, and with the unit test target.
# Modules live in <APP_SOURCE_DIR>/Modules/<Module>/, their tests in <APP_TEST_DIR>/<Module>/.
APP_SOURCE_DIR="KoalaTVault"
APP_TEST_DIR="KoalaTVaultTests"
UNIT_TEST_TARGET="KoalaTVaultTests"
UI_TEST_TARGET="KoalaTVaultUITests"
BASE_BRANCH="main"

# Gates run on iOS 18.6: on the iOS 26.x simulators SKTestSession writes fail under xcodebuild (Apple FB22237318).
SIMULATOR_NAME="iPhone 16 Pro iOS 18.6,OS=18.6"
