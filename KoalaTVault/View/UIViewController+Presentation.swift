//
//  UIViewController+Presentation.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 10/2/26.
//

import UIKit

extension UIViewController {
    /// This controller followed by each controller presented on top of it, in order.
    var presentationChain: [UIViewController] {
        var chain = [self]
        while let next = chain.last?.presentedViewController {
            chain.append(next)
        }
        return chain
    }

    /// The controller at the top of the presentation chain (self if nothing is presented).
    var topmostPresented: UIViewController {
        presentationChain.last ?? self
    }
}
