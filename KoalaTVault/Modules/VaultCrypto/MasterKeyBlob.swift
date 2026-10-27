import CommonCrypto
import CryptoKit
import Foundation

/// The master-key blob v1 format (kept byte-compatible with what earlier app versions wrote).
///
/// Layout: version `0x01` | PBKDF2 iterations `UInt32` little-endian | salt (32 bytes) |
/// AES-GCM combined (nonce 12 | ciphertext | tag 16) of the 32-byte master key, with the
/// 37-byte header authenticated as AAD. The wrapping key is PBKDF2-HMAC-SHA256 of the
/// NFC-normalised UTF-8 password.
enum MasterKeyBlob {
    /// The only blob version this format reads and writes.
    static let version: UInt8 = 1
    /// Iterations written into new blobs (OWASP 2023 guidance for PBKDF2-HMAC-SHA256).
    static let writeIterations: UInt32 = 600_000
    /// Iteration counts accepted when reading; the cap keeps a corrupt blob from hanging unlock.
    static let acceptedIterations: ClosedRange<UInt32> = 100_000...10_000_000
    /// Length of the random salt.
    static let saltSize = 32
    /// Length of the header (version + iterations + salt), authenticated as AAD.
    static let headerSize = 1 + 4 + saltSize
    /// Length of the wrapped master key.
    static let keySize = 32

    /// Wraps `key` with `password` into a new v1 blob with a fresh random salt.
    /// - Throws: `.emptyPassword` for an empty password, `.encryptionFailed` if randomness,
    ///   derivation or sealing fails.
    static func seal(_ key: SymmetricKey, password: String) throws -> Data {
        guard !password.isEmpty else { throw VaultCryptoError.emptyPassword }
        let salt = try randomBytes(count: saltSize)
        var header = Data([version])
        withUnsafeBytes(of: writeIterations.littleEndian) { header.append(contentsOf: $0) }
        header.append(salt)

        let wrappingKey = try deriveKey(password: password, salt: salt, iterations: writeIterations)
        var keyData = key.withUnsafeBytes { Data($0) }
        defer { zero(&keyData) }
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(keyData, using: wrappingKey, authenticating: header)
        } catch {
            throw VaultCryptoError.encryptionFailed // coverage-exempt: AES-GCM seal of a 32-byte key does not fail
        }
        guard let combined = sealed.combined else { throw VaultCryptoError.encryptionFailed }
        return header + combined
    }

    /// Unwraps the master key from `blob` with `password`.
    /// - Throws: `.corruptBlob` for a short blob, a version other than 1, iterations outside
    ///   `acceptedIterations`, a malformed sealed box or an unwrapped key that is not 32 bytes;
    ///   `.wrongPassword` when authentication fails (wrong password, empty password or a
    ///   tampered blob); `.encryptionFailed` if key derivation itself fails.
    static func open(_ rawBlob: Data, password: String) throws -> SymmetricKey {
        // Rebase so indices start at 0 whatever slice the caller passed.
        let blob = Data(rawBlob)
        guard blob.count > headerSize, blob[0] == version else { throw VaultCryptoError.corruptBlob }
        let header = blob.subdata(in: 0..<headerSize)
        let iterations = blob[1..<5].enumerated().reduce(UInt32(0)) { result, byte in
            result | UInt32(byte.element) << (8 * UInt32(byte.offset))
        }
        guard acceptedIterations.contains(iterations) else { throw VaultCryptoError.corruptBlob }
        let salt = blob.subdata(in: 5..<headerSize)
        guard let box = try? AES.GCM.SealedBox(combined: blob.subdata(in: headerSize..<blob.count)) else {
            throw VaultCryptoError.corruptBlob
        }
        // Creation never accepts an empty password, so one can never be right.
        guard !password.isEmpty else { throw VaultCryptoError.wrongPassword }

        let wrappingKey = try deriveKey(password: password, salt: salt, iterations: iterations)
        var keyData: Data
        do {
            keyData = try AES.GCM.open(box, using: wrappingKey, authenticating: header)
        } catch CryptoKitError.authenticationFailure {
            throw VaultCryptoError.wrongPassword
        } catch {
            throw VaultCryptoError.corruptBlob
        }
        defer { zero(&keyData) }
        guard keyData.count == keySize else { throw VaultCryptoError.corruptBlob }
        return SymmetricKey(data: keyData)
    }

    /// PBKDF2-HMAC-SHA256 of the NFC-normalised UTF-8 password, 32 bytes.
    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var passwordData = Data(password.precomposedStringWithCanonicalMapping.utf8)
        defer { zero(&passwordData) }
        var derived = Data(count: keySize)
        defer { zero(&derived) }
        let passwordCount = passwordData.count
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), passwordCount,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), derivedBytes.count)
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw VaultCryptoError.encryptionFailed }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status: OSStatus = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else { throw VaultCryptoError.encryptionFailed }
        return data
    }

    /// Overwrites `data` with zeros so key material does not linger in memory.
    static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }
}
