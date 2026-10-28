//
//  ErrorPresenting.swift
//  KoalaTVault
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
        showError(legacyErrorMessage(for: error))
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

/// The text the legacy screens show for `error`. `VaultStoreError` keeps the wording the legacy app
/// showed for the same failures; any other error shows its `localizedDescription`.
func legacyErrorMessage(for error: Error) -> String {
    guard let storeError = error as? VaultStoreError else { return error.localizedDescription }
    switch storeError {
    case .indexUnreadable:
        return "Couldn't read the vault's file index. It may still be locked, or a file may have become corrupted."
    case .locked:
        return VaultCryptoError.noKeyLoaded.localizedDescription
    case .invalidName:
        return "Names can't contain / or start with ."
    case .notFound:
        return "This item no longer exists."
    case .moveIntoItself:
        return "A folder can't be moved into itself"
    case .stillEncrypted(let count):
        return "\(count) file\(count == 1 ? " is" : "s are") still encrypted."
    case .io(let message):
        return message
    }
}
