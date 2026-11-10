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
        let harness = try await VaultLockHarness(lockMode: .none)
        #expect(harness.lock.state == .open)
        #expect(harness.lock.lockMode == .none)
    }

    @Test("With a lock the vault starts locked", arguments: [LockMode.password, .passwordAndBiometrics])
    func startsLockedWithLock(mode: LockMode) async throws {
        let harness = try await VaultLockHarness(lockMode: mode, blobPassword: secret)
        #expect(harness.lock.state == .locked)
        #expect(harness.lock.lockMode == mode)
    }

    @Test("Biometric kind and availability come from the injected probe")
    func biometricInfoFromProbe() async throws {
        let harness = try await VaultLockHarness(biometricKind: .touchID, biometricsEnabled: true)
        #expect(harness.lock.biometricKind == .touchID)
        #expect(harness.lock.biometricsAvailable)
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
        let harness = try await VaultLockHarness(lockMode: .none)
        try await harness.lock.setUp(mode: .none, password: nil)
        #expect(harness.prefs.lockMode == .none)
        #expect(harness.lock.state == .open)
        #expect(harness.log.events.filter { !$0.hasPrefix("lockMode=") }.isEmpty)
        #expect(harness.keychain.calls.isEmpty)
    }

    @Test("Setting up a password lock with no blob creates the key then writes the lock mode and ends unlocked")
    func setUpPasswordNoBlob() async throws {
        let harness = try await VaultLockHarness()
        try await harness.lock.setUp(mode: .password, password: secret)
        let create = try #require(harness.log.index(of: "createMasterKey"))
        let write = try #require(harness.log.index(of: "lockMode=password"))
        #expect(create < write)
        #expect(!harness.log.events.contains("storeBiometricKey"))
        #expect(harness.keys.password == secret)
        #expect(harness.keys.isKeyLoaded)
        #expect(harness.lock.lockMode == .password)
        #expect(harness.lock.state == .unlocked)
    }

    @Test("Setting up password plus biometrics stores the biometric item before writing the lock mode")
    func setUpBiometricOrder() async throws {
        let harness = try await VaultLockHarness()
        try await harness.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        let create = try #require(harness.log.index(of: "createMasterKey"))
        let store = try #require(harness.log.index(of: "storeBiometricKey"))
        let write = try #require(harness.log.index(of: "lockMode=passwordAndBiometrics"))
        #expect(create < store)
        #expect(store < write)
        #expect(harness.keys.hasBiometricKey)
        #expect(harness.lock.state == .unlocked)
    }

    @Test("An empty password is rejected before anything is created", arguments: [String?.some(""), nil])
    func setUpEmptyPassword(password: String?) async throws {
        let harness = try await VaultLockHarness()
        await #expect(throws: VaultLockError.emptyPassword) {
            try await harness.lock.setUp(mode: .password, password: password)
        }
        #expect(!harness.log.events.contains("createMasterKey"))
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.state == .open)
    }

    @Test("Biometric mode without biometrics throws biometricsUnavailable and creates nothing")
    func setUpBiometricsUnavailable() async throws {
        let harness = try await VaultLockHarness(biometricKind: .none, biometricsEnabled: false)
        await #expect(throws: VaultLockError.biometricsUnavailable) {
            try await harness.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        }
        #expect(!harness.log.events.contains("createMasterKey"))
        #expect(harness.keys.password == nil)
        #expect(harness.prefs.lockModeWrites.isEmpty)
    }

    @Test("A stale blob in an empty vault is deleted with its biometric item and a new key is created")
    func staleBlobReplacedWhenVaultEmpty() async throws {
        let harness = try await VaultLockHarness(
            blobPassword: otherSecret, hasBiometricKey: true, vaultHasEncryptedData: false)
        try await harness.lock.setUp(mode: .password, password: secret)
        let deleteBlob = try #require(harness.log.index(of: "deleteMasterKeyBlob"))
        let deleteBiometric = try #require(harness.log.index(of: "deleteBiometricKey"))
        let create = try #require(harness.log.index(of: "createMasterKey"))
        #expect(deleteBlob < create)
        #expect(deleteBiometric < create)
        #expect(harness.keys.password == secret)
        #expect(!harness.keys.hasBiometricKey)
        #expect(harness.lock.state == .unlocked)
        #expect(harness.lock.lockMode == .password)
    }

    @Test("An existing blob over encrypted data is unlocked with the given password, not replaced")
    func existingBlobWithRightPassword() async throws {
        let harness = try await VaultLockHarness(blobPassword: secret, vaultHasEncryptedData: true)
        try await harness.lock.setUp(mode: .password, password: secret)
        #expect(!harness.log.events.contains("createMasterKey"))
        #expect(!harness.log.events.contains("deleteMasterKeyBlob"))
        #expect(harness.keys.password == secret)
        #expect(harness.lock.state == .unlocked)
        #expect(harness.lock.lockMode == .password)
    }

    @Test("An existing blob over encrypted data with a wrong password throws existingPasswordRequired and is kept")
    func existingBlobWithWrongPassword() async throws {
        let harness = try await VaultLockHarness(blobPassword: secret, vaultHasEncryptedData: true)
        await #expect(throws: VaultLockError.existingPasswordRequired) {
            try await harness.lock.setUp(mode: .password, password: otherSecret)
        }
        #expect(harness.keys.password == secret)
        #expect(!harness.log.events.contains("deleteMasterKeyBlob"))
        #expect(!harness.log.events.contains("createMasterKey"))
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(!harness.keys.isKeyLoaded)
        #expect(harness.lock.state == .open)
    }

    @Test("A Keychain error while checking for a blob is thrown and nothing is created")
    func blobCheckErrorIsThrown() async throws {
        let harness = try await VaultLockHarness()
        harness.keys.failures = ["hasMasterKeyBlob": .keychain(-25308)]
        await #expect(throws: VaultLockError.keychain(-25308)) {
            try await harness.lock.setUp(mode: .password, password: secret)
        }
        #expect(!harness.log.events.contains("createMasterKey"))
        #expect(harness.prefs.lockModeWrites.isEmpty)
    }

    @Test("A failure storing the biometric item rolls back: blob and item deleted, key wiped, lock mode unchanged")
    func rollbackAfterBiometricFailure() async throws {
        let harness = try await VaultLockHarness()
        harness.keys.failures = ["storeBiometricKey": .keychain(-25293)]
        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await harness.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        }
        let events = harness.log.events
        let create = try #require(events.firstIndex(of: "createMasterKey"))
        let rollbackDelete = try #require(events.lastIndex(of: "deleteMasterKeyBlob"))
        #expect(rollbackDelete > create)
        #expect(events.suffix(from: create).contains("deleteBiometricKey"))
        #expect(events.suffix(from: create).contains("wipeKey"))
        #expect(harness.keys.password == nil)
        #expect(!harness.keys.hasBiometricKey)
        #expect(!harness.keys.isKeyLoaded)
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.prefs.lockMode == .none)
        #expect(harness.lock.state == .open)
    }

    @Test("After a rolled-back setup a retry succeeds instead of failing with a leftover key")
    func retryAfterRollbackSucceeds() async throws {
        let harness = try await VaultLockHarness()
        harness.keys.failures = ["storeBiometricKey": .keychain(-25293)]
        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await harness.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        }
        harness.keys.failures = [:]
        try await harness.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        #expect(harness.lock.state == .unlocked)
        #expect(harness.lock.lockMode == .passwordAndBiometrics)
    }
}

