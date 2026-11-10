import Foundation

// coverage-exempt-file: declarations only

// VaultCatalog (feature multiple-vaults-duress-password; built in VaultLock unit 2): lists the vaults under
// `Vaults/`, reads and writes each vault's sealed `.vault_info` name, removes interrupted creations at launch,
// and reads and writes the Face ID vault marker.
