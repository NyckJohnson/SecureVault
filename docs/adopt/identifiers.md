# Accessibility identifiers (adoption Stage 3)

Identifiers added to legacy screens so the journey tests can find their elements.
Names follow `<screen>.<element>`. Identifiers that already existed are kept unchanged and marked "(existing)".

## Setup wizard (`KoalaTVault/View/SetupWizard.swift`)

| element | identifier | journey |
| --- | --- | --- |
| Continue button | `continueButton` (existing) | 1 |
| Title "Welcome to Koala T Vault" | `setupWizard.titleLabel` | 1 |
| No Lock card | `setupWizard.noLockCard` | 1 |
| Password card | `setupWizard.passwordCard` | 1 |
| Password + biometric card | `setupWizard.biometricCard` | 1 |
| "Set Password" alert, password field | `setupWizard.passwordField` | 1 |
| "Set Password" alert, confirm field | `setupWizard.confirmPasswordField` | 1 |

## Lock screen (`KoalaTVault/View/LockScreen.swift`)

| element | identifier | journey |
| --- | --- | --- |
| Password field | `passwordField` (existing) | 2 |
| Unlock button | `unlockButton` (existing) | 2 |
| Title "KoalaTVault Locked" | `lockScreen.titleLabel` | 2 |
| "Use Face ID/Touch ID" button | `lockScreen.biometricButton` | 2 |
| Error label | `lockScreen.errorLabel` | 2 |

## Migration (`KoalaTVault/View/Migration.swift`)

| element | identifier | journey |
| --- | --- | --- |
| Title "Encrypting Files" / "Decrypting Files" | `migration.titleLabel` | 8 |
| Progress bar | `migration.progressBar` | 8 |
| Status label ("Preparing...", "N% complete", "Paused — unlock to continue", "Complete") | `migration.statusLabel` | 8 |
