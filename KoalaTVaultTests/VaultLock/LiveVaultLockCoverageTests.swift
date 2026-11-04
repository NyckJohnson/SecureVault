import Foundation
import Security
import Testing

@testable import KoalaTVault

private let secret = "correct horse"
private let otherSecret = "battery staple"

// MARK: - setUp / prepareToAddLock failure paths

@MainActor
@Suite struct LiveVaultLockEstablishKeyFailureTests {
    @Test("An existing blob over encrypted data whose unlock fails with a Keychain error throws it and changes nothing")
    func unlockKeychainFailure() async throws {
        let harness = try await VaultLockHarness(blobPassword: secret, vaultHasEncryptedData: true)
        harness.keys.failures = ["unlock": .keychain(-25293)]
        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await harness.lock.prepareToAddLock(mode: .password, password: secret)
        }
        #expect(!harness.log.events.contains("createMasterKey"))
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.lockMode == .none)
    }

    @Test("A stale blob whose delete fails throws the mapped error and creates nothing")
    func staleBlobDeleteFailure() async throws {
        let harness = try await VaultLockHarness(blobPassword: otherSecret, vaultHasEncryptedData: false)
        harness.keys.failures = ["deleteMasterKeyBlob": .keychain(-25244)]
        await #expect(throws: VaultLockError.keychain(-25244)) {
            try await harness.lock.setUp(mode: .password, password: secret)
        }
        #expect(!harness.log.events.contains("createMasterKey"))
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.lockMode == .none)
    }

    @Test("A failure creating the key throws the mapped error and writes no lock mode")
    func createFailure() async throws {
        let harness = try await VaultLockHarness()
        harness.keys.failures = ["createMasterKey": .keychain(-25299)]
        await #expect(throws: VaultLockError.keychain(-25299)) {
            try await harness.lock.setUp(mode: .password, password: secret)
        }
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.lockMode == .none)
    }

    @Test("A rollback whose blob delete also fails still throws the original biometric error and wipes the key")
    func rollbackDeleteFailure() async throws {
        let harness = try await VaultLockHarness()
        harness.keys.failures["storeBiometricKey"] = .keychain(-25293)
        harness.keys.failures["deleteMasterKeyBlob"] = .keychain(-25244)
        await #expect(throws: VaultLockError.keychain(-25293)) {
            try await harness.lock.setUp(mode: .passwordAndBiometrics, password: secret)
        }
        #expect(harness.log.events.contains("deleteMasterKeyBlob"))
        #expect(!harness.keys.isKeyLoaded)
        #expect(!harness.keys.hasBiometricKey)
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.lockMode == .none)
    }

    @Test("A stale biometric item that can't be deleted does not stop setUp")
    func staleBiometricDeleteFailureIgnored() async throws {
        let harness = try await VaultLockHarness(
            blobPassword: otherSecret, hasBiometricKey: true, vaultHasEncryptedData: false)
        harness.keys.failures = ["deleteBiometricKey": .keychain(-25244)]
        try await harness.lock.setUp(mode: .password, password: secret)
        #expect(harness.keys.password == secret)
        #expect(harness.prefs.lockModeWrites == [.password])
        #expect(harness.lock.state == .unlocked)
    }

    @Test("A mismatched biometric item that can't be deleted still throws biometricChanged and wipes the key")
    func mismatchedItemDeleteFailureIgnored() async throws {
        let harness = try await VaultLockHarness(
            lockMode: .passwordAndBiometrics, blobPassword: secret, hasBiometricKey: true,
            keyMatchesVault: false)
        harness.keys.failures = ["deleteBiometricKey": .keychain(-25244)]
        await #expect(throws: VaultLockError.biometricChanged) {
            try await harness.lock.unlockWithBiometrics()
        }
        #expect(!harness.keys.isKeyLoaded)
        #expect(harness.log.events.contains("wipeKey"))
        #expect(harness.lock.state == .locked)
    }
}

// MARK: - Error mapping

@MainActor
@Suite struct LiveVaultLockErrorMappingTests {
    // swiftlint:disable trailing_comma
    @Test(
        "Key-store errors map to lock errors",
        arguments: [
            (VaultCryptoError.corruptBlob, VaultLockError.keychain(errSecDecode)),
            (VaultCryptoError.invalidKeyData, VaultLockError.keychain(errSecDecode)),
            (VaultCryptoError.encryptionFailed, VaultLockError.keychain(errSecDecode)),
            (VaultCryptoError.decryptionFailed, VaultLockError.keychain(errSecDecode)),
            (VaultCryptoError.masterKeyAlreadyExists, VaultLockError.keychain(errSecDuplicateItem)),
            (VaultCryptoError.noMasterKeyBlob, VaultLockError.passwordMissing),
            (VaultCryptoError.noKeyLoaded, VaultLockError.notUnlocked),
            (VaultCryptoError.keychain(-25293), VaultLockError.keychain(-25293)),
            (VaultCryptoError.emptyPassword, VaultLockError.emptyPassword),
            (VaultCryptoError.wrongPassword, VaultLockError.wrongPassword),
        ])
    // swiftlint:enable trailing_comma
    func cryptoErrorMapping(crypto: VaultCryptoError, expected: VaultLockError) async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        harness.keys.failures = ["unlock": crypto]
        await #expect(throws: expected) {
            try await harness.lock.unlock(password: secret)
        }
        #expect(harness.lock.state == .locked)
    }

    @Test("An error that is not a key-store error becomes a Keychain internal error")
    func unknownErrorMapping() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        harness.keys.anyFailures = ["unlock": CocoaError(.fileReadUnknown)]
        await #expect(throws: VaultLockError.keychain(errSecInternalError)) {
            try await harness.lock.unlock(password: secret)
        }
    }

    @Test("A lock error from the key store passes through unchanged")
    func lockErrorPassesThrough() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret)
        harness.keys.anyFailures = ["unlock": VaultLockError.passcodeNotSet]
        await #expect(throws: VaultLockError.passcodeNotSet) {
            try await harness.lock.unlock(password: secret)
        }
    }
}

