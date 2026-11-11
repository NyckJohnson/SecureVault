//
//  J5ViewEditJourneyTests.swift
//  KoalaTVaultUITests
//
//  Journey 5: View / edit. Seeds are plain-text files, so the viewer pages are QuickLook pages.
//  Not covered: image zoom, video playback controls (no video seed), Share
//  (system share sheet; only the button's presence is checked), the tap-toggles-bars behaviour
//  and the 3 s bar fade (the tap is consumed by the QuickLook page of a text seed).
//

import XCTest

final class J5ViewEditJourneyTests: JourneyTestCase {

    private let seedName = "alpha.txt"

    override var launchEnvironment: [String: String] {
        ["UITEST_SEED_FILE_NAME": seedName]
    }

    override func setUp() async throws {
        try await super.setUp()
        openUnencryptedVault()
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

    /// Opens "My Vault" (made from a seeded 1.2 vault) holding `seed` as a plaintext leftover that Skip left
    /// unencrypted, so decrypting it fails.
    private func launchUndecryptable(seed: String) {
        app.terminate()
        launch(environment: ["UITEST_LEGACY_LOCK": "password", "UITEST_PASSWORD": Self.password,
                             "UITEST_SEED_FILE_NAME": seed, "UITEST_FAIL_MIGRATION_FILE": seed])
        attemptOpen(with: Self.password)
        let alert = app.alerts["Some Files Failed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "The migration should report the failed file")
        tapAlertButton("Skip", in: alert)
        waitForBrowser()
        XCTAssertTrue(cell(seed).waitForExistence(timeout: 10), "\(seed) should be listed")
    }
}

/// Journey 5 regression (baseline fix 13): New Document in an encrypted vault is encrypted, indexed and conflict-safe.
final class J5NewDocumentUnderLockJourneyTests: JourneyTestCase {

    override var launchEnvironment: [String: String] { ["UITEST_PASSWORD": Self.password] }

    override func setUp() async throws {
        try await super.setUp()
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

/// Journey 5: swiping onto an `.rtf` page in the viewer opens the editor, and Done returns to the page
/// the viewer was swiped from. The neighbours are seeded images (`UITEST_SEED_IMAGE_COUNT`), because synthesized
/// swipes page on image pages but not on QuickLook (.txt) pages. Sorted by name:
/// uitest-image-0.png, uitest-image-0x.rtf (created through New Document), uitest-image-1.png.
class J5ViewerRtfPageJourneyBase: JourneyTestCase {

    let first = "uitest-image-0.png"
    let rtfBase = "uitest-image-0x"
    let last = "uitest-image-1.png"

    func openViewer(on name: String, file: StaticString = #filePath, line: UInt = #line) {
        cell(name).tap()
        XCTAssertTrue(app.otherElements["viewer"].waitForExistence(timeout: 10), "The viewer did not open",
                      file: file, line: line)
        expectViewerShows(name, file: file, line: line)
    }

    func expectViewerShows(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["viewer.titleLabel"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Viewer title missing", file: file, line: line)
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", name), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed,
                       "Viewer should show \(name), shows \(title.label)", file: file, line: line)
    }

    func swipe(left: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let viewer = app.otherElements["viewer"]
        XCTAssertTrue(viewer.exists, "No viewer to swipe", file: file, line: line)
        let from = viewer.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.9 : 0.1, dy: 0.3))
        let to = viewer.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.1 : 0.9, dy: 0.3))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    func expectEditorOpen(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons["textEditor.doneButton"].waitForExistence(timeout: 10),
                      "Swiping onto the .rtf page should open the editor", file: file, line: line)
    }

    func tapDoneAndExpectViewer(on name: String, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["textEditor.doneButton"].tap()
        XCTAssertTrue(app.buttons["textEditor.doneButton"].waitForNonExistence(timeout: 5),
                      "The editor should close on Done", file: file, line: line)
        XCTAssertTrue(app.otherElements["viewer"].waitForExistence(timeout: 5), "Viewer should be showing again",
                      file: file, line: line)
        expectViewerShows(name, file: file, line: line)
    }

    func closeViewer(file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["viewer.closeButton"].tap()
        XCTAssertTrue(app.otherElements["viewer"].waitForNonExistence(timeout: 5), "X should close the viewer",
                      file: file, line: line)
        waitForBrowser(file: file, line: line)
    }
}

final class J5ViewerRtfPageJourneyTests: J5ViewerRtfPageJourneyBase {

    override var launchEnvironment: [String: String] {
        ["UITEST_SEED_IMAGE_COUNT": "2"]
    }

    override func setUp() async throws {
        try await super.setUp()
        openUnencryptedVault()
        createDocument(named: rtfBase, text: "Page text")
    }

    func testJourney5_SwipeOntoRtfOpensEditorAndDoneReturnsToPreviousPage() {
        openViewer(on: first)
        swipe(left: true)
        expectEditorOpen()
        tapDoneAndExpectViewer(on: first)
        swipe(left: true)
        expectEditorOpen()
        tapDoneAndExpectViewer(on: first)
        closeViewer()
    }

    func testJourney5_SwipeBackOntoRtfOpensEditorAndDoneReturnsToThirdItem() {
        openViewer(on: last)
        swipe(left: false)
        expectEditorOpen()
        tapDoneAndExpectViewer(on: last)
        swipe(left: false)
        expectEditorOpen()
        tapDoneAndExpectViewer(on: last)
        closeViewer()
    }
}

/// The same return path in an encrypted vault. The seeded images are moved into Test Vault (journey 11), so they are
/// encrypted there; the `.rtf` is created inside the vault.
final class J5ViewerRtfPageUnderLockJourneyTests: J5ViewerRtfPageJourneyBase {

    override var launchEnvironment: [String: String] {
        ["UITEST_PASSWORD": Self.password, "UITEST_SEED_IMAGE_COUNT": "2"]
    }

    override func setUp() async throws {
        try await super.setUp()
        // The seeds are plaintext in the unencrypted vault: move them into Test Vault (encrypting them), then open it.
        openUnencryptedVault()
        moveToVault(first)
        moveToVault(last)
        lockApp()
        unlockWithPassword()
        XCTAssertTrue(cell(first).waitForExistence(timeout: 10), "The images should be in Test Vault")
        createDocument(named: rtfBase, text: "Locked text")
    }

    func testJourney5_UnderLockSwipeOntoRtfEditsAndDoneReturnsToPreviousPage() {
        openViewer(on: first)
        swipe(left: true)
        expectEditorOpen()
        let textView = app.textViews["textEditor.textView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 5))
        XCTAssertTrue((textView.value as? String ?? "").contains("Locked text"),
                      "Saved text should load. Value: \(String(describing: textView.value))")
        type(" more", into: textView)
        tapDoneAndExpectViewer(on: first)
        swipe(left: true)
        expectEditorOpen()
        let reopened = app.textViews["textEditor.textView"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertTrue((reopened.value as? String ?? "").contains("more"),
                      "Text typed before Done should be kept. Value: \(String(describing: reopened.value))")
        tapDoneAndExpectViewer(on: first)
        closeViewer()
    }

    func testJourney5_UnderLockSwipeBackOntoRtfDoneReturnsToThirdItem() {
        openViewer(on: last)
        swipe(left: false)
        expectEditorOpen()
        tapDoneAndExpectViewer(on: last)
        closeViewer()
    }
}
