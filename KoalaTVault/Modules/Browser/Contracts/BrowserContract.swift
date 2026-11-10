import UIKit

// coverage-exempt-file: declarations only

/// Makes the root file browser.
@MainActor
protocol BrowserFactory: AnyObject {
    /// The navigation controller holding the root browser.
    func makeRootBrowser() -> UINavigationController
    /// Reloads every browser on screen.
    func reloadAll()
}