// MARK: - switchMode and changePassword edges

@MainActor
@Suite struct LiveVaultLockSwitchModeEdgeTests {
    @Test("Enabling biometrics while they are unavailable throws biometricsUnavailable and stores nothing")
    func enableBiometricsUnavailable() async throws {
        let harness = try await VaultLockHarness(
            lockMode: .password, blobPassword: secret, biometricKind: .none, biometricsEnabled: false,
            unlocked: true)
        let mark = harness.log.events.count
        await #expect(throws: VaultLockError.biometricsUnavailable) {
            try await harness.lock.switchMode(to: .passwordAndBiometrics)
        }
        #expect(!harness.events(after: mark).contains("storeBiometricKey"))
        #expect(!harness.keys.hasBiometricKey)
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.lockMode == .password)
    }

    @Test("Switching to the current mode does nothing", arguments: [LockMode.password, .passwordAndBiometrics])
    func switchToCurrentModeIsNoOp(mode: LockMode) async throws {
        let harness = try await VaultLockHarness(
            lockMode: mode, blobPassword: secret, hasBiometricKey: mode == .passwordAndBiometrics, unlocked: true)
        let mark = harness.log.events.count
        try await harness.lock.switchMode(to: mode)
        #expect(harness.events(after: mark).isEmpty)
        #expect(harness.prefs.lockModeWrites.isEmpty)
        #expect(harness.lock.lockMode == mode)
    }

    @Test("A rewrap failure after the current password verifies throws the mapped error and keeps the old password")
    func rewrapFailure() async throws {
        let harness = try await VaultLockHarness(lockMode: .password, blobPassword: secret, unlocked: true)
        harness.keys.failures = ["rewrap": .keychain(-25299)]
        await #expect(throws: VaultLockError.keychain(-25299)) {
            try await harness.lock.changePassword(current: secret, new: otherSecret)
        }
        #expect(harness.keys.password == secret)
        harness.lock.appDidEnterBackground()
        try await harness.lock.unlock(password: secret)
        #expect(harness.lock.state == .unlocked)
    }
}

// MARK: - VaultEncryptedDataCheck

@Suite struct VaultEncryptedDataCheckTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A subdirectory that can't be read counts as encrypted data")
    func unreadableSubdirectory() throws {
        let root = try makeRoot()
        let sub = root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sub.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(VaultEncryptedDataCheck.holdsEncryptedData(at: root, fileManager: .default))
    }

    @Test("A non-empty trash folder counts as encrypted data and an empty one does not")
    func trashFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent(".trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        #expect(!VaultEncryptedDataCheck.holdsEncryptedData(at: root, fileManager: .default))
        try Data("x".utf8).write(to: trash.appendingPathComponent(UUID().uuidString))
        #expect(VaultEncryptedDataCheck.holdsEncryptedData(at: root, fileManager: .default))
    }

    private func holds(_ root: URL) -> Bool {
        VaultEncryptedDataCheck.holdsEncryptedData(at: root, fileManager: .default)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test("A vault with only plaintext files, nested or empty, holds no encrypted data")
    func onlyPlaintext() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("hello world", to: root.appendingPathComponent("note.txt"))
        try write("nested plaintext", to: root.appendingPathComponent("a/b/deep.txt"))
        try write("", to: root.appendingPathComponent("empty.dat"))
        #expect(!holds(root))
    }

    @Test("A .vault_map index alone in a subfolder counts as encrypted data")
    func indexAloneInSubfolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("anything", to: root.appendingPathComponent("Sub/.vault_map"))
        #expect(holds(root))
    }

    @Test("A .trash_map file alone counts as encrypted data")
    func trashMapAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("anything", to: root.appendingPathComponent(".trash_map"))
        #expect(holds(root))
    }

    @Test("A file with the SVC5 header counts as encrypted data even without an index")
    func headerFileWithoutIndex() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("SVC5 and then some bytes", to: root.appendingPathComponent("photo.bin"))
        #expect(holds(root))
    }

    @Test("A missing root counts as encrypted data")
    func missingRoot() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(holds(root))
    }

    @Test("A completely empty root holds no encrypted data")
    func emptyRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!holds(root))
    }

    @Test("A root that can't be listed counts as encrypted data")
    func permissionDeniedRoot() throws {
        let root = try makeRoot()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(holds(root))
    }

    @Test(
        "Plain, empty and too-short files are not encrypted data; an SVC5-header file is",
        arguments: [("plain text file", false), ("", false), ("SV", false), ("SVC5", true)])
    func fileContentDecides(content: String, expected: Bool) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(content, to: root.appendingPathComponent("file.bin"))
        #expect(holds(root) == expected)
    }

    @Test("A file that can't be read counts as encrypted data")
    func unreadableFile() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("secret.txt")
        try write("plain", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(holds(root))
    }
}
