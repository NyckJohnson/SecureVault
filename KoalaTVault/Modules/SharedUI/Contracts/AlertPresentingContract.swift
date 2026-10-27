import UIKit

// coverage-exempt-file: declarations only

/// Shows error and success alerts (a default implementation exists for view controllers).
@MainActor protocol AlertPresenting: AnyObject {
    /// Shows an "Error" alert with the error's message.
    func showError(_ error: Error)
    /// Shows an "Error" alert with `message`.
    func showError(_ message: String)
    /// Shows an untitled alert with `message`.
    func showSuccess(_ message: String)
}
