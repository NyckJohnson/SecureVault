import Combine
import Foundation

/// A choice on the setup wizard.
enum SetupWizardOption: Sendable, Equatable, CaseIterable {
    case none, password, passwordAndBiometrics

    fileprivate var lockMode: LockMode {
        switch self {
        case .none: .none
        case .password: .password
        case .passwordAndBiometrics: .passwordAndBiometrics
        }
    }
}

extension BiometricKind {
    /// The biometric name the lock screens show; "Biometrics" on a device without biometric hardware.
    var lockScreensDisplayName: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .none: "Biometrics"
        }
    }
}

/// The logic of the first-launch wizard: choose a lock mode, enter a password for the password modes,
/// set the lock up, and mark setup complete.
@MainActor
final class SetupWizardViewModel: ObservableObject {
    /// The chosen option; No Lock until the user picks another.
    @Published private(set) var selectedOption: SetupWizardOption = .none
    /// True when the view should ask for a password and its confirmation.
    @Published private(set) var isPasswordPromptVisible = false
    /// True while the lock is being set up.
    @Published private(set) var isBusy = false
    /// The message to show, if the last step failed.
    @Published private(set) var errorMessage: String?
    /// True once the lock is set up and setup is marked complete.
    @Published private(set) var isFinished = false
    /// Called once setup succeeds.
    var onFinished: (@MainActor () -> Void)?

    private let lock: any VaultLocking
    private let preferences: any PreferencesStoring

    /// - Parameters:
    ///   - lock: the app's vault lock, which sets up the chosen mode.
    ///   - preferences: where setup is marked complete.
    init(lock: any VaultLocking, preferences: any PreferencesStoring) {
        self.lock = lock
        self.preferences = preferences
    }

    /// The option's title; the biometric one names the device's biometric kind.
    func title(for option: SetupWizardOption) -> String {
        switch option {
        case .none: "No Lock"
        case .password: "Password"
        case .passwordAndBiometrics: "Password + \(lock.biometricKind.lockScreensDisplayName)"
        }
    }

    /// Whether the option can be chosen: the biometric one needs biometrics.
    func isEnabled(_ option: SetupWizardOption) -> Bool {
        option != .passwordAndBiometrics || lock.biometricsAvailable
    }

    /// Chooses the option, if it is enabled.
    func select(_ option: SetupWizardOption) {
        guard isEnabled(option) else { return }
        selectedOption = option
    }

    /// No Lock sets up right away; the password modes ask for a password first.
    func continueTapped() async {
        guard !isBusy else { return }
        if selectedOption == .none {
            await setUp(password: nil)
        } else {
            errorMessage = nil
            isPasswordPromptVisible = true
        }
    }

    /// Closes the password prompt without setting anything up.
    func cancelPasswordPrompt() {
        isPasswordPromptVisible = false
    }

    /// Closes the prompt and sets up the chosen password mode, unless the password is empty or the
    /// confirmation differs.
    func submitPassword(_ password: String, confirmation: String) async {
        guard !isBusy else { return }
        isPasswordPromptVisible = false
        guard !password.isEmpty else {
            errorMessage = VaultLockError.emptyPassword.localizedDescription
            return
        }
        guard password == confirmation else {
            errorMessage = "Passwords do not match"
            return
        }
        await setUp(password: password)
    }

    private func setUp(password: String?) async {
        fatalError("Not implemented: SetupWizardViewModel.setUp (feature multiple-vaults-duress-password)")
    }
}
