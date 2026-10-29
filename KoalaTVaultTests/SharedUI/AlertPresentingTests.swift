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

@MainActor
private func presentAndWait(_ presenter: UIViewController, _ presented: UIViewController) async {
    presented.modalPresentationStyle = .fullScreen
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        presenter.present(presented, animated: false) { continuation.resume() }
    }
}

/// Waits (bounded) until the controller has a presented controller.
@MainActor
private func waitForPresentation(on controller: UIViewController) async {
    for _ in 0..<200 where controller.presentedViewController == nil {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
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
    func presentedFromTopmost() async throws {
        let (host, window) = makeHostedController()
        defer { window.isHidden = true }
        let first = UIViewController()
        let second = UIViewController()
        await presentAndWait(host, first)
        await presentAndWait(first, second)

        host.showError("Nested")
        await waitForPresentation(on: second)

        let alert = try #require(second.presentedViewController as? UIAlertController)
        #expect(alert.message == "Nested")
        #expect(host.presentedViewController === first)
        #expect(first.presentedViewController === second)
    }

    @Test("A success alert is also presented from the topmost presented controller")
    func successFromTopmost() async throws {
        let (host, window) = makeHostedController()
        defer { window.isHidden = true }
        let child = UIViewController()
        await presentAndWait(host, child)

        host.showSuccess("Done")
        await waitForPresentation(on: child)

        let alert = try #require(child.presentedViewController as? UIAlertController)
        #expect(alert.message == "Done")
    }
}
