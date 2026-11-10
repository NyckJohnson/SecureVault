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

## Fix round review (pass) — for coverage triage
- Resolved: injectable step failures, fake fidelity, locked-resume flicker, start while paused/failed.
- Add: `skipCompletesWhenSwitchModeFails` should assert switchMode was attempted; `finishEncryptionFailureStillCompletes` should assert finishEncryption was called.
- Add: kill-resume variant of "locked resume goes straight to paused" (fresh migrator, pending record, locked → no `.running`), if not already covered.
- Spec bullet "target never `.none`; encrypt pending with lockMode `.none` is the launch recovery's job" has no assertion (the migrator would loop on `.failed(names: [])`; launch recovery prevents reaching it). Note for the switch-over: callers must resolve that case before `resumeIfPending`.
- `start` with a stale pending record from an earlier process (run == nil) replaces it — consistent with the spec; callers must call `resumeIfPending` at unlock before the user can start anything.
