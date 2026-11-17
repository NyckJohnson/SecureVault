//
//  J11TransferBetweenVaultsJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 11: Move or copy to another vault. The seed file is plaintext in the unencrypted vault; "Test Vault"
//  (encrypted, `UITEST_PASSWORD`) is the other vault. Not covered: the free-tier 100-file limit (needs a target past
//  100 files), a failing item ("N of M failed"; no seed makes a transfer fail), and backgrounding mid-transfer (the
//  transfer is too short-lived to interrupt reliably).
//

import XCTest

final class J11TransferBetweenVaultsJourneyTests: JourneyTestCase {

    private let seedName = "carry-me.txt"

    override var launchEnvironment: [String: String] {
        ["UITEST_PASSWORD": Self.password, "UITEST_SEED_FILE_NAME": seedName]
    }

    private func transferViaContextMenu(_ name: String, isMove: Bool) {
        longPressCell(name)
        tapMenuAction(isMove ? "browser.contextMenu.moveToVault" : "browser.contextMenu.copyToVault",
                      title: isMove ? "Move to Vault…" : "Copy to Vault…")
    }

    private func expectPickerClosed() {
        XCTAssertTrue(app.buttons["vaultPicker.useButton"].waitForNonExistence(timeout: 15), "The vault picker did not close")
    }

    /// Locks and opens Test Vault.
    private func switchToTestVault() {
        lockApp()
        unlockWithPassword()
        XCTAssertTrue(browserTitle("Test Vault").waitForExistence(timeout: 5))
    }

    // MARK: - Unencrypted -> encrypted

    func testJourney11_MoveToVaultEncryptsTheItemAndRemovesTheOriginal() {
        openUnencryptedVault()
        transferViaContextMenu(seedName, isMove: true)
        XCTAssertFalse(app.buttons["vaultPicker.unencryptedRow"].waitForExistence(timeout: 2),
                       "From the unencrypted vault, the picker does not offer the unencrypted vault")
        usePickedVault(password: Self.password)
        expectPickerClosed()
        XCTAssertTrue(cell(seedName).waitForNonExistence(timeout: 15), "A move removes the original")
        XCTAssertTrue(browserTitle("KoalaTVault").exists, "The browser stays in the current vault")
        openRecentlyDeleted()
        XCTAssertFalse(app.tables["recentlyDeleted.list"].cells["recentlyDeleted.row.\(seedName)"].exists,
                       "A move does not go to Recently Deleted")
        app.navigationBars["Recently Deleted"].buttons["Security"].tap()
        dismissSettingsSheet()

        switchToTestVault()
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 10), "The item should be in Test Vault")
    }

    func testJourney11_CopyToVaultKeepsTheOriginal() {
        openUnencryptedVault()
        transferViaContextMenu(seedName, isMove: false)
        usePickedVault(password: Self.password)
        expectPickerClosed()
        XCTAssertTrue(cell(seedName).exists, "A copy keeps the original")
        switchToTestVault()
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 10), "The copy should be in Test Vault")
    }

    func testJourney11_ClashingNameGetsNumberSuffix() {
        openUnencryptedVault()
        for _ in 1...2 {
            transferViaContextMenu(seedName, isMove: false)
            usePickedVault(password: Self.password)
            expectPickerClosed()
        }
        switchToTestVault()
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 10))
        XCTAssertTrue(cell("carry-me 1.txt").waitForExistence(timeout: 10), "The clashing copy should get \" 1\"")
    }

    func testJourney11_FolderGoesWithEverythingInIt() {
        openUnencryptedVault()
        createFolderViaBar(named: "Box")
        cell("Box").tap()
        XCTAssertTrue(browserTitle("Box").waitForExistence(timeout: 5))
        createDocument(named: "inside")
        app.buttons["browser.backButton"].tap()
        XCTAssertTrue(cell("Box").waitForExistence(timeout: 5))
        moveToVault("Box")
        switchToTestVault()
        XCTAssertTrue(cell("Box").waitForExistence(timeout: 10))
        cell("Box").tap()
        XCTAssertTrue(cell("inside.rtf").waitForExistence(timeout: 10), "The folder's content should come along")
    }

    // MARK: - Select mode

    func testJourney11_SelectModeMenuOffersMoveAndCopyToVault() {
        openUnencryptedVault()
        tapBarButton("selectButton", fallbackLabel: "Select")
        cell(seedName).tap()
        XCTAssertTrue(browserTitle("1 Selected").waitForExistence(timeout: 5))
        app.buttons["browser.selectActionsMenuButton"].tap()
        XCTAssertTrue(app.buttons["Move to Vault…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy to Vault…"].exists)
        XCTAssertFalse(app.buttons["To Vault"].exists, "The To Vault button is gone")
        app.buttons["Copy to Vault…"].tap()
        usePickedVault(password: Self.password)
        expectPickerClosed()
        XCTAssertTrue(cell(seedName).exists, "Copy keeps the original")
        switchToTestVault()
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 10))
    }

    // MARK: - Encrypted -> unencrypted

    func testJourney11_FromAnEncryptedVaultThePickerOffersTheUnencryptedVault() {
        openTestVaultHolding(seedName)
        transferViaContextMenu(seedName, isMove: true)
        let row = app.buttons["vaultPicker.unencryptedRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The picker offers \"Unencrypted Vault\" from an encrypted vault")
        XCTAssertTrue(app.secureTextFields["vaultPicker.passwordField"].exists)
        XCTAssertTrue(app.buttons["vaultPicker.useButton"].exists)
        row.tap()
        expectPickerClosed()
        XCTAssertTrue(cell(seedName).waitForNonExistence(timeout: 15), "The item left Test Vault")
        lockApp()
        openUnencryptedVault()
        XCTAssertTrue(cell(seedName).waitForExistence(timeout: 10), "The item should be in the unencrypted vault")
    }

    // MARK: - Failure paths

    func testJourney11_PasswordThatOpensNoVaultShowsIncorrectPassword() {
        openUnencryptedVault()
        transferViaContextMenu(seedName, isMove: true)
        usePickedVault(password: "nobodyHasThis1")
        let error = app.staticTexts["vaultPicker.errorLabel"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "Incorrect password")
        XCTAssertTrue(cell(seedName).exists || app.buttons["vaultPicker.useButton"].exists, "Nothing was transferred")
    }

    func testJourney11_TheCurrentVaultsOwnPasswordSaysTheItemsAreAlreadyThere() {
        openTestVaultHolding(seedName)
        transferViaContextMenu(seedName, isMove: false)
        usePickedVault(password: Self.password)
        let error = app.staticTexts["vaultPicker.errorLabel"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "These items are already in this vault.")
    }

    func testJourney11_PickerCancelTransfersNothing() {
        openUnencryptedVault()
        transferViaContextMenu(seedName, isMove: true)
        let cancel = app.buttons["vaultPicker.cancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        expectPickerClosed()
        XCTAssertTrue(cell(seedName).exists, "Nothing should have moved")
    }
}
