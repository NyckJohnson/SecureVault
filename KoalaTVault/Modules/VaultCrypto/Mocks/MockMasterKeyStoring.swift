import CryptoKit
import Foundation
import os

/// A master-key store that keeps its password and key in memory; records every call.
final class MockMasterKeyStoring: MasterKeyStoring {
    /// A recorded call.
    enum Call: Equatable, Sendable {
        case hasMasterKeyBlob, createMasterKey, unlock, rewrap, deleteMasterKeyBlob
        case storeBiometricKey, unlockWithBiometricKey(prompt: String), deleteBiometricKey, wipeKey, withKey
    }

    private struct State: Sendable {
        var password: String?
        var keyData: Data?
        var hasBiometricKey = false
        var calls: [Call] = []
        var errorToThrow: VaultCryptoError?
    }

    private let state: OSAllocatedUnfairLock<State>

    /// A store whose blob is wrapped by `password` (nil: no blob), optionally with the key loaded.
    init(password: String? = "correct horse", keyLoaded: Bool = false, hasBiometricKey: Bool = false) {
        let keyData = keyLoaded ? Data(repeating: 0x2A, count: 32) : nil
        state = OSAllocatedUnfairLock(
            initialState: State(
                password: password, keyData: keyData, hasBiometricKey: hasBiometricKey))
    }

    /// Every call so far, in order.
    var calls: [Call] { state.withLock { $0.calls } }

    /// When set, every throwing call throws this error.
    var errorToThrow: VaultCryptoError? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    var isKeyLoaded: Bool { state.withLock { $0.keyData != nil } }

    func hasMasterKeyBlob() throws -> Bool {
        try record(.hasMasterKeyBlob) { $0.password != nil }
    }

    func createMasterKey(password: String) throws {
        try record(.createMasterKey) { state in
            guard !password.isEmpty else { throw VaultCryptoError.emptyPassword }
            guard state.password == nil else { throw VaultCryptoError.masterKeyAlreadyExists }
            state.password = password
            state.keyData = Data(repeating: 0x2A, count: 32)
        }
    }

    func unlock(password: String) throws {
        try record(.unlock) { state in
            guard let stored = state.password else { throw VaultCryptoError.noMasterKeyBlob }
            guard stored == password else { throw VaultCryptoError.wrongPassword }
            state.keyData = Data(repeating: 0x2A, count: 32)
        }
    }

    func rewrap(newPassword: String) throws {
        try record(.rewrap) { state in
            guard state.keyData != nil else { throw VaultCryptoError.noKeyLoaded }
            state.password = newPassword
        }
    }

    func deleteMasterKeyBlob() throws {
        try record(.deleteMasterKeyBlob) { $0.password = nil }
    }

    func storeBiometricKey() throws {
        try record(.storeBiometricKey) { state in
            guard state.keyData != nil else { throw VaultCryptoError.noKeyLoaded }
            state.hasBiometricKey = true
        }
    }

    func unlockWithBiometricKey(prompt: String) throws {
        try record(.unlockWithBiometricKey(prompt: prompt)) { state in
            guard state.hasBiometricKey else { throw VaultCryptoError.biometricItemMissing }
            state.keyData = Data(repeating: 0x2A, count: 32)
        }
    }

    func deleteBiometricKey() throws {
        try record(.deleteBiometricKey) { $0.hasBiometricKey = false }
    }

    func wipeKey() {
        state.withLock { state in
            state.calls.append(.wipeKey)
            state.keyData = nil
        }
    }

    func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        let keyData = try record(.withKey) { state in
            guard let keyData = state.keyData else { throw VaultCryptoError.noKeyLoaded }
            return keyData
        }
        return try body(SymmetricKey(data: keyData))
    }

    private func record<R: Sendable>(_ call: Call, _ body: @Sendable (inout State) throws -> R) throws -> R {
        try state.withLock { state in
            state.calls.append(call)
            if let error = state.errorToThrow { throw error }
            return try body(&state)
        }
    }
}
