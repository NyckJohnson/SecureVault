import UIKit

/// The default `AlertPresenting` implementation for view controllers. Alerts are presented from the
/// topmost presented controller, so they still appear when something is already presented on top of
/// the conforming controller.
extension AlertPresenting where Self: UIViewController {
    func showError(_ error: Error) {
        showError(error.localizedDescription)
    }

    func showError(_ message: String) {
        presentAlert(title: "Error", message: message)
    }

    func showSuccess(_ message: String) {
        presentAlert(title: nil, message: message)
    }

    /// Presents an alert with `title`, `message` and a single OK action.
    private func presentAlert(title: String?, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topmostPresentedController.present(alert, animated: true)
    }
}
