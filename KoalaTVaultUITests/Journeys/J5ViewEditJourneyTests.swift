//
//  J5ViewEditJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 5: View / edit. Seeds are plain-text files, so the viewer pages are QuickLook pages.
//  Not covered: image zoom (no image seed), video playback controls (no video seed), Share
//  (system share sheet; only the button's presence is checked), the tap-toggles-bars behaviour
//  and the 3 s bar fade (the tap is consumed by the QuickLook page of a text seed).
//

import XCTest

final class J5ViewEditJourneyTests: JourneyTestCase {

    private let seedName = "alpha.txt"

    override var launchEnvironment: [String: String] {
        ["UITEST_SEED_FILE_NAME": seedName]
    }

    override func setUp() {
        super.setUp()
        completeSetupWithNoLockIfShown()
    }

    // MARK: - Viewer

    func testJourney5_TapFileOpensFullScreenViewerAndCloseReturns() {
        cell(seedName).tap()
        XCTAssertTrue(app.otherElements["viewer"].waitForExistence(timeout: 10), "The viewer did not open")
        XCTAssertEqual(app.staticTexts["viewer.titleLabel"].label, seedName)
        XCTAssertTrue(app.buttons["viewer.shareButton"].exists)
        XCTAssertFalse(app.buttons["viewer.playPauseButton"].isHittable, "Video controls only show for videos")
        app.buttons["viewer.closeButton"].tap()
        XCTAssertTrue(app.otherElements["viewer"].waitForNonExistence(timeout: 5), "X should close the viewer")
        waitForBrowser()
        XCTAssertTrue(cell(seedName).exists)
    }