// MARK: - unlock

@MainActor
@Suite struct LiveVaultLockUnlockTests {
    @Test("The right password loads the key and unlocks")
    func rightPassword() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        try await harness.lock.unlock(password: secret)
        #expect(harness.keys.isKeyLoaded)
        #expect(harness.lock.state == .unlocked)
    }

    @Test("A wrong password throws wrongPassword and stays locked")
    func wrongPassword() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        await #expect(throws: VaultLockError.wrongPassword) {
            try await harness.lock.unlock(password: otherSecret)
        }
        #expect(!harness.keys.isKeyLoaded)
        #expect(harness.lock.state == .locked)
    }

    @Test("An empty password throws emptyPassword")
    func emptyPassword() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        await #expect(throws: VaultLockError.emptyPassword) {
            try await harness.lock.unlock(password: "")
        }
        #expect(harness.lock.state == .locked)
    }

    @Test("With no blob unlocking throws passwordMissing")
    func noBlob() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: nil)
        await #expect(throws: VaultLockError.passwordMissing) {
            try await harness.lock.unlock(password: secret)
        }
        #expect(harness.lock.state == .locked)
    }

    @Test("In biometric mode a successful unlock refreshes the biometric item")
    func refreshesBiometricItem() async throws {
        let harness = try await VaultLockHarness(lockMode: .passwordAndBiometrics, blobPassword: secret)
        try await harness.lock.unlock(password: secret)
        let unlock = try #require(harness.log.index(of: "unlock"))
        let store = try #require(harness.log.index(of: "storeBiometricKey"))
        #expect(unlock < store)
        #expect(harness.keys.hasBiometricKey)
    }

    @Test("In password mode unlocking does not store a biometric item")
    func noBiometricItemInPasswordMode() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        try await harness.lock.unlock(password: secret)
        #expect(!harness.log.events.contains("storeBiometricKey"))
    }

    @Test("A failure refreshing the biometric item does not fail the unlock")
    func refreshFailureIgnored() async throws {
        let harness = try await VaultLockHarness(lockMode: .passwordAndBiometrics, blobPassword: secret)
        harness.keys.failures = ["storeBiometricKey": .keychain(-25293)]
        try await harness.lock.unlock(password: secret)
        #expect(harness.lock.state == .unlocked)
        #expect(harness.keys.isKeyLoaded)
    }

    @Test("Unlocking deletes the legacy plaintext password item and ignores a delete error")
    func deletesLegacyItem() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        harness.keychain.errorToThrow = .keychain(-25300)
        try await harness.lock.unlock(password: secret)
        #expect(harness.keychain.calls.contains(.delete(account: legacyAccount)))
        #expect(harness.lock.state == .unlocked)
    }
}

