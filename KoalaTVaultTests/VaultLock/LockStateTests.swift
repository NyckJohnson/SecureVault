import Testing

@testable import KoalaTVault

/// Assumes `LockState.init(lockMode:keyLoaded:)` in LockState.swift derives the state.
@Suite struct LockStateTests {
    @Test("No lock is open whether or not a key is loaded", arguments: [true, false])
    func noLockIsOpen(keyLoaded: Bool) {
        #expect(LockState(lockMode: .none, keyLoaded: keyLoaded) == .open)
    }

    @Test("A lock with no key loaded is locked", arguments: [LockMode.password, .passwordAndBiometrics])
    func lockWithoutKeyIsLocked(mode: LockMode) {
        #expect(LockState(lockMode: mode, keyLoaded: false) == .locked)
    }

    @Test("A lock with the key loaded is unlocked", arguments: [LockMode.password, .passwordAndBiometrics])
    func lockWithKeyIsUnlocked(mode: LockMode) {
        #expect(LockState(lockMode: mode, keyLoaded: true) == .unlocked)
    }
}
