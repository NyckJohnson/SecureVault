//
//  VaultUITestCase.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 9/14/26.
//

import XCTest

/// Base class for UI tests that launch the app fresh each time.
/// Subclasses should call `super.setUp()` first and `super.tearDown()` last,
/// adding only test-specific setup/teardown around it.
class VaultUITestCase: XCTestCase {

    var app: XCUIApplication!

    /// Override to add launch environment variables before the app launches.
    /// Defaults to empty, so existing subclasses are unaffected.
    var additionalLaunchEnvironment: [String: String] { [:] }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launchEnvironment = additionalLaunchEnvironment
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func skipSetupIfNeeded() {
        let continueButton = app.buttons["continueButton"]
        if continueButton.waitForExistence(timeout: 2) {
            continueButton.tap()
        }
    }
}
