import Foundation

/// The encrypted vaults under `Application Support/Vaults/` (feature multiple-vaults-duress-password).
///
/// A vault is a folder `Vaults/<vaultID>/` whose master-key blob exists in the Keychain. The catalog lists the
/// vaults, removes interrupted creations (a folder with no blob), reads and writes each vault's sealed
/// `.vault_info` name, and reads and writes the Face ID vault marker. No list of vaults is stored anywhere else.
struct VaultCatalog: Sendable {
    /// The ID of the vault the one-time upgrade makes from the old single vault.
    static let primaryID = "primary"
    /// The Keychain account of the plain item naming the one vault that has Face ID (UTF-8 vault ID).
    static let markerAccount = "com.KoalaTVault.biometricVaultID"
    /// The name shown for a vault whose `.vault_info` is missing or unreadable.
    static let defaultName = "My Vault"

    private static let legacyBlobAccount = "com.KoalaTVault.masterKeyBlob"
    private static let infoFileName = ".vault_info"
    private static let infoContext = ".vault_info"

    private let vaultsFolder: URL
    private let keychain: any KeychainAccessing

    /// A catalog of the vaults in `vaultsFolder`, checking blobs and the marker through `keychain`.
    init(vaultsFolder: URL, keychain: any KeychainAccessing) {
        self.vaultsFolder = vaultsFolder
        self.keychain = keychain
    }

    /// The Keychain account holding the master-key blob of `vaultID`: the old account for the primary vault,
    /// the old account plus `.<vaultID>` for any other.
    static func blobAccount(for vaultID: String) -> String {
        vaultID == primaryID ? legacyBlobAccount : "\(legacyBlobAccount).\(vaultID)"
    }

    /// The root folder of `vaultID`.
    func folderURL(for vaultID: String) -> URL {
        vaultsFolder.appendingPathComponent(vaultID)
    }

    /// The IDs of the vaults (folders whose blob exists), sorted. A missing `Vaults/` folder means no vaults.
    func vaultIDs() -> [String] {
        folderIDs().filter(blobExists).sorted()
    }

    /// Removes every folder under `Vaults/` whose blob is missing (an interrupted creation, which holds no files).
    /// A Keychain error counts as the blob existing, so a vault is never removed on an error. A folder that cannot
    /// be removed is left for the next launch.
    func removeInterruptedCreations() {
        for id in folderIDs() where !blobExists(id) {
            try? FileManager.default.removeItem(at: folderURL(for: id))
        }
    }

    /// The name sealed in the vault's `.vault_info`, or nil when it is missing or cannot be read or opened
    /// (callers then show `defaultName`).
    func readName(of vaultID: String, cipher: any FileCipher) -> String? {
        let url = folderURL(for: vaultID).appendingPathComponent(Self.infoFileName)
        guard let sealed = try? Data(contentsOf: url),
            let plain = try? cipher.decrypt(sealed, contexts: [Self.infoContext]),
            let info = try? JSONDecoder().decode(VaultInfo.self, from: plain)
        else { return nil }
        return info.name
    }

    /// Writes `name` to the vault's `.vault_info` as JSON `{ "name": … }` sealed under the `.vault_info` context.
    /// - Throws: the cipher's error, or a file-system error writing the file.
    func writeName(_ name: String, of vaultID: String, cipher: any FileCipher) throws {
        let plain = try JSONEncoder().encode(VaultInfo(name: name))
        let sealed = try cipher.encrypt(plain, context: Self.infoContext)
        let url = folderURL(for: vaultID).appendingPathComponent(Self.infoFileName)
        try sealed.write(to: url, options: .atomic)
    }

    /// The ID of the vault that has Face ID, or nil when there is none, the item is not UTF-8, or the Keychain fails.
    func biometricVaultID() -> String? {
        guard let data = try? keychain.read(account: Self.markerAccount, prompt: nil) else { return nil }
        guard let id = String(bytes: data, encoding: .utf8), !id.isEmpty else { return nil }
        return id
    }

    /// Sets the Face ID vault marker to `vaultID` (accessible when unlocked), or deletes it when nil.
    /// - Throws: `VaultCryptoError.keychain` from the Keychain.
    func setBiometricVaultID(_ vaultID: String?) throws {
        if let vaultID {
            try keychain.write(Data(vaultID.utf8), account: Self.markerAccount, accessibility: .whenUnlocked)
        } else {
            try keychain.delete(account: Self.markerAccount)
        }
    }

    /// The names of the subfolders of `Vaults/` (plain files are ignored); empty when the folder is missing.
    private func folderIDs() -> [String] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: vaultsFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return entries.compactMap { url in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isFolder ? url.lastPathComponent : nil
        }
    }

    /// Whether `vaultID`'s blob exists; a Keychain error counts as existing.
    private func blobExists(_ vaultID: String) -> Bool {
        do {
            return try keychain.read(account: Self.blobAccount(for: vaultID), prompt: nil) != nil
        } catch {
            return true
        }
    }
}

/// The JSON sealed in `.vault_info`.
private struct VaultInfo: Codable {
    let name: String
}