// MARK: - unlockWithBiometrics

@MainActor
@Suite struct LiveVaultLockBiometricUnlockTests {
    @Test("Reading the biometric item loads the key and unlocks")
    func success() async throws {
        let harness = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true)
        try await harness.lock.unlockWithBiometrics()
        #expect(harness.keys.isKeyLoaded)
        #expect(harness.lock.state == .unlocked)
    }

    @Test("A key that does not match the vault is wiped, the item deleted and biometricChanged thrown")
    func keyMismatch() async throws {
        let harness = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true,
            keyMatchesVault: false)
        await #expect(throws: VaultLockError.biometricChanged) {
            try await harness.lock.unlockWithBiometrics()
        }
        #expect(harness.store.calls.contains(.keyMatchesVault))
        #expect(!harness.keys.isKeyLoaded)
        #expect(!harness.keys.hasBiometricKey)
        #expect(harness.log.events.contains("wipeKey"))
        #expect(harness.log.events.contains("deleteBiometricKey"))
        #expect(harness.lock.state == .locked)
    }

    // swiftlint:disable trailing_comma
    @Test(
        "Biometric failures map to lock errors and leave the vault locked",
        arguments: [
            (VaultCryptoError.biometricCancelled, VaultLockError.biometricCancelled),
            (VaultCryptoError.biometricItemMissing, VaultLockError.biometricChanged),
            (VaultCryptoError.biometryLockedOut, VaultLockError.biometryLockedOut),
            (VaultCryptoError.biometryNotEnrolled, VaultLockError.biometryNotEnrolled),
            (VaultCryptoError.passcodeNotSet, VaultLockError.passcodeNotSet),
        ])
    // swiftlint:enable trailing_comma
    func errorMapping(crypto: VaultCryptoError, expected: VaultLockError) async throws {
        let harness = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true)
        harness.keys.failures = ["unlockWithBiometricKey": crypto]
        await #expect(throws: expected) {
            try await harness.lock.unlockWithBiometrics()
        }
        #expect(harness.lock.state == .locked)
    }

    @Test("A missing biometric item throws biometricChanged")
    func missingItem() async throws {
        let harness = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: false)
        await #expect(throws: VaultLockError.biometricChanged) {
            try await harness.lock.unlockWithBiometrics()
        }
    }

    @Test(
        "Outside biometric mode biometric unlock throws biometricsUnavailable without reading the item",
        arguments: [LockMode.none, .password])
    func notBiometricMode(mode: LockMode) async throws {
        let harness = try await VaultLockHarness(lockMode: mode, blobPassword: secret, hasBiometricKey: true)
        await #expect(throws: VaultLockError.biometricsUnavailable) {
            try await harness.lock.unlockWithBiometrics()
        }
        #expect(!harness.log.events.contains("unlockWithBiometricKey"))
        #expect(!harness.keys.isKeyLoaded)
    }
}

