import Combine
import Foundation

/// The logic of the lock screen: unlock with the password or biometrics, and the messages for failures.
@MainActor
final class LockScreenViewModel: ObservableObject {
    /// The password field's text.
    @Published private(set) var password = ""
    /// True while an unlock runs; the unlock button is disabled.
    @Published private(set) var isBusy = false
    /// The message to show, if the last attempt failed.
    @Published private(set) var errorMessage: String?
    /// Called after a successful unlock.
    var onUnlocked: (@MainActor () -> Void)?

    private let lock: any VaultLocking
    private let preferences: any PreferencesStoring
    private var hasAttemptedAutomaticBiometrics = false

    /// - Parameters:
    ///   - lock: the app's vault lock.
    ///   - preferences: read for a pending encrypt migration.
    init(lock: any VaultLocking, preferences: any PreferencesStoring) {
        self.lock = lock
        self.preferences = preferences
    }

    /// True in biometric mode with biometrics available.
    var showsBiometricButton: Bool {
        fatalError(
            "Not implemented: LockScreenViewModel.showsBiometricButton (feature multiple-vaults-duress-password)")
    }

    /// The biometric button's title, naming the device's biometric kind.
    var biometricButtonTitle: String {
        "Use \(lock.biometricKind.lockScreensDisplayName)"
    }

    /// True unless the biometric prompt is going to start.
    var focusesPasswordField: Bool {
        !showsBiometricButton
    }

    /// The user changed the password field; any error clears.
    func passwordEdited(_ text: String) {
        password = text
        errorMessage = nil
    }

    /// Runs the automatic biometric attempt, the first time only.
    func sceneDidBecomeActive() async {
        guard showsBiometricButton, !hasAttemptedAutomaticBiometrics else { return }
        hasAttemptedAutomaticBiometrics = true
        await biometricTapped()
    }

    /// Unlocks with biometrics. A cancelled prompt shows nothing.
    func biometricTapped() async {
        fatalError("Not implemented: LockScreenViewModel.biometricTapped (feature multiple-vaults-duress-password)")
    }

    /// Unlocks with the field's password; an empty one is ignored.
    func unlockTapped() async {
        fatalError("Not implemented: LockScreenViewModel.unlockTapped (feature multiple-vaults-duress-password)")
    }

    /// An encrypt migration can be pending with no lock mode saved. The lock is added as `.password`
    /// whatever the record's target: the migration switches to the target at its end.
    private var needsPendingLock: Bool {
        fatalError("Not implemented: LockScreenViewModel.needsPendingLock (feature multiple-vaults-duress-password)")
    }

    private func biometricMessage(for error: any Error) -> String? {
        let name = lock.biometricKind.lockScreensDisplayName
        switch error as? VaultLockError {
        case .biometricCancelled: return nil
        case .biometryLockedOut: return "Too many attempts. Use your password."
        case .biometryNotEnrolled: return "\(name) is not set up."
        case .passcodeNotSet: return "Set a device passcode to use \(name)."
        case .biometricChanged: return "\(name) changed. Use your password."
        default: return "Biometric authentication failed"
        }
    }

    /// Every failure message also empties the field, as the app has always done.
    private func show(_ message: String) {
        errorMessage = message
        password = ""
    }
}
