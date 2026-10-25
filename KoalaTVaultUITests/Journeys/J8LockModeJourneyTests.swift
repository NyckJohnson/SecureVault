//
//  J8LockModeJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 8: Change lock mode. Biometrics cannot be enrolled on the simulator, so the
//  Password + Face ID rows are checked but the switch to biometric is an environment case.
//  Not covered: a failed lock removal (Retry/Skip keeps Password) because `UITEST_PASSWORD` seeds the file as
//  plaintext, so no decrypt ever touches it and there is no way to start with an encrypted failing file; pausing a migration when backgrounded and resuming after a kill (the migration
//  is too short-lived to interrupt reliably), and the migration screen's progress text beyond what
//  can be seen before it closes. Current lock mode = the Lock Mode row with `isSelected`.
//

import XCTest

final class J8LockModeJourneyTests: JourneyTestCase {

    static let newPassword = "brandNewPassword456"
    private let seedName = "lock-me.txt"

    var seedsPassword = false
    var failingFile: String? = nil

    override var launchesInSetUp: Bool { false }

    private func start(password: Bool, failMigration: Bool = false) {
        var env = ["UITEST_SEED_FILE_NAME": seedName]
        if password { env["UITEST_PASSWORD"] = Self.password }
        if failMigration { env["UITEST_FAIL_MIGRATION_FILE"] = seedName }
        launch(environment: env)
        if password {
            unlockWithPassword()
        } else {
            completeSetupWithNoLockIfShown()
        }
    }

    private func row(_ id: String) -> XCUIElement { app.cells[id] }

