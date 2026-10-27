import CommonCrypto
import CryptoKit
import Foundation
import Testing

@testable import KoalaTVault

/// Tests of the master-key blob v1 format, exercised through the store and an in-memory Keychain.
/// Layout: version 0x01 | iterations UInt32 LE | salt 32 | AES-GCM combined (header 37 bytes as AAD).
@Suite struct MasterKeyBlobTests {
    static let blobAccount = "com.KoalaTVault.masterKeyBlob"

    static func pbkdf2(_ password: String, salt: Data, iterations: Int) -> SymmetricKey {
        let passBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), passBytes.map { Int8(bitPattern: $0) }, passBytes.count,
            saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations), &out, 32)
        return SymmetricKey(data: out)
    }

    static func makeBlob(
        key: Data, password: String, iterations: Int = 100_000, version: UInt8 = 1,
        salt: Data = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    ) throws -> Data {
        var header = Data([version])
        withUnsafeBytes(of: UInt32(iterations).littleEndian) { header.append(contentsOf: $0) }
        header.append(salt)
        let wrapping = pbkdf2(password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(key, using: wrapping, authenticating: header)
        guard let combined = sealed.combined else { throw VaultCryptoError.encryptionFailed }
        return header + combined
    }

    private func unlockedKey(_ store: LiveMasterKeyStore) throws -> Data {
        try store.withKey { key in key.withUnsafeBytes { Data($0) } }
    }

    @Test("A created blob follows the v1 layout with 600,000 iterations and a 97-byte total length")
    func createdBlobLayout() throws {
        let keychain = MockKeychainAccessing()
        let store = LiveMasterKeyStore(keychain: keychain)
        try store.createMasterKey(password: "pw")
        let blob = try #require(keychain.items[Self.blobAccount])
        #expect(blob.count == 37 + 12 + 32 + 16)
        #expect(blob[0] == 1)
        let iterations = blob[1..<5].enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << (8 * UInt32($1.offset))
        }
        #expect(iterations == 600_000)
    }

    @Test("A created blob decrypts with the PBKDF2 key and its 37-byte header as AAD")
    func createdBlobUnwrapsIndependently() throws {
        let keychain = MockKeychainAccessing()
        let store = LiveMasterKeyStore(keychain: keychain)
        try store.createMasterKey(password: "pw")
        let blob = try #require(keychain.items[Self.blobAccount])
        let header = blob.prefix(37)
        let salt = blob[5..<37]
        let wrapping = Self.pbkdf2("pw", salt: Data(salt), iterations: 600_000)
        let box = try AES.GCM.SealedBox(combined: blob.suffix(from: 37))
        let key = try AES.GCM.open(box, using: wrapping, authenticating: Data(header))
        #expect(key.count == 32)
        #expect(key == (try unlockedKey(store)))
    }

    @Test("Two created blobs use different salts")
    func saltsDiffer() throws {
        let keychainOne = MockKeychainAccessing()
        let keychainTwo = MockKeychainAccessing()
        try LiveMasterKeyStore(keychain: keychainOne).createMasterKey(password: "pw")
        try LiveMasterKeyStore(keychain: keychainTwo).createMasterKey(password: "pw")
        let blobOne = try #require(keychainOne.items[Self.blobAccount])
        let blobTwo = try #require(keychainTwo.items[Self.blobAccount])
        #expect(blobOne[5..<37] != blobTwo[5..<37])
    }

    @Test("A hand-built v1 blob unlocks with the right password")
    func handBuiltBlobUnlocks() throws {
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let blob = try Self.makeBlob(key: key, password: "secret")
        let store = LiveMasterKeyStore(keychain: MockKeychainAccessing(items: [Self.blobAccount: blob]))
        try store.unlock(password: "secret")
        #expect(try unlockedKey(store) == key)
    }

    @Test("Iteration counts at the accepted bounds unlock", arguments: [100_000, 10_000_000])
    func boundaryIterationsAccepted(iterations: Int) throws {
        let key = Data(repeating: 7, count: 32)
        let blob = try Self.makeBlob(key: key, password: "pw", iterations: iterations)
        let store = LiveMasterKeyStore(keychain: MockKeychainAccessing(items: [Self.blobAccount: blob]))
        try store.unlock(password: "pw")
        #expect(try unlockedKey(store) == key)
    }

    @Test("Iteration counts outside 100,000...10,000,000 are corrupt", arguments: [0, 99_999, 10_000_001])
    func outOfBoundsIterationsCorrupt(iterations: Int) throws {
        let blob = try Self.makeBlob(key: Data(repeating: 1, count: 32), password: "pw", iterations: iterations)
        let store = LiveMasterKeyStore(keychain: MockKeychainAccessing(items: [Self.blobAccount: blob]))
        #expect(throws: VaultCryptoError.corruptBlob) { try store.unlock(password: "pw") }
        #expect(!store.isKeyLoaded)
    }

    @Test("A version other than 1 is corrupt", arguments: [UInt8(0), 2, 255])
    func wrongVersionCorrupt(version: UInt8) throws {
        let blob = try Self.makeBlob(key: Data(repeating: 1, count: 32), password: "pw", version: version)
        let store = LiveMasterKeyStore(keychain: MockKeychainAccessing(items: [Self.blobAccount: blob]))
        #expect(throws: VaultCryptoError.corruptBlob) { try store.unlock(password: "pw") }
    }

    @Test("An unwrapped key that is not 32 bytes is corrupt", arguments: [16, 31, 33, 64])
    func wrongKeyLengthCorrupt(length: Int) throws {
        let blob = try Self.makeBlob(key: Data(repeating: 1, count: length), password: "pw")
        let store = LiveMasterKeyStore(keychain: MockKeychainAccessing(items: [Self.blobAccount: blob]))
        #expect(throws: VaultCryptoError.corruptBlob) { try store.unlock(password: "pw") }
        #expect(!store.isKeyLoaded)
    }

    @Test("A truncated or empty blob is corrupt", arguments: [0, 1, 36, 37, 60])
    func truncatedBlobCorrupt(length: Int) throws {
        let full = try Self.makeBlob(key: Data(repeating: 1, count: 32), password: "pw")
        let store = LiveMasterKeyStore(
            keychain: MockKeychainAccessing(items: [Self.blobAccount: full.prefix(length)]))
        #expect(throws: VaultCryptoError.corruptBlob) { try store.unlock(password: "pw") }
    }

    @Test("A blob with a tampered header fails authentication")
    func tamperedHeaderRejected() throws {
        var blob = try Self.makeBlob(key: Data(repeating: 1, count: 32), password: "pw")
        blob[10] ^= 0xFF  // salt byte: wrapping key and AAD both change
        let store = LiveMasterKeyStore(keychain: MockKeychainAccessing(items: [Self.blobAccount: blob]))
        #expect(throws: VaultCryptoError.wrongPassword) { try store.unlock(password: "pw") }
    }

    @Test("Composed and decomposed forms of the same password unlock the same blob")
    func nfcNormalisation() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let key = Data(repeating: 5, count: 32)
        let blob = try Self.makeBlob(key: key, password: composed)
        let keychain = MockKeychainAccessing(items: [Self.blobAccount: blob])
        let composedStore = LiveMasterKeyStore(keychain: keychain)
        try composedStore.unlock(password: composed)
        let decomposedStore = LiveMasterKeyStore(keychain: keychain)
        try decomposedStore.unlock(password: decomposed)
        #expect(try unlockedKey(composedStore) == key)
        #expect(try unlockedKey(decomposedStore) == key)
    }

    @Test("A password created in decomposed form unlocks in composed form")
    func nfcNormalisationOnCreate() throws {
        let keychain = MockKeychainAccessing()
        try LiveMasterKeyStore(keychain: keychain).createMasterKey(password: "e\u{0301}")
        let other = LiveMasterKeyStore(keychain: keychain)
        try other.unlock(password: "\u{00E9}")
        #expect(other.isKeyLoaded)
    }
}
