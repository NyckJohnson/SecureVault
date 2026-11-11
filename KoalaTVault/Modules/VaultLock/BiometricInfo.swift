import Foundation
import LocalAuthentication

/// Asks the device which biometric type it has and whether biometrics can be evaluated right now.
protocol BiometricProbing: Sendable {
    /// The biometric hardware type and whether it can be used now (enrolled, not locked out).
    func probe() -> (kind: BiometricKind, canEvaluate: Bool)
}

/// The device's biometrics, re-probed on every read so enrollment changes show up.
struct BiometricInfo: Sendable {
    private let prober: any BiometricProbing

    /// Biometric information answered by `probe`.
    init(probe: any BiometricProbing) {
        prober = probe
    }

    /// The device's biometric type.
    var kind: BiometricKind { prober.probe().kind }

    /// Whether biometrics can be evaluated now.
    var isAvailable: Bool { prober.probe().canEvaluate }
}

/// The live probe: a fresh `LAContext` per call, so the answer reflects the current enrollment.
struct LiveBiometricProbe: BiometricProbing {
    // coverage-exempt-begin: real LAContext probe; tests use FakeBiometricProbe
    func probe() -> (kind: BiometricKind, canEvaluate: Bool) {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        // `biometryType` is only set after `canEvaluatePolicy` has run.
        let kind: BiometricKind
        switch context.biometryType {
        case .faceID: kind = .faceID
        case .touchID: kind = .touchID
        default: kind = .none
        }
        return (kind, canEvaluate)
    }
    // coverage-exempt-end
}