    private func setPassword(_ password: String = JourneyTestCase.password) {
        row("settings.lockMode.passwordRow").tap()
        let alert = app.alerts["Set Password"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Set Password alert missing")
        type(password, into: alert.secureTextFields["settings.passwordField"])
        type(password, into: alert.secureTextFields["settings.confirmPasswordField"])
        tapAlertButton("Set", in: alert)
    }

    private func waitForMigrationToClose() {
        XCTAssertTrue(app.staticTexts["migration.titleLabel"].waitForNonExistence(timeout: 30),
                      "The migration screen did not close")
    }

    // MARK: - No Lock -> Password

    func testJourney8_NoLockToPasswordEncryptsAndShowsPasswordMode() {
        start(password: false)
        openSettings()
        XCTAssertTrue(row("settings.lockMode.noLockRow").isSelected, "No Lock should be current at start")
        XCTAssertFalse(row("settings.changePasswordRow").exists, "Change Password must be absent in No Lock")
        setPassword()
        waitForMigrationToClose()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 10), "Settings should be back")
        XCTAssertTrue(row("settings.lockMode.passwordRow").waitForExistence(timeout: 5))
        XCTAssertTrue(row("settings.lockMode.passwordRow").isSelected, "Password should now be the lock mode")
        XCTAssertFalse(row("settings.lockMode.noLockRow").isSelected)
        XCTAssertTrue(row("settings.changePasswordRow").exists, "Change Password should now show")
        XCTAssertFalse(row("settings.lockMode.reEncryptRow").exists, "Every file is encrypted; no Re-encrypt row")
    }

    // MARK: - Password -> No Lock

    func testJourney8_RemoveLockCancelKeepsPasswordMode() {
        start(password: true)
        openSettings()
        XCTAssertTrue(row("settings.lockMode.passwordRow").isSelected)
        row("settings.lockMode.noLockRow").tap()
        let alert = app.alerts["Remove Lock?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Remove Lock? alert missing")
        tapAlertButton("Cancel", in: alert)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["migration.titleLabel"].exists, "Cancel must not start a migration")
        XCTAssertTrue(row("settings.lockMode.passwordRow").isSelected, "Password should still be the lock mode")
    }

    func testJourney8_PasswordToNoLockDecryptsAndRemovesLock() {
        start(password: true)
        openSettings()
        row("settings.lockMode.noLockRow").tap()
        let alert = app.alerts["Remove Lock?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Remove Lock? alert missing")
        tapAlertButton("Remove", in: alert)
        waitForMigrationToClose()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 10), "Settings should be back")
        XCTAssertTrue(row("settings.lockMode.noLockRow").isSelected, "No Lock should now be the lock mode")
        XCTAssertFalse(row("settings.changePasswordRow").exists, "Change Password must be gone in No Lock")
    }

    // MARK: - Password <-> Password + Face ID

    func testJourney8_PasswordToBiometricSwitchesImmediately() throws {
        start(password: true)
        openSettings()
        let biometric = row("settings.lockMode.biometricRow")
        XCTAssertTrue(biometric.waitForExistence(timeout: 5), "Password + Face ID row missing")
        biometric.tap()
        // The app ignores the tap when biometrics are unavailable, so the row stays unselected.
        let selected = NSPredicate(format: "isSelected == true")
        let outcome = XCTWaiter().wait(for: [expectation(for: selected, evaluatedWith: biometric)], timeout: 3)
        if outcome != .completed, !app.alerts.firstMatch.exists, !app.staticTexts["migration.titleLabel"].exists {
            throw XCTSkip("Face ID not enrolled on this simulator; covered by the device check")
        }
        XCTAssertTrue(biometric.isSelected, "Password + Face ID should be current right after the tap")
        XCTAssertFalse(row("settings.lockMode.passwordRow").isSelected)
        XCTAssertFalse(app.staticTexts["migration.titleLabel"].exists, "Switching between lock modes needs no migration")
    }

    // MARK: - Change password

    func testJourney8_ChangePasswordShowsSuccess() {
        start(password: true)
        openSettings()
        row("settings.changePasswordRow").tap()
        let alert = app.alerts["Change Password"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Change Password alert missing")
        type(Self.password, into: alert.secureTextFields["settings.currentPasswordField"])
        type(Self.newPassword, into: alert.secureTextFields["settings.newPasswordField"])
        type(Self.newPassword, into: alert.secureTextFields["settings.confirmNewPasswordField"])
        tapAlertButton("Change", in: alert)
        let done = app.alerts.firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "No result alert")
        XCTAssertTrue(done.staticTexts["Password changed successfully"].exists,
                      "Expected \"Password changed successfully\". Alert: \(done.debugDescription)")
        tapAlertButton("OK", in: done)
    }

    func testJourney8_ChangePasswordWithWrongCurrentPasswordShowsError() {
        start(password: true)
        openSettings()
        row("settings.changePasswordRow").tap()
        let alert = app.alerts["Change Password"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        type("notThePassword", into: alert.secureTextFields["settings.currentPasswordField"])
        type(Self.newPassword, into: alert.secureTextFields["settings.newPasswordField"])
        type(Self.newPassword, into: alert.secureTextFields["settings.confirmNewPasswordField"])
        tapAlertButton("Change", in: alert)
        expectErrorAlertAndDismiss(containing: "Current password is incorrect")
    }

    // MARK: - Migration failures

    /// Adding a lock with a file that fails: Retry (still fails), then Skip leaves the file plaintext,
    /// so "Re-encrypt Everything" shows.
    func testJourney8_AddLockFailureOffersRetryAndSkipThenReEncryptRow() {
        start(password: false, failMigration: true)
        openSettings()
        setPassword()
        let failure = app.alerts["Some Files Failed"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15), "\"Some Files Failed\" alert missing")
        XCTAssertTrue(failure.staticTexts["These files couldn't be migrated: \(seedName)"].exists,
                      "Alert should list the failed file. Alert: \(failure.debugDescription)")
        XCTAssertTrue(failure.buttons["Retry"].exists)
        XCTAssertTrue(failure.buttons["Skip"].exists)

        tapAlertButton("Retry", in: failure)
        XCTAssertTrue(app.alerts["Some Files Failed"].waitForExistence(timeout: 15),
                      "The file still fails, so the alert should come back after Retry")
        tapAlertButton("Skip", in: app.alerts["Some Files Failed"])
        waitForMigrationToClose()

        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 10))
        XCTAssertTrue(row("settings.lockMode.reEncryptRow").waitForExistence(timeout: 5),
                      "A skipped plaintext file should leave \"Re-encrypt Everything\" showing")
    }

    // MARK: - Regression: Remove Lock with encrypted content (baseline fix 11)

    func testJourney8_RemoveLockKeepsEncryptedFolderContentListable() {
        start(password: true)
        createFolderViaBar(named: "F")
        cell("F").tap()
        XCTAssertTrue(app.navigationBars["F"].waitForExistence(timeout: 5))
        createDocument(named: "notes")
        app.navigationBars["F"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["KoalaTVault"].waitForExistence(timeout: 5))

        openSettings()
        row("settings.lockMode.noLockRow").tap()
        let alert = app.alerts["Remove Lock?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Remove Lock? alert missing")
        tapAlertButton("Remove", in: alert)
        waitForMigrationToClose()
        XCTAssertFalse(app.alerts["Some Files Failed"].exists, "Removing the lock must not report failures")
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 10), "Settings should be back")
        XCTAssertTrue(row("settings.lockMode.noLockRow").isSelected)
        dismissSettingsSheet()

        XCTAssertTrue(cell("F").waitForExistence(timeout: 5), "The root must still list F")
        cell("F").tap()
        XCTAssertTrue(app.navigationBars["F"].waitForExistence(timeout: 5))
        XCTAssertTrue(cell("notes.rtf").waitForExistence(timeout: 5), "notes.rtf should be listed in F")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Listing F must not show an error. Alert: \(app.alerts.firstMatch.debugDescription)")
    }
}
