import Foundation
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
}
