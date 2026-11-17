import Foundation

/// The open vault (`current`) and its publishing (feature multiple-vaults-duress-password; replaces the
/// lock-mode `LockState`). Each change of `current` (to a vault with another ID) is published once to every
/// subscriber; subscribers read `current` first, so nothing is sent on subscribing.
@MainActor
final class OpenVaultState {
    /// The open vault.
    private(set) var current: OpenVault

    private var continuations: [UUID: AsyncStream<OpenVault>.Continuation] = [:]

    /// A state whose `current` starts as `initial`.
    init(initial: OpenVault) {
        current = initial
    }

    /// Each later change of `current`, once, in order.
    func updates() -> AsyncStream<OpenVault> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<OpenVault>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { _ in
            Task { @MainActor [weak self] in self?.continuations[id] = nil }
        }
        return stream
    }

    /// Makes `vault` current and publishes it, unless it is already current (same ID).
    func set(_ vault: OpenVault) {
        guard vault.id != current.id else { return }
        current = vault
        for continuation in continuations.values { continuation.yield(vault) }
    }
}