// MARK: - Lifecycle

@MainActor
@Suite struct LiveVaultLockLifecycleTests {
    @Test("Resigning active while unlocked asks for the privacy cover and wipes nothing")
    func resignActiveUnlocked() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let mark = harness.log.events.count
        #expect(harness.lock.appWillResignActive())
        #expect(harness.events(after: mark).isEmpty)
        #expect(harness.keys.isKeyLoaded)
        #expect(harness.lock.state == .unlocked)
        #expect(!harness.store.calls.contains(.removeAllTemporaryFiles))
    }

    @Test("Resigning active while locked does not ask for the cover")
    func resignActiveLocked() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        #expect(!harness.lock.appWillResignActive())
    }

    @Test("Resigning active with no lock does not ask for the cover")
    func resignActiveOpen() async throws {
        let harness = try await VaultLockHarness(lockMode: .none)
        #expect(!harness.lock.appWillResignActive())
    }

    @Test("Entering the background with a lock wipes the key, removes temp files and locks")
    func backgroundWithLock() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        harness.lock.appDidEnterBackground()
        #expect(!harness.keys.isKeyLoaded)
        #expect(harness.log.events.contains("wipeKey"))
        #expect(harness.store.calls.contains(.removeAllTemporaryFiles))
        #expect(harness.lock.state == .locked)
    }

    @Test("Entering the background with no lock does nothing")
    func backgroundWithoutLock() async throws {
        let harness = try await VaultLockHarness(lockMode: .none)
        harness.lock.appDidEnterBackground()
        #expect(!harness.log.events.contains("wipeKey"))
        #expect(!harness.store.calls.contains(.removeAllTemporaryFiles))
        #expect(harness.lock.state == .open)
    }

    @Test("Entering the foreground with no lock is open")
    func foregroundWithoutLock() async throws {
        let harness = try await VaultLockHarness(lockMode: .none)
        harness.lock.appWillEnterForeground()
        #expect(harness.lock.state == .open)
    }

    @Test("Entering the foreground with a lock leaves the state unchanged")
    func foregroundWithLock() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        harness.lock.appWillEnterForeground()
        #expect(harness.lock.state == .locked)
        try await harness.lock.unlock(password: secret)
        harness.lock.appWillEnterForeground()
        #expect(harness.lock.state == .unlocked)
    }

    @Test("Entering the foreground after the lock mode became none is open")
    func foregroundAfterLockRemoved() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        harness.prefs.lockMode = .none
        harness.lock.appWillEnterForeground()
        #expect(harness.lock.state == .open)
    }
}

