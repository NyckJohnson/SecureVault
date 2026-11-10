import UIKit

extension UIViewController {
    /// The controller at the end of the `presentedViewController` chain starting at this controller
    /// (this controller itself when nothing is presented). The walk stops before a controller that is
    /// being dismissed, so something presented right after a sheet closes isn't presented on it and lost.
    var topmostPresentedController: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }
}
