//
//  J12UpgradeFromOneVaultJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 12: Upgrade from one vault. `UITEST_LEGACY_LOCK` seeds the 1.2 layout (the seed file in the old vault, a
//  blob for `UITEST_PASSWORD`, lock mode set, not upgraded), so the upgrade runs at launch. Not covered (no seed
//  makes them happen): an interrupted upgrade finishing at the next launch, an unfinished lock change with no
//  password on the device, and the "Couldn't finish updating your vaults" failure. Face ID kept for "My Vault" in
//  the Password + Face ID layout cannot be observed without biometrics.
//

import XCTest

final class J12UpgradeFromOneVaultJourneyTests: JourneyTestCase {

    private let seedName = "old-note.txt"

    override var launchesInSetUp: Bool { false }

    // MARK: - No lock

    func testJourney12_NoLockKeepsTheFilesInTheUnencryptedVault() {
        launch(environment: ["UITEST_SEED_FILE_NAME": seedName])
        waitForLockScreen()
        openUnencryptedVault()
        XCTAssertTrue(app.navigationBars["KoalaTVault"].exists)
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 5), "The files stay in the unencrypted vault, unchanged")
    }

    // MARK: - Password (and Password + Face ID)

    private func assertUpgradedToMyVault(file: StaticString = #filePath, line: UInt = #line) {
        // The upgrade ends on the lock screen.
        waitForLockScreen(file: file, line: line)
        XCTAssertFalse(app.staticTexts["Couldn't finish updating your vaults. Restart the app to try again."].exists,
                       file: file, line: line)

        // The unencrypted vault starts empty.
        openUnencryptedVault(file: file, line: line)
        XCTAssertEqual(app.collectionViews["fileGrid"].cells.count, 0, "The unencrypted vault starts empty",
                       file: file, line: line)
        lockApp(file: file, line: line)

        // The same password opens "My Vault", with the old files (leftover plaintext, encrypted on open).
        attemptOpen(with: Self.password, file: file, line: line)
        let migration = app.staticTexts["migration.titleLabel"]
        if migration.waitForExistence(timeout: 5) {
            XCTAssertTrue(migration.waitForNonExistence(timeout: 30), "Migration did not close", file: file, line: line)
        }
        waitForBrowser(file: file, line: line)
        XCTAssertTrue(app.navigationBars["My Vault"].waitForExistence(timeout: 5), "The vault is named \"My Vault\"",
                      file: file, line: line)
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 10), "The old files are in My Vault", file: file, line: line)
    }

    func testJourney12_PasswordLockBecomesMyVaultWithTheSamePassword() {
        launch(environment: ["UITEST_LEGACY_LOCK": "password", "UITEST_PASSWORD": Self.password,
                             "UITEST_SEED_FILE_NAME": seedName])
        assertUpgradedToMyVault()
    }

    func testJourney12_PasswordAndFaceIDLockBecomesMyVaultWithTheSamePassword() {
        launch(environment: ["UITEST_LEGACY_LOCK": "biometric", "UITEST_PASSWORD": Self.password,
                             "UITEST_SEED_FILE_NAME": seedName])
        assertUpgradedToMyVault()
    }

    func testJourney12_OpeningMyVaultShowsTheMigrationScreenForLeftoverFiles() {
        launch(environment: ["UITEST_LEGACY_LOCK": "password", "UITEST_PASSWORD": Self.password,
                             "UITEST_SEED_FILE_NAME": seedName, "UITEST_MIGRATION_FILE_DELAY": "2"])
        attemptOpen(with: Self.password)
        let title = app.staticTexts["migration.titleLabel"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "The Migration screen should show")
        XCTAssertEqual(title.label, "Encrypting Files")
        XCTAssertTrue(title.waitForNonExistence(timeout: 30))
        waitForBrowser()
    }
}
