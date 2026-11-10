# Faster lock changes in large folders

<!-- Added with `feature add`. The orchestrator fills the sections below during the feature's stage 1. -->

## Idea
Turning the lock on or off re-reads, decrypts, checks and rewrites a folder's whole index for every file, so time grows with the square of the folder size (device test 2026-11-09: about 1 file/sec in a 9,090-file folder with an 850 KB index; the trash repeats the same pattern via correctedTrashMap probing every trash file per item). Options discussed: batch files per index write (contract change to VaultStore and LockMigration, fastest, equally crash-safe), or cache each folder's index in memory during a run (no contract change, a few times faster).

## Discussion notes

## Agreed scope
- New or changed journeys:
- New or changed screens:
- Affected modules (new / changed):
- Contract changes:
- Out of scope:
