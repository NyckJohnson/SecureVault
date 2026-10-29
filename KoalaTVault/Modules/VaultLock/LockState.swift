import Foundation

extension LockState {
    /// Derives the lock state: no lock is `.open`; a lock without a loaded key is `.locked`;
    /// a lock with the key loaded is `.unlocked`.
    init(lockMode: LockMode, keyLoaded: Bool) {
        if lockMode == .none {
            self = .open
        } else {
            self = keyLoaded ? .unlocked : .locked
        }
    }
}
