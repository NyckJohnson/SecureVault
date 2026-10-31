<!-- ios-pipeline:begin (managed by `ios-pipeline init`; do not edit this block) -->
@/Users/nicholasjohnson/Documents/Programs/ios-agent-pipeline/orchestrator.md
<!-- ios-pipeline:end -->

# App notes

Anything specific to this app that every session should know goes here, below the
managed block above.

- Logic in contracts: `Preferences/Contracts/PreferencesModels.swift`, `VaultStore/Contracts/VaultStoreModels.swift`
  and `SharedUI/Contracts/FileIconMappingContract.swift` hold real code. In each owning module's unit 1, the
  test-writer brief lists that file and its spec bullet in READ and ACCEPTANCE. Coverage triage may never
  classify their lines `exempt`, and the reviewer checks that every branch has an asserting test, not just
  coverage. Never add a `coverage-exempt` marker to these files.
- `VaultCrypto/Contracts/VaultCryptoContract.swift` also holds real code (`VaultCryptoError.errorDescription`,
  added in VaultCrypto's switch-over unit). Same rules: tested, never `coverage-exempt`.
- `VaultStore/Contracts/VaultStoring.swift` also holds real code (`VaultStoreError.errorDescription`, added during SharedUI
  unit 1, approved 2026-10-29). Same rules: tested, never `coverage-exempt`.
- `Import/Contracts/ImportContract.swift` also holds real code (`ImportError.errorDescription`, added during Import unit 1, approved
  2026-10-30). Same rules: tested, never `coverage-exempt`.
