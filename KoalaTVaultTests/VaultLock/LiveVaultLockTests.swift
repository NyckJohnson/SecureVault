import Foundation
import Testing

@testable import KoalaTVault

/// Assumes this initializer on `@MainActor final class LiveVaultLock: VaultLocking` in LiveVaultLock.swift:
/// `init(masterKeys: any MasterKeyStoring, keychain: any KeychainAccessing, preferences: any PreferencesStoring,
///       store: any VaultStoring, biometricInfo: BiometricInfo,
///       vaultHoldsEncryptedData: @escaping @Sendable () async -> Bool)`
/// `vaultHoldsEncryptedData` answers "does the vault hold any encrypted data (index, encrypted file or trash entry)".
/// `lockMode` reads the preferences; the initial state is `.open` for none, else `.locked`.
private let legacyAccount = "com.KoalaTVault.password"
private let secret = "correct horse"
private let otherSecret = "battery staple"

// MARK: - Launch and state

@MainActor
@Suite struct LiveVaultLockLaunchTests {
    @Test("With no lock the vault starts open")
    func startsOpenWithNoLock() async throws {
        let h = try await VaultLockHarness(lockMode: .none)
        #expect(h.lock.state == .open)
        #expect(h.lock.lockMode == .none)
    }

    @Test("With a lock the vault starts locked", arguments: [LockMode.password, .passwordAndBiometrics])
    func startsLockedWithLock(mode: LockMode) async throws {
        let h = try await VaultLockHarness(lockMode: mode, blobPassword: secret)
        #expect(h.lock.state == .locked)
        #expect(h.lock.lockMode == mode)
    }

    @Test("Biometric kind and availability come from the injected probe")
    func biometricInfoFromProbe() async throws {
        let h = try await VaultLockHarness(biometricKind: .touchID, biometricsEnabled: true)
        #expect(h.lock.biometricKind == .touchID)
        #expect(h.lock.biometricsAvailable)
        let none = try await VaultLockHarness(biometricKind: .none, biometricsEnabled: false)
        #expect(none.lock.biometricKind == .none)
        #expect(!none.lock.biometricsAvailable)
    }
}

// MARK: - setUp

@MainActor
@Suite struct LiveVaultLockSetUpTests {
    @Test("Setting up no lock writes none and touches no key or Keychain item")
    func setUpNone() async throws {
        let h = try await VaultLockHarness(lockMode: .none)
        try await h.lock.setUp(mode: .none, password: nil)
        #expect(h.prefs.lockMode == .none)
        #expect(h.lock.state == .open)
        #expect(h.log.events.filter { !$0.hasPrefix("lockMode=") }.isEmpty)
        #expect(h.keychain.calls.isEmpty)
    }

    @Test("Setting up a password lock with no blob creates the key then writes the lock mode and ends unlocked")
    func setUpPasswordNoBlob() async throws {
        let h = try await VaultLockHarness()
        try await h.lock.setUp(mode: .password, password: secret)
        let create = try #require(h.log.index(of: "createMasterKey"))
        let write = try #require(h.log.index(of: "lockMode=password"))
        #expect(create < write)
        #expect(!h.log.events.contains("storeBiometricKey"))
        #expect(h.keys.password == secret)
        #expect(h.keys.isKeyLoaded)
        #expect(h.lock.lockMode == .password)
        #expect(h.lock.state == .unlocked)
    }

    @Test("Setting up password plus biometrics stores the biometric item before writing the lock mode")
    func setUpBiometricOrder() async throws {
        let h = try await VaultLockHarness()
        try await h.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        let create = try #require(h.log.index(of: "createMasterKey"))
        let store = try #require(h.log.index(of: "storeBiometricKey"))
        let write = try #require(h.log.index(of: "lockMode=passwordAndBiometrics"))
        #expect(create < store)
        #expect(store < write)
        #expect(h.keys.hasBiometricKey)
        #expect(h.lock.state == .unlocked)
    }