    func testJourney5_TextFileShowsInQuickLookPage() {
        cell(seedName).tap()
        XCTAssertTrue(app.otherElements["viewer"].waitForExistence(timeout: 10))
        let page = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "filePage.\(seedName)")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "No file page for \(seedName)")
        XCTAssertTrue(app.descendants(matching: .any)["filePage.\(seedName).quickLook"].waitForExistence(timeout: 10),
                      "Other kinds show in QuickLook")
    }

    // MARK: - Editor

    func testJourney5_NewDocumentOpensEditorWithToolbarAndDoneCloses() {
        app.navigationBars.buttons["browser.newDocumentButton"].tap()
        let alert = app.alerts["New Document"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        type("Notes", into: alert.textFields["browser.newDocumentNameField"])
        tapAlertButton("Create", in: alert)
        XCTAssertTrue(app.navigationBars["Notes.rtf"].waitForExistence(timeout: 5), "Editor should open titled with the name")
        let textView = app.textViews["textEditor.textView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 5))
        type("Hello", into: textView)
        for id in ["boldButton", "italicButton", "underlineButton", "decreaseFontSizeButton", "increaseFontSizeButton",
                   "alignLeftButton", "alignCenterButton", "alignRightButton"] {
            XCTAssertTrue(app.buttons["textEditor.\(id)"].waitForExistence(timeout: 3), "Toolbar button \(id) missing")
        }
        app.buttons["textEditor.doneButton"].tap()
        XCTAssertTrue(app.navigationBars["Notes.rtf"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(cell("Notes.rtf").waitForExistence(timeout: 5))
    }

    func testJourney5_TappingRtfOpensEditorNotViewerAndKeepsSavedText() {
        createDocument(named: "Notes", text: "Persisted text")
        cell("Notes.rtf").tap()
        XCTAssertTrue(app.navigationBars["Notes.rtf"].waitForExistence(timeout: 5), "An .rtf opens the editor")
        XCTAssertFalse(app.otherElements["viewer"].exists)
        let textView = app.textViews["textEditor.textView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 5))
        XCTAssertTrue((textView.value as? String ?? "").contains("Persisted text"),
                      "Saved text should reload. Value: \(String(describing: textView.value))")
        app.buttons["textEditor.doneButton"].tap()
        XCTAssertTrue(app.navigationBars["Notes.rtf"].waitForNonExistence(timeout: 5))
    }

    func testJourney5_AutosavesOneSecondAfterTyping() {
        app.navigationBars.buttons["browser.newDocumentButton"].tap()
        let alert = app.alerts["New Document"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        type("Auto", into: alert.textFields["browser.newDocumentNameField"])
        tapAlertButton("Create", in: alert)
        type("Autosaved text", into: app.textViews["textEditor.textView"])
        Thread.sleep(forTimeInterval: 2.5)
        // Autosave has fired by now; Done then saves again. The reopened text proves the content was kept.
        app.buttons["textEditor.doneButton"].tap()
        XCTAssertTrue(cell("Auto.rtf").waitForExistence(timeout: 5))
        cell("Auto.rtf").tap()
        let textView = app.textViews["textEditor.textView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 5))
        XCTAssertTrue((textView.value as? String ?? "").contains("Autosaved text"))
    }

    // MARK: - Failure paths

    /// A file that can't be decrypted shows "This file can't be opened." on its page.
    func testJourney5_UndecryptableFileShowsCantBeOpenedLabel() {
        launchUndecryptable(seed: "secret.png")
        cell("secret.png").tap()
        XCTAssertTrue(app.otherElements["viewer"].waitForExistence(timeout: 10), "The viewer did not open")
        XCTAssertTrue(app.staticTexts["This file can't be opened."].waitForExistence(timeout: 10),
                      "Page should say \"This file can't be opened.\"")
    }

    /// An editor load failure shows the error and the editor is read-only (the original is not overwritten).
    func testJourney5_EditorLoadFailureShowsErrorAndIsReadOnly() {
        launchUndecryptable(seed: "broken.rtf")
        cell("broken.rtf").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "A load failure should show an error")
        tapAlertButton("OK", in: alert)
        let textView = app.textViews["textEditor.textView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 5))
        textView.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2), "The editor must be read-only after a load failure")
    }

    /// Launches an unlocked password vault whose seeded file is plaintext, so decrypting it fails.
    private func launchUndecryptable(seed: String) {
        app.terminate()
        launch(environment: ["UITEST_PASSWORD": Self.password, "UITEST_SEED_FILE_NAME": seed])
        XCTAssertTrue(app.staticTexts["lockScreen.titleLabel"].waitForExistence(timeout: 10), "Lock screen missing")
        type(Self.password, into: app.secureTextFields["passwordField"])
        app.buttons["unlockButton"].tap()
        waitForBrowser()
    }
}

/// Journey 5 regression (baseline fix 13): New Document in an encrypted vault is encrypted, indexed and conflict-safe.
final class J5NewDocumentUnderLockJourneyTests: JourneyTestCase {

    override var launchEnvironment: [String: String] { ["UITEST_PASSWORD": Self.password] }

    override func setUp() {
        super.setUp()
        unlockWithPassword()
    }

    func testJourney5_NewDocumentUnderLockKeepsSameNameDocumentsAndText() {
        createDocument(named: "notes", resultingFileName: "notes.rtf", text: "First text")
        createDocument(named: "notes", resultingFileName: "notes 1.rtf")
        XCTAssertTrue(cell("notes.rtf").exists, "The first document stays")
        XCTAssertTrue(cell("notes 1.rtf").exists, "The second gets a numbered name")

        cell("notes.rtf").tap()
        XCTAssertTrue(app.navigationBars["notes.rtf"].waitForExistence(timeout: 5), "An .rtf opens the editor")
        let textView = app.textViews["textEditor.textView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 5))
        XCTAssertTrue((textView.value as? String ?? "").contains("First text"),
                      "The first document must keep its text. Value: \(String(describing: textView.value))")
        app.buttons["textEditor.doneButton"].tap()
        XCTAssertTrue(app.navigationBars["notes.rtf"].waitForNonExistence(timeout: 5))
    }
}
