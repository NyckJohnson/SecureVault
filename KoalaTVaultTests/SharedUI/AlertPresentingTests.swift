import Testing
import UIKit

@testable import KoalaTVault

/// A plain view controller that gets the default `AlertPresenting` implementation.
@MainActor
private final class AlertHostViewController: UIViewController, AlertPresenting {}

@MainActor
private func makeHostedController() -> (AlertHostViewController, UIWindow) {
    let window = UIWindow(frame: UIScreen.main.bounds)
    let host = AlertHostViewController()
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.loadViewIfNeeded()
    return (host, window)
}

private struct DescribedError: LocalizedError {
    var errorDescription: String? { "Disk is full" }
}

@MainActor
@Suite struct AlertPresentingTests {
    @Test("showError(String) presents an alert titled Error with the message and one OK action")
    func errorStringAlert() throws {
        let (host, window) = makeHostedController()
        defer { window.isHidden = true }

        host.showError("Something broke")

        let alert = try #require(host.presentedViewController as? UIAlertController)
        #expect(alert.preferredStyle == .alert)
        #expect(alert.title == "Error")
        #expect(alert.message == "Something broke")
        #expect(alert.actions.count == 1)
        #expect(alert.actions.first?.title == "OK")
    }

    @Test("showError(Error) uses the error's localizedDescription as the message")
    func errorObjectAlert() throws {
        let (host, window) = makeHostedController()
        defer { window.isHidden = true }

        host.showError(DescribedError())

        let alert = try #require(host.presentedViewController as? UIAlertController)
        #expect(alert.title == "Error")
        #expect(alert.message == DescribedError().localizedDescription)
        #expect(alert.actions.count == 1)
        #expect(alert.actions.first?.title == "OK")
    }

    @Test("showSuccess presents an alert with no title, the message and an OK action")
    func successAlert() throws {
        let (host, window) = makeHostedController()
        defer { window.isHidden = true }

        host.showSuccess("Exported 3 files")

        let alert = try #require(host.presentedViewController as? UIAlertController)
        #expect(alert.title == nil || alert.title?.isEmpty == true)
        #expect(alert.message == "Exported 3 files")
        #expect(alert.actions.first?.title == "OK")
    }

    @Test("The alert is presented from the topmost presented controller")
    func presentedFromTopmost() throws {
        let (host, window) = makeHostedController()
        defer { window.isHidden = true }
        let first = UIViewController()
        let second = UIViewController()
        host.present(first, animated: false)
        first.present(second, animated: false)

        host.showError("Nested")

        let alert = try #require(second.presentedViewController as? UIAlertController)
        #expect(alert.message == "Nested")
        #expect(host.presentedViewController === first)
        #expect(first.presentedViewController === second)
    }

    @Test("A success alert is also presented from the topmost presented controller")
    func successFromTopmost() throws {
        let (host, window) = makeHostedController()
        defer { window.isHidden = true }
        let child = UIViewController()
        host.present(child, animated: false)

        host.showSuccess("Done")

        let alert = try #require(child.presentedViewController as? UIAlertController)
        #expect(alert.message == "Done")
    }
}