    @Test("An empty password is rejected before anything is created", arguments: [String?.some(""), nil])
    func setUpEmptyPassword(password: String?) async throws {
        let h = try await VaultLockHarness()
        await #expect(throws: VaultLockError.emptyPassword) {
            try await h.lock.setUp(mode: .password, password: password)
        }
        #expect(!h.log.events.contains("createMasterKey"))
        #expect(h.prefs.lockModeWrites.isEmpty)
        #expect(h.lock.state == .open)
    }

    @Test("Biometric mode without biometrics throws biometricsUnavailable and creates nothing")
    func setUpBiometricsUnavailable() async throws {
        let h = try await VaultLockHarness(biometricKind: .none, biometricsEnabled: false)
        await #expect(throws: VaultLockError.biometricsUnavailable) {
            try await h.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        }
        #expect(!h.log.events.contains("createMasterKey"))
        #expect(h.keys.password == nil)
        #expect(h.prefs.lockModeWrites.isEmpty)
    }

    @Test("A stale blob in an empty vault is deleted with its biometric item and a new key is created")
    func staleBlobReplacedWhenVaultEmpty() async throws {
        let h = try await VaultLockHarness(
            blobPassword: otherSecret, hasBiometricKey: true, vaultHasEncryptedData: false)
        try await h.lock.setUp(mode: .password, password: secret)
        let deleteBlob = try #require(h.log.index(of: "deleteMasterKeyBlob"))
        let deleteBiometric = try #require(h.log.index(of: "deleteBiometricKey"))
        let create = try #require(h.log.index(of: "createMasterKey"))
        #expect(deleteBlob < create)
        #expect(deleteBiometric < create)
        #expect(h.keys.password == secret)
        #expect(!h.keys.hasBiometricKey)
        #expect(h.lock.state == .unlocked)
        #expect(h.lock.lockMode == .password)
    }

    @Test("An existing blob over encrypted data is unlocked with the given password, not replaced")
    func existingBlobWithRightPassword() async throws {
        let h = try await VaultLockHarness(blobPassword: secret, vaultHasEncryptedData: true)
        try await h.lock.setUp(mode: .password, password: secret)
        #expect(!h.log.events.contains("createMasterKey"))
        #expect(!h.log.events.contains("deleteMasterKeyBlob"))
        #expect(h.keys.password == secret)
        #expect(h.lock.state == .unlocked)
        #expect(h.lock.lockMode == .password)
    }

    @Test("An existing blob over encrypted data with a wrong password throws existingPasswordRequired and is kept")
    func existingBlobWithWrongPassword() async throws {
        let h = try await VaultLockHarness(blobPassword: secret, vaultHasEncryptedData: true)
        await #expect(throws: VaultLockError.existingPasswordRequired) {
            try await h.lock.setUp(mode: .password, password: otherSecret)
        }
        #expect(h.keys.password == secret)
        #expect(!h.log.events.contains("deleteMasterKeyBlob"))
        #expect(!h.log.events.contains("createMasterKey"))
        #expect(h.prefs.lockModeWrites.isEmpty)
        #expect(!h.keys.isKeyLoaded)
        #expect(h.lock.state == .open)
    }

    @Test("A Keychain error while checking for a blob is thrown and nothing is created")
    func blobCheckErrorIsThrown() async throws {
        let h = try await VaultLockHarness()
        h.keys.failures = ["hasMasterKeyBlob": .keychain(-25308)]
        await #expect(throws: VaultLockError.keychain(-25308)) {
            try await h.lock.setUp(mode: .password, password: secret)
        }
        #expect(!h.log.events.contains("createMasterKey"))
        #expect(h.prefs.lockModeWrites.isEmpty)
    }

    @Test("A failure storing the biometric item rolls back: blob and item deleted, key wiped, lock mode unchanged")
    func rollbackAfterBiometricFailure() async throws {
        let h = try await VaultLockHarness()
        h.keys.failures = ["storeBiometricKey": .keychain(-25293)]
        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await h.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        }
        let events = h.log.events
        let create = try #require(events.firstIndex(of: "createMasterKey"))
        let rollbackDelete = try #require(events.lastIndex(of: "deleteMasterKeyBlob"))
        #expect(rollbackDelete > create)
        #expect(events.suffix(from: create).contains("deleteBiometricKey"))
        #expect(events.suffix(from: create).contains("wipeKey"))
        #expect(h.keys.password == nil)
        #expect(!h.keys.hasBiometricKey)
        #expect(!h.keys.isKeyLoaded)
        #expect(h.prefs.lockModeWrites.isEmpty)
        #expect(h.prefs.lockMode == .none)
        #expect(h.lock.state == .open)
    }

    @Test("After a rolled-back setup a retry succeeds instead of failing with a leftover key")
    func retryAfterRollbackSucceeds() async throws {
        let h = try await VaultLockHarness()
        h.keys.failures = ["storeBiometricKey": .keychain(-25293)]
        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await h.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        }
        h.keys.failures = [:]
        try await h.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        #expect(h.lock.state == .unlocked)
        #expect(h.lock.lockMode == .passwordAndBiometrics)
    }
}

