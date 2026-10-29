import Testing

@testable import KoalaTVault

/// Assumes `protocol BiometricProbing: Sendable { func probe() -> (kind: BiometricKind, canEvaluate: Bool) }`
/// and `struct BiometricInfo { init(probe: any BiometricProbing); var kind: BiometricKind; var isAvailable: Bool }`
/// in BiometricInfo.swift; the live probe wraps LAContext and is never used in tests.
@Suite struct BiometricInfoTests {
    @Test("Face ID that can be evaluated is available as faceID")
    func faceIDAvailable() {
        let info = BiometricInfo(probe: FakeBiometricProbe(kind: .faceID, canEvaluate: true))
        #expect(info.kind == .faceID)
        #expect(info.isAvailable)
    }

    @Test("Touch ID that can be evaluated is available as touchID")
    func touchIDAvailable() {
        let info = BiometricInfo(probe: FakeBiometricProbe(kind: .touchID, canEvaluate: true))
        #expect(info.kind == .touchID)
        #expect(info.isAvailable)
    }

    @Test("A device without biometrics reports none and unavailable")
    func noBiometrics() {
        let info = BiometricInfo(probe: FakeBiometricProbe(kind: .none, canEvaluate: false))
        #expect(info.kind == .none)
        #expect(!info.isAvailable)
    }

    @Test(
        "Biometrics that cannot be evaluated are unavailable even when the hardware has a kind",
        arguments: [BiometricKind.faceID, .touchID])
    func cannotEvaluateIsUnavailable(kind: BiometricKind) {
        let info = BiometricInfo(probe: FakeBiometricProbe(kind: kind, canEvaluate: false))
        #expect(!info.isAvailable)
    }

    @Test("Availability is re-evaluated on every read so enrollment changes show up")
    func reevaluatesEachRead() {
        let probe = FakeBiometricProbe(kind: .faceID, canEvaluate: false)
        let info = BiometricInfo(probe: probe)
        #expect(!info.isAvailable)
        probe.canEvaluate = true
        #expect(info.isAvailable)
        #expect(probe.probeCount >= 2)
    }
}
