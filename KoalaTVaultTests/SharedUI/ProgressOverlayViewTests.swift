import Testing
import UIKit

@testable import KoalaTVault

// Assumed API (new): `ProgressOverlayView.show(in:title:style:status:)` where
// `style: ProgressOverlayView.Style = .progress` (cases `.progress`, `.activity`) and
// `status: String? = nil` (shown at show time; used by `.activity`). Existing
// `show(in:title:)` calls keep compiling.

@MainActor
private func allSubviews(of view: UIView) -> [UIView] {
    view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
}

@MainActor
private func labelTexts(in view: UIView) -> [String] {
    allSubviews(of: view).compactMap { ($0 as? UILabel)?.text }
}

@MainActor
private func hostedWindow(root: UIViewController) -> UIWindow {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.loadViewIfNeeded()
    window.layoutIfNeeded()
    return window
}

@MainActor
@Suite struct ProgressOverlayViewTests {
    @Test("From a controller inside a navigation controller the overlay sits on the navigation controller's view")
    func overlayOnNavigationView() {
        let content = UIViewController()
        let nav = UINavigationController(rootViewController: content)
        let window = hostedWindow(root: nav)
        defer { window.isHidden = true }

        let overlay = ProgressOverlayView.show(in: content, title: "Working")
        #expect(overlay.superview === nav.view)
        #expect(!(overlay.isDescendant(of: content.view)))
        overlay.dismiss()
    }

    @Test("The overlay frame covers the navigation bar")
    func overlayCoversNavigationBar() {
        let content = UIViewController()
        let nav = UINavigationController(rootViewController: content)
        let window = hostedWindow(root: nav)
        defer { window.isHidden = true }

        let overlay = ProgressOverlayView.show(in: content, title: "Working")
        overlay.layoutIfNeeded()
        let barFrame = nav.view.convert(nav.navigationBar.frame, from: nav.navigationBar.superview)
        #expect(overlay.frame.contains(barFrame))
        #expect(overlay.frame == nav.view.bounds)
        overlay.dismiss()
    }

    @Test("Without a navigation controller the overlay sits on the controller's own view")
    func overlayOnControllerView() {
        let content = UIViewController()
        let window = hostedWindow(root: content)
        defer { window.isHidden = true }

        let overlay = ProgressOverlayView.show(in: content, title: "Working")
        #expect(overlay.superview === content.view)
        #expect(overlay.frame == content.view.bounds)
        overlay.dismiss()
    }

    @Test("The overlay is modal for VoiceOver")
    func overlayIsAccessibilityModal() {
        let content = UIViewController()
        let window = hostedWindow(root: content)
        defer { window.isHidden = true }

        let overlay = ProgressOverlayView.show(in: content, title: "Working")
        #expect(overlay.accessibilityViewIsModal)
        overlay.dismiss()
    }

    @Test("The default style shows the title, a progress bar and the Preparing status")
    func defaultStyleShowsProgress() {
        let content = UIViewController()
        let window = hostedWindow(root: content)
        defer { window.isHidden = true }

        let overlay = ProgressOverlayView.show(in: content, title: "Working")
        let bars = allSubviews(of: overlay).compactMap { $0 as? UIProgressView }
        #expect(bars.count == 1)
        #expect(bars.first?.isHidden == false)
        #expect(labelTexts(in: overlay).contains("Working"))
        #expect(labelTexts(in: overlay).contains("Preparing..."))
        overlay.dismiss()
    }

    @Test("The no-progress style shows an activity indicator, hides the progress bar and shows the given status")
    func activityStyle() {
        let content = UIViewController()
        let window = hostedWindow(root: content)
        defer { window.isHidden = true }

        let overlay = ProgressOverlayView.show(
            in: content, title: "Exporting", style: .activity, status: "Encrypting files")
        let bars = allSubviews(of: overlay).compactMap { $0 as? UIProgressView }
        let indicators = allSubviews(of: overlay).compactMap { $0 as? UIActivityIndicatorView }
        #expect(bars.allSatisfy { $0.isHidden })
        #expect(indicators.contains { !$0.isHidden && $0.isAnimating })
        #expect(labelTexts(in: overlay).contains("Exporting"))
        #expect(labelTexts(in: overlay).contains("Encrypting files"))
        overlay.dismiss()
    }

    @Test("update changes the status line and can be called repeatedly")
    func updateRepeatedly() {
        let content = UIViewController()
        let window = hostedWindow(root: content)
        defer { window.isHidden = true }

        let overlay = ProgressOverlayView.show(in: content, title: "Working")
        overlay.update(progress: 0.25, status: "25% complete")
        overlay.update(progress: 0.5, status: "50% complete")
        overlay.update(progress: 0.5, status: "50% complete")
        #expect(labelTexts(in: overlay).contains("50% complete"))
        let bars = allSubviews(of: overlay).compactMap { $0 as? UIProgressView }
        #expect(bars.first?.progress == 0.5)
        overlay.dismiss()
    }

    @Test("dismiss removes the overlay and is safe to call repeatedly")
    func dismissRepeatedly() {
        let content = UIViewController()
        let window = hostedWindow(root: content)
        defer { window.isHidden = true }

        let overlay = ProgressOverlayView.show(in: content, title: "Working")
        overlay.dismiss()
        overlay.dismiss()
        #expect(overlay.superview == nil)
        overlay.update(progress: 1, status: "Done")
    }
}
