# LockMigration unit 1 review follow-ups (reviewer pass, 2026-10-29)

For coverage triage (missed tests; fakes need injectable failures per store/lock method):
- `.stillEncrypted` from finishDecryption → `.failed(names: [])`, then Retry (re-list, migrate) and Skip (keeps lock and keys)
- finishEncryption failing with the key loaded → logged, still completes
- itemsToMigrate failure then Retry; removeKeysAfterDecryption failure then Retry
- Skip after encrypt with a failing switchMode → logs, still completes
- key wipe during finishDecryption / removeKeys (not only kills)
- Fake fidelity: FakeMigrationLock.switchMode should throw `.notUnlocked` without a key or to/from `.none`; removeKeysAfterDecryption should wipe the key and go `.open`

Minor code notes (pending the human's decision):
- drive: resuming while locked from an in-memory pause publishes `.running` then `.paused` (spinner flicker) — check keyLoaded before the first running update
- start while `.paused` / `.failed` (not busy) replaces the run and pending record
