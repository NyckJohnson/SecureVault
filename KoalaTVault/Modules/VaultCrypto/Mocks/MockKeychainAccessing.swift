import Foundation
import os

/// An in-memory Keychain for previews and tests; records every call.
final class MockKeychainAccessing: KeychainAccessing {
    /// A recorded call.
    enum Call: Equatable, Sendable {
        case read(account: String, prompt: String?)
        case write(account: String, accessibility: KeychainAccessibility)
        case delete(account: String)
    }

    private struct State: Sendable {
        var items: [String: Data]
        var calls: [Call] = []
        var errorToThrow: VaultCryptoError?
    }

    private let state: OSAllocatedUnfairLock<State>

    /// A Keychain holding `items`, keyed by account.
    init(items: [String: Data] = [:]) {
        state = OSAllocatedUnfairLock(initialState: State(items: items))
    }

    /// Every call so far, in order.
    var calls: [Call] { state.withLock { $0.calls } }

    /// The stored items, keyed by account.
    var items: [String: Data] { state.withLock { $0.items } }

    /// When set, every call throws this error.
    var errorToThrow: VaultCryptoError? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    func read(account: String, prompt: String?) throws -> Data? {
        try state.withLock { state in
            state.calls.append(.read(account: account, prompt: prompt))
            if let error = state.errorToThrow { throw error }
            return state.items[account]
        }
    }

    func write(_ data: Data, account: String, accessibility: KeychainAccessibility) throws {
        try state.withLock { state in
            state.calls.append(.write(account: account, accessibility: accessibility))
            if let error = state.errorToThrow { throw error }
            state.items[account] = data
        }
    }

    func delete(account: String) throws {
        try state.withLock { state in
            state.calls.append(.delete(account: account))
            if let error = state.errorToThrow { throw error }
            state.items[account] = nil
        }
    }
}