// MARK: - stateUpdates

@MainActor
@Suite struct LiveVaultLockStateUpdatesTests {
    @Test("Each state change is published exactly once, in order")
    func publishesEachChangeOnce() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        let collector = LockStateCollector(harness.lock.stateUpdates())
        try await harness.lock.unlock(password: secret)
        await collector.settle()
        #expect(collector.values == [.unlocked])
        harness.lock.appDidEnterBackground()
        await collector.settle()
        #expect(collector.values == [.unlocked, .locked])
        collector.stop()
    }

    @Test("A failed unlock publishes nothing")
    func failedUnlockPublishesNothing() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        let collector = LockStateCollector(harness.lock.stateUpdates())
        await #expect(throws: VaultLockError.wrongPassword) {
            try await harness.lock.unlock(password: otherSecret)
        }
        await collector.settle()
        #expect(collector.values.isEmpty)
        collector.stop()
    }

    @Test("Setting up a lock publishes unlocked once")
    func setUpPublishes() async throws {
        let harness = try await VaultLockHarness()
        let collector = LockStateCollector(harness.lock.stateUpdates())
        try await harness.lock.setUp(mode: .password, password: secret)
        await collector.settle()
        #expect(collector.values == [.unlocked])
        collector.stop()
    }

    @Test("Entering the foreground without a change publishes nothing")
    func unchangedForegroundPublishesNothing() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        let collector = LockStateCollector(harness.lock.stateUpdates())
        harness.lock.appWillEnterForeground()
        harness.lock.appDidEnterBackground()
        await collector.settle()
        #expect(collector.values.isEmpty)
        collector.stop()
    }

    @Test("Removing the keys publishes open once")
    func removeKeysPublishes() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let collector = LockStateCollector(harness.lock.stateUpdates())
        try await harness.lock.removeKeysAfterDecryption()
        await collector.settle()
        #expect(collector.values == [.open])
        collector.stop()
    }

    @Test("Every subscriber receives the changes")
    func multipleSubscribers() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        let first = LockStateCollector(harness.lock.stateUpdates())
        let second = LockStateCollector(harness.lock.stateUpdates())
        try await harness.lock.unlock(password: secret)
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
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let mark = harness.log.events.count
        try await harness.lock.changePassword(current: secret, new: otherSecret)
        #expect(harness.events(after: mark).contains("rewrap"))
        #expect(!harness.events(after: mark).contains("createMasterKey"))
        harness.lock.appDidEnterBackground()
        await #expect(throws: VaultLockError.wrongPassword) {
            try await harness.lock.unlock(password: secret)
        }
        try await harness.lock.unlock(password: otherSecret)
        #expect(harness.lock.state == .unlocked)
    }

    @Test("A wrong current password throws wrongPassword and leaves the blob unchanged")
    func wrongCurrent() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let mark = harness.log.events.count
        await #expect(throws: VaultLockError.wrongPassword) {
            try await harness.lock.changePassword(current: "nope", new: otherSecret)
        }
        #expect(harness.keys.password == secret)
        #expect(!harness.events(after: mark).contains("rewrap"))
    }

    @Test("An empty new password throws emptyPassword and leaves the blob unchanged")
    func emptyNew() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let mark = harness.log.events.count
        await #expect(throws: VaultLockError.emptyPassword) {
            try await harness.lock.changePassword(current: secret, new: "")
        }
        #expect(harness.keys.password == secret)
        #expect(!harness.events(after: mark).contains("rewrap"))
    }
}

// MARK: - switchMode

