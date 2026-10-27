import CryptoKit
import Foundation

// coverage-exempt-file: declarations only

/// Errors thrown by the master-key store and the file cipher.
enum VaultCryptoError: Error, Equatable, Sendable {
    case noKeyLoaded, noMasterKeyBlob, masterKeyAlreadyExists, wrongPassword, emptyPassword
    case corruptBlob, invalidKeyData, encryptionFailed, decryptionFailed
    case biometricItemMissing, biometricCancelled, biometryLockedOut, biometryNotEnrolled, passcodeNotSet
    case keychain(OSStatus)
}

/// When a Keychain item can be read.
enum KeychainAccessibility: Sendable {
    case whenUnlocked, biometryCurrentSetThisDeviceOnly
}

/// Seam over the Keychain (generic password items in one service); tests use an in-memory fake.
protocol KeychainAccessing: Sendable {
    /// The item's data, or nil when absent; `prompt` is shown for a biometric-protected item.
    func read(account: String, prompt: String?) throws -> Data?
    /// Writes (adds or replaces) the item with the given accessibility.
    func write(_ data: Data, account: String, accessibility: KeychainAccessibility) throws
    /// Deletes the item; an absent item is not an error.
    func delete(account: String) throws
}

/// The vault master key: in memory, password-wrapped in the Keychain blob, and in the biometric item.
protocol MasterKeyStoring: Sendable {
    /// Whether a master key is loaded in memory.
    var isKeyLoaded: Bool { get }
    /// Whether the password-wrapped blob exists in the Keychain.
    func hasMasterKeyBlob() throws -> Bool
    /// Creates a new random master key, stores it wrapped by `password` and loads it.
    func createMasterKey(password: String) throws
    /// Unwraps the blob with `password` and loads the key.
    func unlock(password: String) throws
    /// Re-wraps the loaded key with `newPassword`.
    func rewrap(newPassword: String) throws
    /// Deletes the password-wrapped blob.
    func deleteMasterKeyBlob() throws
    /// Stores the loaded key in the biometric Keychain item.
    func storeBiometricKey() throws
    /// Loads the key from the biometric item, showing `prompt`.
    func unlockWithBiometricKey(prompt: String) throws
    /// Deletes the biometric Keychain item.
    func deleteBiometricKey() throws
    /// Unloads the key from memory.
    func wipeKey()
    /// Runs `body` with the key captured once; a later wipe doesn't affect the running body.
    func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T
}

/// The header facts of an SVC5 file needed to stream it.
struct StreamInfo: Sendable, Equatable {
    let totalSize: Int
    let chunkSize: Int
}

/// Encryption of small data (indexes) and of whole files in the SVC5 format.
protocol FileCipher: Sendable {
    /// Encrypts `data` with the master key, bound to `context` (AAD).
    func encrypt(_ data: Data, context: String) throws -> Data
    /// Decrypts `data`, trying each context in order.
    func decrypt(_ data: Data, contexts: [String]) throws -> Data
    /// Encrypts the file at `source` into an SVC5 file at `destination`.
    func encryptFile(at source: URL, to destination: URL) throws
    /// Decrypts the SVC5 file at `source` into `destination`.
    func decryptFile(at source: URL, to destination: URL) throws
    /// Reads the SVC5 header of the file at `url`.
    func streamInfo(of url: URL) throws -> StreamInfo
    /// Decrypts one chunk of the SVC5 file at `url`.
    func decryptChunk(_ index: Int, of url: URL, info: StreamInfo) throws -> Data
}
