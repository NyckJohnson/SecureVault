import CryptoKit
import Foundation
import Testing
import os

@testable import KoalaTVault

/// A scripted in-memory Keychain: can fail chosen operations on chosen accounts, and records order.
final class ScriptedKeychain: KeychainAccessing {
    struct State: Sendable {
        var items: [String: Data] = [:]
        var accessibility: [String: KeychainAccessibility] = [:]
        var log: [String] = []
        var failWrites: [String: VaultCryptoError] = [:]
        var failReads: [String: VaultCryptoError] = [:]
        var failDeletes: [String: VaultCryptoError] = [:]
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func read(account: String, prompt: String?) throws -> Data? {
        try state.withLock { current in
            current.log.append("read:\(account):\(prompt ?? "nil")")
            if let failure = current.failReads[account] { throw failure }
            return current.items[account]
        }
    }
    func write(_ data: Data, account: String, accessibility: KeychainAccessibility) throws {
        try state.withLock { current in
            current.log.append("write:\(account)")
            if let failure = current.failWrites[account] { throw failure }
            current.items[account] = data
            current.accessibility[account] = accessibility
        }
    }
    func delete(account: String) throws {
        try state.withLock { current in
            current.log.append("delete:\(account)")
            if let failure = current.failDeletes[account] { throw failure }
            current.items[account] = nil
        }
    }
}

@Suite struct LiveMasterKeyStoreTests {
    static let blob = "com.KoalaTVault.masterKeyBlob"
    static let bio = "com.KoalaTVault.biometricMasterKey"
    static let legacy = "com.KoalaTVault.password"

    private func keyData(_ store: LiveMasterKeyStore) throws -> Data {
        try store.withKey { key in key.withUnsafeBytes { Data($0) } }
    }

    private func created(
        password: String = "pw", keychain: ScriptedKeychain = ScriptedKeychain()
    ) throws -> (LiveMasterKeyStore, ScriptedKeychain) {
        let store = LiveMasterKeyStore(keychain: keychain)
        try store.createMasterKey(password: password)
        return (store, keychain)
    }

    // MARK: createMasterKey

    @Test("Creating a master key stores a blob and loads a 32-byte key")
    func createStoresAndLoads() throws {
        let (store, keychain) = try created()
        #expect(store.isKeyLoaded)
        #expect(try keyData(store).count == 32)
        #expect(keychain.state.withLock { $0.items[Self.blob] } != nil)
        #expect(keychain.state.withLock { $0.accessibility[Self.blob] } == .whenUnlocked)
        #expect(try store.hasMasterKeyBlob())
    }

    @Test("Created keys are random")
    func createdKeysDiffer() throws {
        let (first, _) = try created()
        let (second, _) = try created()
        #expect(try keyData(first) != keyData(second))
    }

    @Test("Creating when a blob exists throws masterKeyAlreadyExists and writes nothing")
    func createWhenBlobExists() throws {
        let (_, keychain) = try created()
        let before = keychain.state.withLock { $0.items }
        keychain.state.withLock { $0.log = [] }
        let other = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.masterKeyAlreadyExists) { try other.createMasterKey(password: "x") }
        #expect(keychain.state.withLock { $0.items } == before)
        #expect(!keychain.state.withLock { $0.log }.contains { $0.hasPrefix("write:") })
        #expect(!other.isKeyLoaded)
    }