// MARK: - unlock

@MainActor
@Suite struct LiveVaultLockUnlockTests {
    @Test("The right password loads the key and unlocks")
    func rightPassword() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        try await h.lock.unlock(password: secret)
        #expect(h.keys.isKeyLoaded)
        #expect(h.lock.state == .unlocked)
    }

    @Test("A wrong password throws wrongPassword and stays locked")
    func wrongPassword() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        await #expect(throws: VaultLockError.wrongPassword) {
            try await h.lock.unlock(password: otherSecret)
        }
        #expect(!h.keys.isKeyLoaded)
        #expect(h.lock.state == .locked)
    }

    @Test("An empty password throws emptyPassword")
    func emptyPassword() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        await #expect(throws: VaultLockError.emptyPassword) {
            try await h.lock.unlock(password: "")
        }
        #expect(h.lock.state == .locked)
    }

    @Test("With no blob unlocking throws passwordMissing")
    func noBlob() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: nil)
        await #expect(throws: VaultLockError.passwordMissing) {
            try await h.lock.unlock(password: secret)
        }
        #expect(h.lock.state == .locked)
    }

    @Test("In biometric mode a successful unlock refreshes the biometric item")
    func refreshesBiometricItem() async throws {
        let h = try await VaultLockHarness(lockMode: .passwordAndBiometrics, blobPassword: secret)
        try await h.lock.unlock(password: secret)
        let unlock = try #require(h.log.index(of: "unlock"))
        let store = try #require(h.log.index(of: "storeBiometricKey"))
        #expect(unlock < store)
        #expect(h.keys.hasBiometricKey)
    }

    @Test("In password mode unlocking does not store a biometric item")
    func noBiometricItemInPasswordMode() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        try await h.lock.unlock(password: secret)
        #expect(!h.log.events.contains("storeBiometricKey"))
    }

    @Test("A failure refreshing the biometric item does not fail the unlock")
    func refreshFailureIgnored() async throws {
        let h = try await VaultLockHarness(lockMode: .passwordAndBiometrics, blobPassword: secret)
        h.keys.failures = ["storeBiometricKey": .keychain(-25293)]
        try await h.lock.unlock(password: secret)
        #expect(h.lock.state == .unlocked)
        #expect(h.keys.isKeyLoaded)
    }

    @Test("Unlocking deletes the legacy plaintext password item and ignores a delete error")
    func deletesLegacyItem() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        h.keychain.errorToThrow = .keychain(-25300)
        try await h.lock.unlock(password: secret)
        #expect(h.keychain.calls.contains(.delete(account: legacyAccount)))
        #expect(h.lock.state == .unlocked)
    }
}

// MARK: - unlockWithBiometrics

