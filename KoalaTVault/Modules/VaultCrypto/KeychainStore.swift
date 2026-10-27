import Foundation
import LocalAuthentication
import Security

/// The real Keychain: generic password items in one service, keyed by account.
///
/// Errors are `VaultCryptoError`: `.keychain(status)` for a failed `SecItem*` call, and for a
/// read that shows a biometric prompt the typed biometric cases (`.biometricCancelled`,
/// `.biometryLockedOut`, `.biometryNotEnrolled`, `.passcodeNotSet`).
struct KeychainStore: KeychainAccessing {
    private let service: String
    private let unscopedAccounts: Set<String>

    /// A store for the items of `service`.
    /// - Parameter unscopedAccounts: accounts whose deletes match items of any service. Older app
    ///   versions stored the plaintext password item without a service, so deleting it by service
    ///   alone would leave it behind.
    init(service: String, unscopedAccounts: Set<String> = [LiveMasterKeyStore.legacyPasswordAccount]) {
        self.service = service
        self.unscopedAccounts = unscopedAccounts
    }

    func read(account: String, prompt: String?) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let prompt {
            // A fresh, non-pre-evaluated context: the Keychain read is the only authentication gate.
            let context = LAContext()
            context.localizedReason = prompt
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw VaultCryptoError.keychain(errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            // coverage-exempt-begin: a failing SecItemCopyMatching can't be provoked on the simulator
            if prompt != nil { throw Self.biometricError(for: status) }
            throw VaultCryptoError.keychain(status)
            // coverage-exempt-end
        }
    }

    func write(_ data: Data, account: String, accessibility: KeychainAccessibility) throws {
        switch accessibility {
        case .whenUnlocked:
            try writeUpdatingInPlace(data, account: account)
        case .biometryCurrentSetThisDeviceOnly:
            try writeBiometric(data, account: account) // coverage-exempt: needs passcode and biometrics
        }
    }

    func delete(account: String) throws {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        if !unscopedAccounts.contains(account) {
            query[kSecAttrService as String] = service
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultCryptoError.keychain(status) // coverage-exempt: SecItemDelete failure can't be provoked
        }
    }

    // MARK: - Private

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
        query[kSecAttrService as String] = service
        query[kSecAttrAccount as String] = account
        return query
    }

    /// Updates the item in place (so a failure leaves the old data), adding it when absent.
    private func writeUpdatingInPlace(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        var attributes: [String: Any] = [kSecValueData as String: data]
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw VaultCryptoError.keychain(addStatus) }
        default:
            throw VaultCryptoError.keychain(updateStatus) // coverage-exempt: SecItemUpdate failure can't be provoked
        }
    }

    // coverage-exempt-begin: needs a passcode and enrolled biometrics
    /// Writes an item readable only after biometric authentication on this device, invalidated
    /// when the enrolled biometrics change (`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` +
    /// `.biometryCurrentSet`).
    ///
    /// The new item is written before the old one is removed, so a failure leaves the old item:
    /// access control can't be changed by `SecItemUpdate`, so an existing item gets its data
    /// replaced in place without user interaction (same access control as a new item). Only
    /// when the old item can't be updated without user interaction (`errSecInteractionNotAllowed`
    /// or `errSecAuthFailed`, e.g. it was invalidated) is it deleted and re-added; a failed
    /// re-add there leaves no item. If it vanished meanwhile (`errSecItemNotFound`) it is just
    /// added. Any other update status throws `.keychain(status)` and leaves the old item.
    private func writeBiometric(_ data: Data, account: String) throws {
        var accessError: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &accessError)
        guard let access else {
            accessError?.release()
            throw VaultCryptoError.keychain(errSecParam)
        }
        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessControl as String] = access

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecDuplicateItem else {
            guard addStatus == errSecSuccess else { throw VaultCryptoError.keychain(addStatus) }
            return
        }

        var updateQuery = baseQuery(account: account)
        let silent = LAContext()
        silent.interactionNotAllowed = true
        updateQuery[kSecUseAuthenticationContext as String] = silent
        let updateStatus = SecItemUpdate(
            updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecInteractionNotAllowed, errSecAuthFailed:
            try delete(account: account)
        case errSecItemNotFound:
            break
        default:
            throw VaultCryptoError.keychain(updateStatus)
        }
        let retryStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard retryStatus == errSecSuccess else { throw VaultCryptoError.keychain(retryStatus) }
    }
    // coverage-exempt-end

    /// Maps a failed biometric-prompted read to its typed error.
    ///
    /// The Keychain reports some LocalAuthentication outcomes with the `LAError` code as the
    /// status, and others only as `errSecAuthFailed`; for the latter the device's biometric
    /// state is checked (without prompting) to tell lockout, enrollment and passcode apart.
    static func biometricError(for status: OSStatus) -> VaultCryptoError {
        // -4 is both `LAError.systemCancel` and `errSecUnimplemented`; only the latter is meant here.
        if status != errSecUnimplemented, let mapped = map(laCode: Int(status)) { return mapped }
        if status == errSecUserCanceled { return .biometricCancelled }
        // coverage-exempt-begin: needs device biometric state (LAContext().canEvaluatePolicy)
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            var policyError: NSError?
            let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
            let canEvaluate = LAContext().canEvaluatePolicy(policy, error: &policyError)
            if !canEvaluate, let policyError, policyError.domain == LAError.errorDomain {
                if let mapped = map(laCode: policyError.code) { return mapped }
            }
        }
        // coverage-exempt-end
        return .keychain(status)
    }

    /// Maps a LocalAuthentication error code to its typed error, or `nil` for codes with no
    /// dedicated case (cancel-like codes all become `.biometricCancelled`).
    static func map(laCode: Int) -> VaultCryptoError? {
        switch LAError.Code(rawValue: laCode) {
        case .userCancel, .systemCancel, .appCancel, .userFallback:
            return .biometricCancelled
        case .biometryLockout:
            return .biometryLockedOut
        case .biometryNotEnrolled:
            return .biometryNotEnrolled
        case .passcodeNotSet:
            return .passcodeNotSet
        default:
            return nil
        }
    }
}
