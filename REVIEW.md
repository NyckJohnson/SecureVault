# KoalaTVault Code Review Ledger

### Should-fix

**S2. No minimum password strength**

- Where: password setup (`SetupWizard`, `SecuritySettings.promptSetPassword`, `promptChangePassword`); `CryptoService.deriveKey` only rejects empty.

- Issue: the wrapped master-key blob is included in backups by design, so it can be brute-forced offline. PBKDF2 at 600k iterations slows this down, but a short password (e.g. 4 digits) still falls quickly.

- Fix: require a minimum length (e.g. 8+ characters) and show a strength hint.

- Status: Open