@MainActor
@Suite struct LiveVaultLockBiometricUnlockTests {
    @Test("Reading the biometric item loads the key and unlocks")
    func success() async throws {
        let h = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true)
        try await h.lock.unlockWithBiometrics()
        #expect(h.keys.isKeyLoaded)
        #expect(h.lock.state == .unlocked)
    }

    @Test("A key that does not match the vault is wiped, the item deleted and biometricChanged thrown")
    func keyMismatch() async throws {
        let h = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true,
            keyMatchesVault: false)
        await #expect(throws: VaultLockError.biometricChanged) {
            try await h.lock.unlockWithBiometrics()
        }
        #expect(h.store.calls.contains(.keyMatchesVault))
        #expect(!h.keys.isKeyLoaded)
        #expect(!h.keys.hasBiometricKey)
        #expect(h.log.events.contains("wipeKey"))
        #expect(h.log.events.contains("deleteBiometricKey"))
        #expect(h.lock.state == .locked)
    }

    @Test("Biometric failures map to lock errors and leave the vault locked", arguments: [
        (VaultCryptoError.biometricCancelled, VaultLockError.biometricCancelled),
        (VaultCryptoError.biometricItemMissing, VaultLockError.biometricChanged),
        (VaultCryptoError.biometryLockedOut, VaultLockError.biometryLockedOut),
        (VaultCryptoError.biometryNotEnrolled, VaultLockError.biometryNotEnrolled),
        (VaultCryptoError.passcodeNotSet, VaultLockError.passcodeNotSet),
    ])
    func errorMapping(crypto: VaultCryptoError, expected: VaultLockError) async throws {
        let h = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true)
        h.keys.failures = ["unlockWithBiometricKey": crypto]
        await #expect(throws: expected) {
            try await h.lock.unlockWithBiometrics()
        }
        #expect(h.lock.state == .locked)
    }

    @Test("A missing biometric item throws biometricChanged")
    func missingItem() async throws {
        let h = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: false)
        await #expect(throws: VaultLockError.biometricChanged) {
            try await h.lock.unlockWithBiometrics()
        }
    }

    @Test("Outside biometric mode biometric unlock throws biometricsUnavailable without reading the item",
          arguments: [LockMode.none, .password])
    func notBiometricMode(mode: LockMode) async throws {
        let h = try await VaultLockHarness(lockMode: mode, blobPassword: secret, hasBiometricKey: true)
        await #expect(throws: VaultLockError.biometricsUnavailable) {
            try await h.lock.unlockWithBiometrics()
        }
        #expect(!h.log.events.contains("unlockWithBiometricKey"))
        #expect(!h.keys.isKeyLoaded)
    }
}

// MARK: - Lifecycle

@MainActor
@Suite struct LiveVaultLockLifecycleTests {
    @Test("Resigning active while unlocked asks for the privacy cover and wipes nothing")
    func resignActiveUnlocked() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let mark = h.log.events.count
        #expect(h.lock.appWillResignActive())
        #expect(h.events(after: mark).isEmpty)
        #expect(h.keys.isKeyLoaded)
        #expect(h.lock.state == .unlocked)
        #expect(!h.store.calls.contains(.removeAllTemporaryFiles))
    }

    @Test("Resigning active while locked does not ask for the cover")
    func resignActiveLocked() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        #expect(!h.lock.appWillResignActive())
    }

    @Test("Resigning active with no lock does not ask for the cover")
    func resignActiveOpen() async throws {
        let h = try await VaultLockHarness(lockMode: .none)
        #expect(!h.lock.appWillResignActive())
    }

    @Test("Entering the background with a lock wipes the key, removes temp files and locks")
    func backgroundWithLock() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        h.lock.appDidEnterBackground()
        #expect(!h.keys.isKeyLoaded)
        #expect(h.log.events.contains("wipeKey"))
        #expect(h.store.calls.contains(.removeAllTemporaryFiles))
        #expect(h.lock.state == .locked)
    }

    @Test("Entering the background with no lock does nothing")
    func backgroundWithoutLock() async throws {
        let h = try await VaultLockHarness(lockMode: .none)
        h.lock.appDidEnterBackground()
        #expect(!h.log.events.contains("wipeKey"))
        #expect(!h.store.calls.contains(.removeAllTemporaryFiles))
        #expect(h.lock.state == .open)
    }

    @Test("Entering the foreground with no lock is open")
    func foregroundWithoutLock() async throws {
        let h = try await VaultLockHarness(lockMode: .none)
        h.lock.appWillEnterForeground()
        #expect(h.lock.state == .open)
    }

    @Test("Entering the foreground with a lock leaves the state unchanged")
    func foregroundWithLock() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        h.lock.appWillEnterForeground()
        #expect(h.lock.state == .locked)
        try await h.lock.unlock(password: secret)
        h.lock.appWillEnterForeground()
        #expect(h.lock.state == .unlocked)
    }

    @Test("Entering the foreground after the lock mode became none is open")
    func foregroundAfterLockRemoved() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        h.prefs.lockMode = .none
        h.lock.appWillEnterForeground()
        #expect(h.lock.state == .open)
    }
}

// MARK: - stateUpdates

@MainActor
@Suite struct LiveVaultLockStateUpdatesTests {
    @Test("Each state change is published exactly once, in order")
    func publishesEachChangeOnce() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        let collector = LockStateCollector(h.lock.stateUpdates())
        try await h.lock.unlock(password: secret)
        await collector.settle()
        #expect(collector.values == [.unlocked])
        h.lock.appDidEnterBackground()
        await collector.settle()
        #expect(collector.values == [.unlocked, .locked])
        collector.stop()
    }

    @Test("A failed unlock publishes nothing")
    func failedUnlockPublishesNothing() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        let collector = LockStateCollector(h.lock.stateUpdates())
        await #expect(throws: VaultLockError.wrongPassword) {
            try await h.lock.unlock(password: otherSecret)
        }
        await collector.settle()
        #expect(collector.values.isEmpty)
        collector.stop()
    }

    @Test("Setting up a lock publishes unlocked once")
    func setUpPublishes() async throws {
        let h = try await VaultLockHarness()
        let collector = LockStateCollector(h.lock.stateUpdates())
        try await h.lock.setUp(mode: .password, password: secret)
        await collector.settle()
        #expect(collector.values == [.unlocked])
        collector.stop()
    }

    @Test("Entering the foreground without a change publishes nothing")
    func unchangedForegroundPublishesNothing() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        let collector = LockStateCollector(h.lock.stateUpdates())
        h.lock.appWillEnterForeground()
        h.lock.appDidEnterBackground()
        await collector.settle()
        #expect(collector.values.isEmpty)
        collector.stop()
    }

    @Test("Removing the keys publishes open once")
    func removeKeysPublishes() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let collector = LockStateCollector(h.lock.stateUpdates())
        try await h.lock.removeKeysAfterDecryption()
        await collector.settle()
        #expect(collector.values == [.open])
        collector.stop()
    }

    @Test("Every subscriber receives the changes")
    func multipleSubscribers() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        let first = LockStateCollector(h.lock.stateUpdates())
        let second = LockStateCollector(h.lock.stateUpdates())
        try await h.lock.unlock(password: secret)
        await first.settle()
        #expect(first.values == [.unlocked])
        #expect(second.values == [.unlocked])
        first.stop()
        second.stop()
    }
}

// MARK: - changePassword

@MainActor
@Suite struct LiveVaultLockChangePasswordTests {
    @Test("Changing the password rewraps the blob so the new password unlocks and the old one does not")
    func changesPassword() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let mark = h.log.events.count
        try await h.lock.changePassword(current: secret, new: otherSecret)
        #expect(h.events(after: mark).contains("rewrap"))
        #expect(!h.events(after: mark).contains("createMasterKey"))
        h.lock.appDidEnterBackground()
        await #expect(throws: VaultLockError.wrongPassword) {
            try await h.lock.unlock(password: secret)
        }
        try await h.lock.unlock(password: otherSecret)
        #expect(h.lock.state == .unlocked)
    }

    @Test("A wrong current password throws wrongPassword and leaves the blob unchanged")
    func wrongCurrent() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let mark = h.log.events.count
        await #expect(throws: VaultLockError.wrongPassword) {
            try await h.lock.changePassword(current: "nope", new: otherSecret)
        }
        #expect(h.keys.password == secret)
        #expect(!h.events(after: mark).contains("rewrap"))
    }

    @Test("An empty new password throws emptyPassword and leaves the blob unchanged")
    func emptyNew() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let mark = h.log.events.count
        await #expect(throws: VaultLockError.emptyPassword) {
            try await h.lock.changePassword(current: secret, new: "")
        }
        #expect(h.keys.password == secret)
        #expect(!h.events(after: mark).contains("rewrap"))
    }
}

// MARK: - switchMode

@MainActor
@Suite struct LiveVaultLockSwitchModeTests {
    @Test("Switching to password plus biometrics stores the biometric item, then writes the lock mode")
    func enableBiometrics() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let mark = h.log.events.count
        try await h.lock.switchMode(to: .passwordAndBiometrics)
        let events = h.events(after: mark)
        let store = try #require(events.firstIndex(of: "storeBiometricKey"))
        let write = try #require(events.firstIndex(of: "lockMode=passwordAndBiometrics"))
        #expect(store < write)
        #expect(h.lock.lockMode == .passwordAndBiometrics)
        #expect(h.keys.hasBiometricKey)
    }

    @Test("Enabling biometrics without the key loaded throws notUnlocked and changes nothing")
    func enableBiometricsLocked() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        await #expect(throws: VaultLockError.notUnlocked) {
            try await h.lock.switchMode(to: .passwordAndBiometrics)
        }
        #expect(h.prefs.lockModeWrites.isEmpty)
        #expect(h.lock.lockMode == .password)
        #expect(!h.keys.hasBiometricKey)
    }

    @Test("A failure storing the biometric item leaves the lock mode unchanged and throws")
    func enableBiometricsFailure() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        h.keys.failures = ["storeBiometricKey": .keychain(-25293)]
        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await h.lock.switchMode(to: .passwordAndBiometrics)
        }
        #expect(h.prefs.lockModeWrites.isEmpty)
        #expect(h.lock.lockMode == .password)
    }

    @Test("Switching to password writes the lock mode, then deletes the biometric item")
    func disableBiometrics() async throws {
        let h = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true, unlocked: true)
        let mark = h.log.events.count
        try await h.lock.switchMode(to: .password)
        let events = h.events(after: mark)
        let write = try #require(events.firstIndex(of: "lockMode=password"))
        let delete = try #require(events.firstIndex(of: "deleteBiometricKey"))
        #expect(write < delete)
        #expect(h.lock.lockMode == .password)
        #expect(!h.keys.hasBiometricKey)
    }

    @Test("A biometric item delete failure is thrown after the lock mode was already set")
    func disableBiometricsDeleteFailure() async throws {
        let h = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true, unlocked: true)
        h.keys.failures = ["deleteBiometricKey": .keychain(-25244)]
        await #expect(throws: VaultLockError.keychain(-25244)) {
            try await h.lock.switchMode(to: .password)
        }
        #expect(h.lock.lockMode == .password)
        #expect(h.prefs.lockMode == .password)
    }

    @Test("Switching to or from none is not allowed here", arguments: [
        (LockMode.password, LockMode.none),
        (LockMode.passwordAndBiometrics, LockMode.none),
        (LockMode.none, LockMode.password),
        (LockMode.none, LockMode.passwordAndBiometrics),
    ])
    func noneNotAllowed(from: LockMode, to: LockMode) async throws {
        let h = try await VaultLockHarness(
            lockMode: from, blobPassword: from == .none ? nil : secret, hasBiometricKey: from == .passwordAndBiometrics,
            unlocked: from != .none)
        let mark = h.log.events.count
        await #expect(throws: VaultLockError.notUnlocked) {
            try await h.lock.switchMode(to: to)
        }
        #expect(h.lock.lockMode == from)
        #expect(h.events(after: mark).isEmpty)
    }
}

// MARK: - prepareToAddLock

@MainActor
@Suite struct LiveVaultLockPrepareToAddLockTests {
    @Test("With no blob the key is created and the lock mode written; the lock ends unlocked")
    func noBlob() async throws {
        let h = try await VaultLockHarness()
        try await h.lock.prepareToAddLock(mode: .password, password: secret)
        let create = try #require(h.log.index(of: "createMasterKey"))
        let write = try #require(h.log.index(of: "lockMode=password"))
        #expect(create < write)
        #expect(h.lock.lockMode == .password)
        #expect(h.lock.state == .unlocked)
        #expect(h.keys.password == secret)
    }

    @Test("Biometric mode stores the biometric item before writing the lock mode")
    func biometricMode() async throws {
        let h = try await VaultLockHarness()
        try await h.lock.prepareToAddLock(mode: .passwordAndBiometrics, password: secret)
        let store = try #require(h.log.index(of: "storeBiometricKey"))
        let write = try #require(h.log.index(of: "lockMode=passwordAndBiometrics"))
        #expect(store < write)
        #expect(h.lock.state == .unlocked)
    }

    @Test("A stale blob in an empty vault is replaced")
    func staleBlobReplaced() async throws {
        let h = try await VaultLockHarness(
            blobPassword: otherSecret, hasBiometricKey: true, vaultHasEncryptedData: false)
        try await h.lock.prepareToAddLock(mode: .password, password: secret)
        let deleteBlob = try #require(h.log.index(of: "deleteMasterKeyBlob"))
        let create = try #require(h.log.index(of: "createMasterKey"))
        #expect(deleteBlob < create)
        #expect(!h.keys.hasBiometricKey)
        #expect(h.keys.password == secret)
        #expect(h.lock.state == .unlocked)
    }

    @Test("An existing blob over encrypted data is unlocked with the right password")
    func existingBlobRightPassword() async throws {
        let h = try await VaultLockHarness(blobPassword: secret, vaultHasEncryptedData: true)
        try await h.lock.prepareToAddLock(mode: .password, password: secret)
        #expect(!h.log.events.contains("deleteMasterKeyBlob"))
        #expect(!h.log.events.contains("createMasterKey"))
        #expect(h.lock.lockMode == .password)
        #expect(h.lock.state == .unlocked)
    }

    @Test("An existing blob over encrypted data with a wrong password throws existingPasswordRequired")
    func existingBlobWrongPassword() async throws {
        let h = try await VaultLockHarness(blobPassword: secret, vaultHasEncryptedData: true)
        await #expect(throws: VaultLockError.existingPasswordRequired) {
            try await h.lock.prepareToAddLock(mode: .password, password: otherSecret)
        }
        #expect(h.keys.password == secret)
        #expect(!h.log.events.contains("deleteMasterKeyBlob"))
        #expect(h.prefs.lockModeWrites.isEmpty)
        #expect(h.lock.state == .open)
    }

    @Test("A Keychain error while checking for a blob is thrown, not treated as a blob or no blob")
    func blobCheckError() async throws {
        let h = try await VaultLockHarness()
        h.keys.failures = ["hasMasterKeyBlob": .keychain(-25308)]
        await #expect(throws: VaultLockError.keychain(-25308)) {
            try await h.lock.prepareToAddLock(mode: .password, password: secret)
        }
        #expect(!h.log.events.contains("createMasterKey"))
        #expect(h.prefs.lockModeWrites.isEmpty)
    }

    @Test("An empty password throws emptyPassword")
    func emptyPassword() async throws {
        let h = try await VaultLockHarness()
        await #expect(throws: VaultLockError.emptyPassword) {
            try await h.lock.prepareToAddLock(mode: .password, password: "")
        }
        #expect(!h.log.events.contains("createMasterKey"))
    }

    @Test("A biometric item failure rolls back: blob and item deleted, key wiped, lock mode unchanged")
    func rollback() async throws {
        let h = try await VaultLockHarness()
        h.keys.failures = ["storeBiometricKey": .keychain(-25293)]
        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await h.lock.prepareToAddLock(mode: .passwordAndBiometrics, password: secret)
        }
        let events = h.log.events
        let create = try #require(events.firstIndex(of: "createMasterKey"))
        #expect(events.suffix(from: create).contains("deleteMasterKeyBlob"))
        #expect(events.suffix(from: create).contains("deleteBiometricKey"))
        #expect(events.suffix(from: create).contains("wipeKey"))
        #expect(h.keys.password == nil)
        #expect(!h.keys.hasBiometricKey)
        #expect(!h.keys.isKeyLoaded)
        #expect(h.prefs.lockModeWrites.isEmpty)
        #expect(h.lock.lockMode == .none)
        #expect(h.lock.state == .open)
    }
}

// MARK: - removeKeysAfterDecryption

@MainActor
@Suite struct LiveVaultLockRemoveKeysTests {
    @Test("Keys are removed in order: biometric item, lock mode none, blob, key wipe; the lock ends open")
    func removesInOrder() async throws {
        let h = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true, unlocked: true)
        let mark = h.log.events.count
        try await h.lock.removeKeysAfterDecryption()
        let steps = h.events(after: mark).filter {
            ["deleteBiometricKey", "lockMode=none", "deleteMasterKeyBlob", "wipeKey"].contains($0)
        }
        #expect(steps == ["deleteBiometricKey", "lockMode=none", "deleteMasterKeyBlob", "wipeKey"])
        #expect(h.keys.password == nil)
        #expect(!h.keys.hasBiometricKey)
        #expect(!h.keys.isKeyLoaded)
        #expect(h.lock.lockMode == .none)
        #expect(h.lock.state == .open)
    }

    @Test("The legacy plaintext password item is deleted")
    func deletesLegacyItem() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        try await h.lock.removeKeysAfterDecryption()
        #expect(h.keychain.calls.contains(.delete(account: legacyAccount)))
    }

    @Test("A legacy item delete error is ignored")
    func legacyDeleteErrorIgnored() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        h.keychain.errorToThrow = .keychain(-25300)
        try await h.lock.removeKeysAfterDecryption()
        #expect(h.lock.state == .open)
        #expect(h.keys.password == nil)
    }

    @Test("Running it again after completion succeeds and changes nothing")
    func repeatable() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        try await h.lock.removeKeysAfterDecryption()
        try await h.lock.removeKeysAfterDecryption()
        #expect(h.lock.lockMode == .none)
        #expect(h.lock.state == .open)
        #expect(h.keys.password == nil)
    }

    @Test("It also works when the vault was left locked")
    func fromLockedState() async throws {
        let h = try await VaultLockHarness(lockMode: .password, blobPassword: secret, hasBiometricKey: true)
        try await h.lock.removeKeysAfterDecryption()
        #expect(h.keys.password == nil)
        #expect(!h.keys.hasBiometricKey)
        #expect(h.lock.state == .open)
    }

    @Test("A biometric item delete failure throws and leaves the later steps for the next call")
    func biometricDeleteFailureStops() async throws {
        let h = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true, unlocked: true)
        h.keys.failures = ["deleteBiometricKey": .keychain(-25244)]
        await #expect(throws: VaultLockError.keychain(-25244)) {
            try await h.lock.removeKeysAfterDecryption()
        }
        #expect(h.prefs.lockModeWrites.isEmpty)
        #expect(h.keys.password == secret)
        #expect(h.keys.isKeyLoaded)

        h.keys.failures = [:]
        try await h.lock.removeKeysAfterDecryption()
        #expect(h.lock.lockMode == .none)
        #expect(h.keys.password == nil)
        #expect(!h.keys.hasBiometricKey)
        #expect(!h.keys.isKeyLoaded)
        #expect(h.lock.state == .open)
    }

    @Test("A blob delete failure throws after the lock mode was cleared; the next call finishes")
    func blobDeleteFailureResumes() async throws {
        let h = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true, unlocked: true)
        h.keys.failures = ["deleteMasterKeyBlob": .keychain(-25244)]
        await #expect(throws: VaultLockError.keychain(-25244)) {
            try await h.lock.removeKeysAfterDecryption()
        }
        #expect(h.prefs.lockMode == .none)
        #expect(!h.keys.hasBiometricKey)
        #expect(h.keys.password == secret)
        #expect(h.keys.isKeyLoaded)

        h.keys.failures = [:]
        try await h.lock.removeKeysAfterDecryption()
        #expect(h.keys.password == nil)
        #expect(!h.keys.isKeyLoaded)
        #expect(h.lock.state == .open)
    }
}
