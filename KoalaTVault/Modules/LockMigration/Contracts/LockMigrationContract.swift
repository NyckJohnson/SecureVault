import Foundation

// coverage-exempt-file: declarations only

/// Where the encryption of an opened vault's leftover plaintext files is.
enum MigrationPhase: Sendable, Equatable {
    case idle
    case running(done: Int, total: Int)
    case failed(names: [String])
    case completed(fully: Bool)
    /// The run stopped because the trash holds items that can never be decrypted; awaits Clear or Skip.
    case unreadableTrash
}

/// Encrypts the files an encrypted vault still holds unencrypted, when it opens.
@MainActor
protocol LockMigrating: AnyObject, Sendable {
    /// The current phase.
    var phase: MigrationPhase { get }
    /// Each change of `phase`.
    func phaseUpdates() -> AsyncStream<MigrationPhase>
    /// Encrypts the plaintext files left in `store` (an encrypted vault), one at a time.
    func encryptLeftovers(in store: any VaultStoring) async
    /// Encrypts the failed files again.
    func retryFailed() async
    /// Gives up on the failed files.
    func skipFailed() async
    /// From `.unreadableTrash` only: clears the unreadable trash, then continues from a fresh listing;
    /// a clearing failure (not a lock) → `.failed(names: [])`.
    func clearUnreadableTrash() async
    /// Stops the run after the file in progress (the vault closed); the phase becomes `.idle`.
    func cancel()
}
