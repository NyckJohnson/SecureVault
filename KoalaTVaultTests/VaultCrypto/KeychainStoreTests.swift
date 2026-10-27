import Foundation
import LocalAuthentication
import Security
import Testing

@testable import KoalaTVault

/// The live Keychain seam, using a unique service per test so nothing shared is touched.
@Suite struct KeychainStoreTests {
    private func makeStore() -> KeychainStore {
        KeychainStore(service: "com.KoalaTVault.tests.\(UUID().uuidString)")
    }

    @Test("Reading an absent item returns nil")
    func readAbsentReturnsNil() throws {
        let store = makeStore()
        #expect(try store.read(account: "a", prompt: nil) == nil)
    }

    @Test("A written item reads back with the same data")
    func writeThenRead() throws {
        let store = makeStore()
        defer { try? store.delete(account: "a") }
        let data = Data([1, 2, 3, 4])
        try store.write(data, account: "a", accessibility: .whenUnlocked)
        #expect(try store.read(account: "a", prompt: nil) == data)
    }

    @Test("Writing an existing account replaces its data")
    func writeReplaces() throws {
        let store = makeStore()
        defer { try? store.delete(account: "a") }
        try store.write(Data([1]), account: "a", accessibility: .whenUnlocked)
        try store.write(Data([2, 2]), account: "a", accessibility: .whenUnlocked)
        #expect(try store.read(account: "a", prompt: nil) == Data([2, 2]))
    }

    @Test("Accounts are independent items")
    func accountsAreIndependent() throws {
        let store = makeStore()
        defer {
            try? store.delete(account: "a")
            try? store.delete(account: "b")
        }
        try store.write(Data([1]), account: "a", accessibility: .whenUnlocked)
        try store.write(Data([2]), account: "b", accessibility: .whenUnlocked)
        #expect(try store.read(account: "a", prompt: nil) == Data([1]))
        #expect(try store.read(account: "b", prompt: nil) == Data([2]))
    }

    @Test("Deleting removes the item")
    func deleteRemoves() throws {
        let store = makeStore()
        try store.write(Data([9]), account: "a", accessibility: .whenUnlocked)
        try store.delete(account: "a")
        #expect(try store.read(account: "a", prompt: nil) == nil)
    }

    @Test("Deleting an absent item is not an error")
    func deleteAbsentSucceeds() throws {
        let store = makeStore()
        try store.delete(account: "never-written")
    }

    @Test("Items in different services do not see each other")
    func servicesAreIsolated() throws {
        let one = makeStore()
        let two = makeStore()
        defer { try? one.delete(account: "a") }
        try one.write(Data([1]), account: "a", accessibility: .whenUnlocked)
        #expect(try two.read(account: "a", prompt: nil) == nil)
    }

    @Test("Deleting removes a legacy item that has no service attribute")
    func deleteRemovesUnscopedLegacyItem() throws {
        let account = "com.KoalaTVault.password"
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        var add = match
        add[kSecValueData as String] = Data([7])
        let status = SecItemAdd(add as CFDictionary, nil)
        defer { SecItemDelete(match as CFDictionary) }
        try #require(status == errSecSuccess)

        try makeStore().delete(account: account)

        var query = match
        query[kSecReturnData as String] = true
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
    }

    static let laMappings: [(code: Int, error: VaultCryptoError?)] = [
        (LAError.userCancel.rawValue, .biometricCancelled),
        (LAError.userFallback.rawValue, .biometricCancelled),
        (LAError.systemCancel.rawValue, .biometricCancelled),
        (LAError.appCancel.rawValue, .biometricCancelled),
        (LAError.passcodeNotSet.rawValue, .passcodeNotSet),
        (LAError.biometryNotEnrolled.rawValue, .biometryNotEnrolled),
        (LAError.biometryLockout.rawValue, .biometryLockedOut),
        (-9999, nil),
    ]

    // biometryNotAvailable (-6) is left out: the spec does not say how it maps.
    @Test("LocalAuthentication codes map to the matching VaultCryptoError", arguments: laMappings)
    func laCodeMapping(code: Int, error: VaultCryptoError?) {
        #expect(KeychainStore.map(laCode: code) == error)
    }
}