@MainActor
@Suite struct LiveVaultLockSwitchModeTests {
    @Test("Switching to password plus biometrics stores the biometric item, then writes the lock mode")
    func enableBiometrics() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        let mark = harness.log.events.count
        try await harness.lock.switchMode(to: .passwordAndBiometrics)
        let events = harness.events(after: mark)
        let store = try #require(events.firstIndex(of: "storeBiometricKey"))
        let write = try #require(events.firstIndex(of: "lockMode=passwordAndBiometrics"))
        #expect(store < write)
        #expect(harness.lock.lockMode == .passwordAndBiometrics)
        #expect(harness.keys.hasBiometricKey)
    }

    @Test("Enabling biometrics without the key loaded throws notUnlocked and changes nothing")
    func enableBiometricsLocked() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        await #expect(throws: VaultLockError.notUnlocked) {
            try await harness.lock.switchMode(to: .passwordAndBiometrics)
        }
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.lockMode == .password)
        #expect(!harness.keys.hasBiometricKey)
    }

    @Test("A failure storing the biometric item leaves the lock mode unchanged and throws")
    func enableBiometricsFailure() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        harness.keys.failures = ["storeBiometricKey": .keychain(-25293)]
        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await harness.lock.switchMode(to: .passwordAndBiometrics)
        }
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.lockMode == .password)
    }

    @Test("Switching to password writes the lock mode, then deletes the biometric item")
    func disableBiometrics() async throws {
        let harness = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true, unlocked: true)
        let mark = harness.log.events.count
        try await harness.lock.switchMode(to: .password)
        let events = harness.events(after: mark)
        let write = try #require(events.firstIndex(of: "lockMode=password"))
        let delete = try #require(events.firstIndex(of: "deleteBiometricKey"))
        #expect(write < delete)
        #expect(harness.lock.lockMode == .password)
        #expect(!harness.keys.hasBiometricKey)
    }

    @Test("A biometric item delete failure is thrown after the lock mode was already set")
    func disableBiometricsDeleteFailure() async throws {
        let harness = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true, unlocked: true)
        harness.keys.failures = ["deleteBiometricKey": .keychain(-25244)]
        await #expect(throws: VaultLockError.keychain(-25244)) {
            try await harness.lock.switchMode(to: .password)
        }
        #expect(harness.lock.lockMode == .password)
        #expect(harness.prefs.lockMode == .password)
    }

    // swiftlint:disable trailing_comma
    @Test(
        "Switching to or from none is not allowed here",
        arguments: [
            (LockMode.password, LockMode.none),
            (LockMode.passwordAndBiometrics, LockMode.none),
            (LockMode.none, LockMode.password),
            (LockMode.none, LockMode.passwordAndBiometrics),
        ])
    // swiftlint:enable trailing_comma
    func noneNotAllowed(from: LockMode, target: LockMode) async throws {
        let harness = try await VaultLockHarness(
            lockMode: from, blobPassword: from == .none ? nil : secret, hasBiometricKey: from == .passwordAndBiometrics,
            unlocked: from != .none)
        let mark = harness.log.events.count
        await #expect(throws: VaultLockError.notUnlocked) {
            try await harness.lock.switchMode(to: target)
        }
        #expect(harness.lock.lockMode == from)
        #expect(harness.events(after: mark).isEmpty)
    }
}

// MARK: - prepareToAddLock

@MainActor
@Suite struct LiveVaultLockPrepareToAddLockTests {
    @Test("With no blob the key is created and the lock mode written; the lock ends unlocked")
    func noBlob() async throws {
        let harness = try await VaultLockHarness()
        try await harness.lock.prepareToAddLock(mode: .password, password: secret)
        let create = try #require(harness.log.index(of: "createMasterKey"))
        let write = try #require(harness.log.index(of: "lockMode=password"))
        #expect(create < write)
        #expect(harness.lock.lockMode == .password)
        #expect(harness.lock.state == .unlocked)
        #expect(harness.keys.password == secret)
    }

