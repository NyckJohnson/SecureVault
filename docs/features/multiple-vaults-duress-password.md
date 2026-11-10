# Multiple vaults / duress password

<!-- Added with `feature add`. The orchestrator fills the sections below during the feature's stage 1. -->

## Idea
more than one vault, each with its own password, including a duress password that opens a decoy vault

From the human (2026-11-10): there is always one unencrypted vault, and the user can make encrypted vaults; more than one
encrypted vault is part of Pro. The app opens to the unencrypted vault's root. A Vaults button lets the user type a
vault's password, which finds the matching vault and opens it, or create a new vault. Because any password simply opens
the vault it belongs to, a second vault doubles as a duress (decoy) vault.

## Discussion notes
- 2026-11-10 (human): the app-wide lock goes: no setup wizard, no lock screen at launch, no Settings → Lock Mode and no
  encrypt/decrypt-everything migration. Encryption belongs to each vault, fixed when it's created.
- 2026-11-10 (human): sending the app to the background while an encrypted vault is open closes it (key and plaintext temp
  files wiped); returning shows the unencrypted vault's root, no lock screen.
- 2026-11-10 (human): the free 100-file limit counts per vault (each vault up to 100 files without Pro). Pro also allows
  more than one encrypted vault.
- Assumed (stated to the human, not objected to): upgrading a No Lock vault → its files are the unencrypted vault;
  upgrading a locked vault → it becomes the first encrypted vault with the same password and the unencrypted vault starts
  empty. The app never shows how many encrypted vaults exist; the Vaults button shows only a password field and "Create
  New Vault"; Settings inside an open vault manages that vault only. Each vault has its own folders, trash and Storage.

## Agreed scope
- New or changed journeys:
- New or changed screens:
- Affected modules (new / changed):
- Contract changes:
- Out of scope:
