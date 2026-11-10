# Entitlements unit 1: handover to the switch-over (unit 2)

The unit 1 review passed with minor findings only. Unit 2 picks these up.

- **Tighten the finish assertions.** The legacy `EntitlementService` listener (started by `AppDelegate`) finishes
  verified transactions in the test host. Because of it, these checks are weak or missing in unit 1:
  - `purchaseUnlocks`'s "finishes the transaction" check;
  - "unverified purchase/update is not finished";
  - "verified update is finished".

  Once the switch-over deletes the legacy service, the test-writer (`ADOPT: switch-over`) should make these checks real
  where SKTestSession allows. SKTestSession does not redeliver transaction 0 through `Transaction.updates` across tests.
- **Re-lock window (reviewer, minor).** `purchase` sets unlocked directly after `finish()`. A refresh queued earlier
  (the init refresh, or one from the listener) that read `currentEntitlements` before the purchase can briefly apply
  `false`, until the next refresh corrects it. Suggested fix: `await refresh()` after unlocking, so the ordered queue
  has the last word. Unit 1 left it, because its attempts were used up. Raise it with the human at the switch-over.
- **Launch refresh.** `init` starts the refresh itself. The composition root needs no extra call.
- **Coverage.** The default `purchase` seam's real StoreKit call can't run in the hosted unit-test process (AMS 305).
  If coverage triage reports it, the reviewer considers it acceptable to exempt it with that reason. J9 covers it.