    @Test("Biometric mode stores the biometric item before writing the lock mode")
    func biometricMode() async throws {
        let harness = try await VaultLockHarness()
        try await harness.lock.prepareToAddLock(mode: .passwordAndBiometrics, password: secret)
        let store = try #require(harness.log.index(of: "storeBiometricKey"))
        let write = try #require(harness.log.index(of: "lockMode=passwordAndBiometrics"))
        #expect(store < write)
        #expect(harness.lock.state == .unlocked)
    }

    @Test("A stale blob in an empty vault is replaced")
    func staleBlobReplaced() async throws {
        let harness = try await VaultLockHarness(
            blobPassword: otherSecret, hasBiometricKey: true, vaultHasEncryptedData: false)
        try await harness.lock.prepareToAddLock(mode: .password, password: secret)
        let deleteBlob = try #require(harness.log.index(of: "deleteMasterKeyBlob"))
        let create = try #require(harness.log.index(of: "createMasterKey"))
        #expect(deleteBlob < create)
        #expect(!harness.keys.hasBiometricKey)
        #expect(harness.keys.password == secret)
        #expect(harness.lock.state == .unlocked)
    }

    @Test("An existing blob over encrypted data is unlocked with the right password")
    func existingBlobRightPassword() async throws {
        let harness = try await VaultLockHarness(blobPassword: secret, vaultHasEncryptedData: true)
        try await harness.lock.prepareToAddLock(mode: .password, password: secret)
        #expect(!harness.log.events.contains("deleteMasterKeyBlob"))
        #expect(!harness.log.events.contains("createMasterKey"))
        #expect(harness.lock.lockMode == .password)
        #expect(harness.lock.state == .unlocked)
    }

    @Test("An existing blob over encrypted data with a wrong password throws existingPasswordRequired")
    func existingBlobWrongPassword() async throws {
        let harness = try await VaultLockHarness(blobPassword: secret, vaultHasEncryptedData: true)
        await #expect(throws: VaultLockError.existingPasswordRequired) {
            try await harness.lock.prepareToAddLock(mode: .password, password: otherSecret)
        }
        #expect(harness.keys.password == secret)
        #expect(!harness.log.events.contains("deleteMasterKeyBlob"))
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.state == .open)
    }

    @Test("A Keychain error while checking for a blob is thrown, not treated as a blob or no blob")
    func blobCheckError() async throws {
        let harness = try await VaultLockHarness()
        harness.keys.failures = ["hasMasterKeyBlob": .keychain(-25308)]
        await #expect(throws: VaultLockError.keychain(-25308)) {
            try await harness.lock.prepareToAddLock(mode: .password, password: secret)
        }
        #expect(!harness.log.events.contains("createMasterKey"))
        #expect(harness.prefs.lockModeWrites.isEmpty)
    }

    @Test("An empty password throws emptyPassword")
    func emptyPassword() async throws {
        let harness = try await VaultLockHarness()
        await #expect(throws: VaultLockError.emptyPassword) {
            try await harness.lock.prepareToAddLock(mode: .password, password: "")
        }
        #expect(!harness.log.events.contains("createMasterKey"))
    }

    @Test("A biometric item failure rolls back: blob and item deleted, key wiped, lock mode unchanged")
    func rollback() async throws {
        let harness = try await VaultLockHarness()
        harness.keys.failures = ["storeBiometricKey": .keychain(-25293)]
        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await harness.lock.prepareToAddLock(mode: .passwordAndBiometrics, password: secret)
        }
        let events = harness.log.events
        let create = try #require(events.firstIndex(of: "createMasterKey"))
        #expect(events.suffix(from: create).contains("deleteMasterKeyBlob"))
        #expect(events.suffix(from: create).contains("deleteBiometricKey"))
        #expect(events.suffix(from: create).contains("wipeKey"))
        #expect(harness.keys.password == nil)
        #expect(!harness.keys.hasBiometricKey)
        #expect(!harness.keys.isKeyLoaded)
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.lockMode == .none)
        #expect(harness.lock.state == .open)
    }
}

