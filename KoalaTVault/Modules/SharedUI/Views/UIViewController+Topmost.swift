import UIKit

extension UIViewController {
    /// The controller at the end of the `presentedViewController` chain starting at this controller
    /// (this controller itself when nothing is presented).
    var topmostPresentedController: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController {
            top = next
        }
        return top
    }
}
