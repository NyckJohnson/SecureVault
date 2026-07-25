//
//  ErrorPresenting.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/20/26.
//

import UIKit

protocol ErrorPresenting: UIViewController {
    func showError(_ error: Error)
    func showError(_ message: String)
    func showSuccess(_ message: String)
}

extension ErrorPresenting {
    func showError(_ error: Error) {
        showError(error.localizedDescription)
    }

    func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func showSuccess(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