// MARK: - removeKeysAfterDecryption

@MainActor
@Suite struct LiveVaultLockRemoveKeysTests {
    @Test("Keys are removed in order: biometric item, lock mode none, blob, key wipe; the lock ends open")
    func removesInOrder() async throws {
        let harness = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true, unlocked: true)
        let mark = harness.log.events.count
        try await harness.lock.removeKeysAfterDecryption()
        let steps = harness.events(after: mark).filter {
            ["deleteBiometricKey", "lockMode=none", "deleteMasterKeyBlob", "wipeKey"].contains($0)
        }
        #expect(steps == ["deleteBiometricKey", "lockMode=none", "deleteMasterKeyBlob", "wipeKey"])
        #expect(harness.keys.password == nil)
        #expect(!harness.keys.hasBiometricKey)
        #expect(!harness.keys.isKeyLoaded)
        #expect(harness.lock.lockMode == .none)
        #expect(harness.lock.state == .open)
    }

    @Test("The legacy plaintext password item is deleted")
    func deletesLegacyItem() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        try await harness.lock.removeKeysAfterDecryption()
        #expect(harness.keychain.calls.contains(.delete(account: legacyAccount)))
    }

    @Test("A legacy item delete error is ignored")
    func legacyDeleteErrorIgnored() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        harness.keychain.errorToThrow = .keychain(-25300)
        try await harness.lock.removeKeysAfterDecryption()
        #expect(harness.lock.state == .open)
        #expect(harness.keys.password == nil)
    }

    @Test("Running it again after completion succeeds and changes nothing")
    func repeatable() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        try await harness.lock.removeKeysAfterDecryption()
        try await harness.lock.removeKeysAfterDecryption()
        #expect(harness.lock.lockMode == .none)
        #expect(harness.lock.state == .open)
        #expect(harness.keys.password == nil)
    }

    @Test("It also works when the vault was left locked")
    func fromLockedState() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, hasBiometricKey: true)
        try await harness.lock.removeKeysAfterDecryption()
        #expect(harness.keys.password == nil)
        #expect(!harness.keys.hasBiometricKey)
        #expect(harness.lock.state == .open)
    }

    @Test("A biometric item delete failure throws and leaves the later steps for the next call")
    func biometricDeleteFailureStops() async throws {
        let harness = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true, unlocked: true)
        harness.keys.failures = ["deleteBiometricKey": .keychain(-25244)]
        await #expect(throws: VaultLockError.keychain(-25244)) {
            try await harness.lock.removeKeysAfterDecryption()
        }
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.keys.password == secret)
        #expect(harness.keys.isKeyLoaded)

        harness.keys.failures = [:]
        try await harness.lock.removeKeysAfterDecryption()
        #expect(harness.lock.lockMode == .none)
        #expect(harness.keys.password == nil)
        #expect(!harness.keys.hasBiometricKey)
        #expect(!harness.keys.isKeyLoaded)
        #expect(harness.lock.state == .open)
    }

    @Test("A blob delete failure throws after the lock mode was cleared; the next call finishes")
    func blobDeleteFailureResumes() async throws {
        let harness = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true, unlocked: true)
        harness.keys.failures = ["deleteMasterKeyBlob": .keychain(-25244)]
        await #expect(throws: VaultLockError.keychain(-25244)) {
            try await harness.lock.removeKeysAfterDecryption()
        }
        #expect(harness.prefs.lockMode == .none)
        #expect(!harness.keys.hasBiometricKey)
        #expect(harness.keys.password == secret)
        #expect(harness.keys.isKeyLoaded)

        harness.keys.failures = [:]
        try await harness.lock.removeKeysAfterDecryption()
        #expect(harness.keys.password == nil)
        #expect(!harness.keys.isKeyLoaded)
        #expect(harness.lock.state == .open)
    }
}
