import UIKit

/// Records the alerts it is asked to show instead of presenting them.
@MainActor
final class MockAlertPresenting: AlertPresenting {
    /// A recorded alert.
    enum Alert: Equatable, Sendable {
        case error(String)
        case success(String)
    }

    /// Every alert so far, in order.
    private(set) var alerts: [Alert] = []

    init() {}

    func showError(_ error: Error) {
        alerts.append(.error(error.localizedDescription))
    }

    func showError(_ message: String) {
        alerts.append(.error(message))
    }

    func showSuccess(_ message: String) {
        alerts.append(.success(message))
    }
}
