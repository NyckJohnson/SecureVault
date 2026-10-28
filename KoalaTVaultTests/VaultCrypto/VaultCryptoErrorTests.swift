import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultCryptoErrorTests {
    private static func cases() -> [(VaultCryptoError, String)] {
        var table: [(VaultCryptoError, String)] = []
        table.append((.noKeyLoaded, "No encryption key is loaded."))
        table.append((.noMasterKeyBlob, "No password has been set up."))
        table.append((.masterKeyAlreadyExists, "A master key already exists."))
        table.append((.wrongPassword, "Incorrect password."))
        table.append((.emptyPassword, "Password cannot be empty."))
        table.append((.corruptBlob, "The stored password data is damaged."))
        table.append((.invalidKeyData, "The stored key is invalid."))
        table.append((.encryptionFailed, "Encryption failed."))
        table.append((.decryptionFailed, "Decryption failed. The data may be damaged."))
        table.append((.biometricItemMissing, "Face ID key not found. Use your password."))
        table.append((.biometricCancelled, "Authentication was cancelled."))
        table.append((.biometryLockedOut, "Too many attempts. Use your password."))
        table.append((.biometryNotEnrolled, "Face ID is not set up."))
        table.append((.passcodeNotSet, "Set a device passcode to use Face ID."))
        return table
    }

    /// Reads `errorDescription` through the LocalizedError protocol.
    private static func described(_ error: VaultCryptoError) -> String? {
        let erased: any Error = error
        return (erased as? any LocalizedError)?.errorDescription
    }

    @Test("errorDescription and localizedDescription equal the memo text", arguments: VaultCryptoErrorTests.cases())
    func descriptionMatchesMemo(error: VaultCryptoError, expected: String) {
        #expect(Self.described(error) == expected)
        #expect(error.localizedDescription == expected)
    }

    @Test("keychain error text names the status number", arguments: [-25300, -34018, -1, 0])
    func keychainDescriptionContainsStatus(status: Int) {
        let error = VaultCryptoError.keychain(OSStatus(status))
        let expected = "Couldn't access secure storage (error \(status))."
        #expect(Self.described(error) == expected)
        #expect(error.localizedDescription == expected)
        #expect(error.localizedDescription.contains(String(status)))
    }
}