    @Test("Creating with an empty password throws emptyPassword")
    func createEmptyPassword() {
        let keychain = ScriptedKeychain()
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.emptyPassword) { try store.createMasterKey(password: "") }
        #expect(keychain.state.withLock { $0.items }.isEmpty)
        #expect(!store.isKeyLoaded)
    }

    @Test("A failing Keychain write throws keychain(status) and loads no key")
    func createWriteFails() {
        let keychain = ScriptedKeychain()
        keychain.state.withLock { $0.failWrites[Self.blob] = .keychain(-25299) }
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.keychain(-25299)) { try store.createMasterKey(password: "pw") }
        #expect(!store.isKeyLoaded)
    }

    // MARK: unlock

    @Test("Unlocking with the right password loads the same key in a new store")
    func unlockRightPassword() throws {
        let (first, keychain) = try created(password: "hunter2")
        let second = LiveMasterKeyStore(keychain: keychain)
        #expect(!second.isKeyLoaded)
        try second.unlock(password: "hunter2")
        #expect(second.isKeyLoaded)
        #expect(try keyData(first) == keyData(second))
    }

    @Test("Unlocking with a wrong password throws wrongPassword and loads nothing")
    func unlockWrongPassword() throws {
        let (_, keychain) = try created(password: "right")
        let second = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.wrongPassword) { try second.unlock(password: "wrong") }
        #expect(!second.isKeyLoaded)
    }

    @Test("A wrong password leaves an already loaded key unchanged")
    func wrongPasswordKeepsLoadedKey() throws {
        let (store, _) = try created(password: "right")
        let before = try keyData(store)
        #expect(throws: VaultCryptoError.wrongPassword) { try store.unlock(password: "wrong") }
        #expect(try keyData(store) == before)
    }

    @Test("Unlocking replaces a previously loaded key")
    func unlockReplacesLoadedKey() throws {
        let (first, keychain) = try created(password: "one")
        let stored = try keyData(first)
        // A store holding a different key, over the same keychain, unlocks to the stored key.
        let other = LiveMasterKeyStore(keychain: ScriptedKeychain())
        try other.createMasterKey(password: "other")
        #expect(try keyData(other) != stored)
        let third = LiveMasterKeyStore(keychain: keychain)
        try third.unlock(password: "one")
        try third.unlock(password: "one")
        #expect(try keyData(third) == stored)
    }

    @Test("Unlocking with no blob throws noMasterKeyBlob")
    func unlockNoBlob() {
        let store = LiveMasterKeyStore(keychain: ScriptedKeychain())
        #expect(throws: VaultCryptoError.noMasterKeyBlob) { try store.unlock(password: "pw") }
        #expect(!store.isKeyLoaded)
    }

    @Test("Unlocking deletes the legacy password item")
    func unlockDeletesLegacyItem() throws {
        let (_, keychain) = try created()
        keychain.state.withLock { $0.items[Self.legacy] = Data([1]) }
        let second = LiveMasterKeyStore(keychain: keychain)
        try second.unlock(password: "pw")
        #expect(keychain.state.withLock { $0.items[Self.legacy] } == nil)
        #expect(keychain.state.withLock { $0.log }.contains("delete:\(Self.legacy)"))
    }

    @Test("Errors deleting the legacy password item are ignored")
    func unlockIgnoresLegacyDeleteError() throws {
        let (_, keychain) = try created()
        keychain.state.withLock { $0.failDeletes[Self.legacy] = .keychain(-1) }
        let second = LiveMasterKeyStore(keychain: keychain)
        try second.unlock(password: "pw")
        #expect(second.isKeyLoaded)
    }

    @Test("A Keychain read error during unlock surfaces as keychain(status)")
    func unlockReadError() {
        let keychain = ScriptedKeychain()
        keychain.state.withLock { $0.failReads[Self.blob] = .keychain(-25308) }
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.keychain(-25308)) { try store.unlock(password: "pw") }
    }

    // MARK: rewrap

    @Test("Rewrapping keeps the key, changes the salt and swaps the password")
    func rewrapChangesPassword() throws {
        let (store, keychain) = try created(password: "old")
        let key = try keyData(store)
        let oldBlob = try #require(keychain.state.withLock { $0.items[Self.blob] })
        try store.rewrap(newPassword: "new")
        let newBlob = try #require(keychain.state.withLock { $0.items[Self.blob] })
        #expect(newBlob[5..<37] != oldBlob[5..<37])
        #expect(newBlob.count == oldBlob.count)
        #expect(try keyData(store) == key)

        let fresh = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.wrongPassword) { try fresh.unlock(password: "old") }
        try fresh.unlock(password: "new")
        #expect(try keyData(fresh) == key)
    }

    @Test("Rewrapping with no key loaded throws noKeyLoaded")
    func rewrapNoKey() {
        let keychain = ScriptedKeychain()
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.noKeyLoaded) { try store.rewrap(newPassword: "x") }
        #expect(keychain.state.withLock { $0.items }.isEmpty)
    }

    @Test("A failed rewrap write leaves the old blob intact")
    func rewrapWriteFails() throws {
        let (store, keychain) = try created(password: "old")
        let old = keychain.state.withLock { $0.items[Self.blob] }
        keychain.state.withLock { $0.failWrites[Self.blob] = .keychain(-25299) }
        #expect(throws: VaultCryptoError.keychain(-25299)) { try store.rewrap(newPassword: "new") }
        #expect(keychain.state.withLock { $0.items[Self.blob] } == old)
        let fresh = LiveMasterKeyStore(keychain: keychain)
        try fresh.unlock(password: "old")
    }

    @Test("Unlocking with an empty password throws wrongPassword and keeps the loaded key")
    func unlockEmptyPassword() throws {
        let (store, _) = try created(password: "right")
        let before = try keyData(store)
        #expect(throws: VaultCryptoError.wrongPassword) { try store.unlock(password: "") }
        #expect(store.isKeyLoaded)
        #expect(try keyData(store) == before)
    }

    @Test("Rewrapping with an empty password throws emptyPassword and leaves the old blob intact")
    func rewrapEmptyPassword() throws {
        let (store, keychain) = try created(password: "old")
        let old = keychain.state.withLock { $0.items[Self.blob] }
        #expect(throws: VaultCryptoError.emptyPassword) { try store.rewrap(newPassword: "") }
        #expect(keychain.state.withLock { $0.items[Self.blob] } == old)
        let fresh = LiveMasterKeyStore(keychain: keychain)
        try fresh.unlock(password: "old")
        #expect(fresh.isKeyLoaded)
    }

    // MARK: hasMasterKeyBlob / deleteMasterKeyBlob

    @Test("hasMasterKeyBlob is false when absent and true when present")
    func hasBlob() throws {
        let store = LiveMasterKeyStore(keychain: ScriptedKeychain())
        #expect(try !store.hasMasterKeyBlob())
        try store.createMasterKey(password: "pw")
        #expect(try store.hasMasterKeyBlob())
    }

    @Test("hasMasterKeyBlob surfaces Keychain errors")
    func hasBlobError() {
        let keychain = ScriptedKeychain()
        keychain.state.withLock { $0.failReads[Self.blob] = .keychain(-25308) }
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.keychain(-25308)) { try store.hasMasterKeyBlob() }
    }

    @Test("Deleting the blob removes it")
    func deleteBlob() throws {
        let (store, _) = try created()
        try store.deleteMasterKeyBlob()
        #expect(try !store.hasMasterKeyBlob())
    }

    @Test("Deleting an absent blob succeeds")
    func deleteBlobAbsent() throws {
        try LiveMasterKeyStore(keychain: ScriptedKeychain()).deleteMasterKeyBlob()
    }

    @Test("A Keychain failure deleting the blob surfaces as keychain(status)")
    func deleteBlobError() {
        let keychain = ScriptedKeychain()
        keychain.state.withLock { $0.failDeletes[Self.blob] = .keychain(-25308) }
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.keychain(-25308)) { try store.deleteMasterKeyBlob() }
    }

    // MARK: biometric key

    @Test("Storing the biometric key writes the raw 32-byte key with biometry accessibility")
    func storeBiometric() throws {
        let (store, keychain) = try created()
        try store.storeBiometricKey()
        let item = try #require(keychain.state.withLock { $0.items[Self.bio] })
        #expect(item == (try keyData(store)))
        #expect(item.count == 32)
        #expect(keychain.state.withLock { $0.accessibility[Self.bio] } == .biometryCurrentSetThisDeviceOnly)
    }

    @Test("Storing the biometric key with no key loaded throws noKeyLoaded")
    func storeBiometricNoKey() {
        let keychain = ScriptedKeychain()
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.noKeyLoaded) { try store.storeBiometricKey() }
        #expect(keychain.state.withLock { $0.items }.isEmpty)
    }

    @Test("Storing the biometric key replaces an old item")
    func storeBiometricReplaces() throws {
        let (store, keychain) = try created()
        keychain.state.withLock { $0.items[Self.bio] = Data([0xAA]) }
        try store.storeBiometricKey()
        #expect(keychain.state.withLock { $0.items[Self.bio] } == (try keyData(store)))
    }

    @Test("Storing the biometric key writes the biometric account and never deletes it")
    func storeBiometricWritesWithoutDeleting() throws {
        let (store, keychain) = try created()
        keychain.state.withLock { $0.log = [] }
        try store.storeBiometricKey()
        let log = keychain.state.withLock { $0.log }
        #expect(log.contains("write:\(Self.bio)"))
        #expect(!log.contains("delete:\(Self.bio)"))
        // The write-then-remove ordering for a stale item belongs to KeychainStore
        // and is not unit-testable on the simulator.
    }

    @Test("A failing biometric write leaves the old item and surfaces the error")
    func storeBiometricWriteFails() throws {
        let (store, keychain) = try created()
        keychain.state.withLock {
            $0.items[Self.bio] = Data([0xAA])
            $0.failWrites[Self.bio] = .keychain(-25299)
        }
        #expect(throws: VaultCryptoError.keychain(-25299)) { try store.storeBiometricKey() }
        #expect(keychain.state.withLock { $0.items[Self.bio] } == Data([0xAA]))
    }

    @Test("Unlocking with the biometric key loads it and passes the prompt")
    func unlockBiometric() throws {
        let (first, keychain) = try created()
        try first.storeBiometricKey()
        let second = LiveMasterKeyStore(keychain: keychain)
        try second.unlockWithBiometricKey(prompt: "Unlock please")
        #expect(try keyData(second) == keyData(first))
        #expect(keychain.state.withLock { $0.log }.contains("read:\(Self.bio):Unlock please"))
    }

    @Test("A missing biometric item throws biometricItemMissing")
    func unlockBiometricMissing() {
        let store = LiveMasterKeyStore(keychain: ScriptedKeychain())
        #expect(throws: VaultCryptoError.biometricItemMissing) { try store.unlockWithBiometricKey(prompt: "p") }
        #expect(!store.isKeyLoaded)
    }

    @Test("A biometric item that is not 32 bytes throws invalidKeyData", arguments: [0, 16, 31, 33])
    func unlockBiometricWrongLength(length: Int) {
        let keychain = ScriptedKeychain()
        keychain.state.withLock { $0.items[Self.bio] = Data(repeating: 1, count: length) }
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.invalidKeyData) { try store.unlockWithBiometricKey(prompt: "p") }
        #expect(!store.isKeyLoaded)
    }

    static let biometricErrors: [VaultCryptoError] =
        [.biometricCancelled, .biometryLockedOut, .biometryNotEnrolled]
        + [.passcodeNotSet, .biometricItemMissing, .keychain(-50)]

    @Test(
        "Biometric errors from the Keychain are reported as the matching VaultCryptoError",
        arguments: Self.biometricErrors)
    func unlockBiometricErrors(thrown: VaultCryptoError) {
        let keychain = ScriptedKeychain()
        keychain.state.withLock { $0.failReads[Self.bio] = thrown }
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: thrown) { try store.unlockWithBiometricKey(prompt: "p") }
        #expect(!store.isKeyLoaded)
    }

    @Test("A raw user-cancel status (errSecUserCanceled) maps to biometricCancelled")
    func userCancelStatusMaps() {
        let keychain = ScriptedKeychain()
        keychain.state.withLock { $0.failReads[Self.bio] = .keychain(-128) }
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.biometricCancelled) { try store.unlockWithBiometricKey(prompt: "p") }
    }

    @Test("A raw item-not-found status maps to biometricItemMissing")
    func itemNotFoundStatusMaps() {
        let keychain = ScriptedKeychain()
        keychain.state.withLock { $0.failReads[Self.bio] = .keychain(-25300) }
        let store = LiveMasterKeyStore(keychain: keychain)
        #expect(throws: VaultCryptoError.biometricItemMissing) { try store.unlockWithBiometricKey(prompt: "p") }
    }

    @Test("Deleting the biometric key removes it")
    func deleteBiometric() throws {
        let (store, keychain) = try created()
        try store.storeBiometricKey()
        try store.deleteBiometricKey()
        #expect(keychain.state.withLock { $0.items[Self.bio] } == nil)
    }

    @Test("Deleting an absent biometric key succeeds")
    func deleteBiometricAbsent() throws {
        try LiveMasterKeyStore(keychain: ScriptedKeychain()).deleteBiometricKey()
    }

    @Test("A Keychain failure deleting the biometric key surfaces as keychain(status)")
    func deleteBiometricError() {
        let keychain = ScriptedKeychain()
        keychain.state.withLock { $0.failDeletes[Self.bio] = .keychain(-25308) }
        #expect(throws: VaultCryptoError.keychain(-25308)) {
            try LiveMasterKeyStore(keychain: keychain).deleteBiometricKey()
        }
    }

    // MARK: wipeKey / withKey

    @Test("A fresh store has no key loaded")
    func freshStoreNoKey() {
        #expect(!LiveMasterKeyStore(keychain: ScriptedKeychain()).isKeyLoaded)
    }

    @Test("Wiping unloads the key and withKey then throws noKeyLoaded")
    func wipeUnloads() throws {
        let (store, _) = try created()
        store.wipeKey()
        #expect(!store.isKeyLoaded)
        #expect(throws: VaultCryptoError.noKeyLoaded) { try store.withKey { _ in 1 } }
    }

    @Test("Wiping with no key loaded is harmless")
    func wipeWhenEmpty() {
        let store = LiveMasterKeyStore(keychain: ScriptedKeychain())
        store.wipeKey()
        #expect(!store.isKeyLoaded)
    }

    @Test("withKey without a key does not run the body")
    func withKeyNoKeyDoesNotRun() {
        let store = LiveMasterKeyStore(keychain: ScriptedKeychain())
        let ran = OSAllocatedUnfairLock(initialState: false)
        #expect(throws: VaultCryptoError.noKeyLoaded) {
            try store.withKey { _ in ran.withLock { $0 = true } }
        }
        #expect(!ran.withLock { $0 })
    }

    @Test("withKey returns the body's value and propagates its errors")
    func withKeyReturnsAndPropagates() throws {
        let (store, _) = try created()
        #expect(try store.withKey { _ in 42 } == 42)
        struct Boom: Error, Equatable {}
        #expect(throws: Boom()) { try store.withKey { _ -> Int in throw Boom() } }
    }

    @Test("A body running when the key is wiped finishes with its captured key")
    func wipeDuringBody() throws {
        let (store, _) = try created()
        let expected = try keyData(store)
        let seen = try store.withKey { key -> Data in
            store.wipeKey()
            return key.withUnsafeBytes { Data($0) }
        }
        #expect(seen == expected)
        #expect(!store.isKeyLoaded)
    }
}
