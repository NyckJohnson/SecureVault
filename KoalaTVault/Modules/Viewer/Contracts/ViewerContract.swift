import UIKit

// coverage-exempt-file: declarations only

/// Makes the file viewer and the rich-text editor.
@MainActor
protocol ViewerFactory: AnyObject {
    /// A full-screen viewer paging through `items`, starting at `index`.
    func makeViewer(items: [VaultItem], startingAt index: Int) -> UIViewController
    /// The rich-text editor for an `.rtf` item.
    func makeEditor(for item: VaultItem) -> UIViewController
}
