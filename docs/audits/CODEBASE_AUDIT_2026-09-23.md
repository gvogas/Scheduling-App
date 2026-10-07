# Code review and improvements — 2026-09-23

Baseline: `6b96db46`, initially clean working tree. Changes are local and have
not been deployed.

This review concentrated on authorization, asynchronous data access, cache
freshness and repeated reads. It also inspected callable validation and scope
guards, appointment scan limits, client propagation and deletion, notification
fan-out, the security rules, CI, and the findings of the previous audits. It is
not an exhaustive certification of every Dart, JavaScript or native iOS path.

## Fixed

| Priority | Finding | Change and evidence |
|---|---|---|
| High | `syncUsersByUid` trusted event snapshots. A delayed activation could overwrite a later disabled state or recreate a deleted account's authorization bridge. | `bridge_reconcile.js` reads the current profile and affected bridges inside a Firestore transaction. Stale user-ID mappings are removed only when owned by that profile; another profile's mapping is protected. Tests exercise delayed activation, deletion, reactivation and ID rotation. |
| High | Employees could overwrite appointment photo bytes despite being prohibited from editing/deleting photo records. | Storage grants employee uploads only when `resource == null`. Metadata updates and deletion remain admin-only. Twelve checks run against real local Firebase emulators, including overwrite and metadata tampering attempts. |
| Medium | Every search-cache hit restarted its TTL, allowing a frequently used result to remain stale indefinitely. | Reads update LRU order while retaining the original freshness timestamp. An exact-boundary regression test includes an intervening cache hit. |
| Medium | An in-flight request could refill a cache after a local save or sign-out cleared it. | Cache generations guard completed search requests and client/history scans. Old completions cannot replace new results or remove a newer pending request. |
| Performance | Concurrent search/filter requests repeated identical network work before the first request finished. | Search requests share work by normalized query and scope; client filters share a scan; history scans share work within their employee/admin scope. Tests verify one scan for simultaneous consumers and recovery after failures. |

Firebase explicitly does not guarantee Firestore event ordering; see the
[trigger documentation](https://firebase.google.com/docs/functions/firestore-events).
Auth writes cannot participate in the Firestore transaction, so the Auth update
re-reads the profile afterward and reconciles again if its status changed. Three
unstable attempts throw, leaving the retry-enabled trigger to retry. This gives
convergence, not an atomic transaction across Auth and Firestore. The bridge
continues to be the data-access gate.

Storage's granular operation names alone were insufficient in the tested
emulator: uploading new bytes to an existing object was evaluated as `create`.
The explicit absent-resource condition is therefore essential. See Firebase's
[Storage rules reference](https://firebase.google.com/docs/reference/security/storage).

The concurrency changes reduce duplicated reads and calls; no device latency or
production billing benchmark was measured. Account-state changes now do extra
reads to reconcile safely; unrelated profile edits still return without doing
that work.

## Verification

- `flutter analyze --no-pub`: no issues.
- Full `flutter test --no-pub`: **3,784 passed**. The final focused cache/rules
  run also passed all **98** tests after the analyzer cleanup.
- Functions ESLint: clean.
- Functions Jest with coverage: **1,995 passed across 95 suites**. Coverage
  gates passed: statements **82.96%**, branches **77.05%**, functions
  **84.53%**, lines **83.43%**. The new bridge reconciliation module has
  **97.61% statement / 95.12% branch coverage**.
- Firebase emulators: **12 Storage authorization checks and 6 account-trigger
  checks passed**, including actual Firestore transactions and Auth updates.
- `git diff --check`: clean.

The Storage emulator printed a Java shutdown warning after the successful
checks; the emulator command exited 0. Leftover review Firestore Java processes
were stopped. No production project was used.

The emulator checks are reproducible using the command in
[`functions/__tests__/emulator/README.md`](../../functions/__tests__/emulator/README.md).
They deliberately reject production project IDs and non-local hosts.

## Remaining limits and follow-up

- **Client deletion versus concurrent booking:** `performDeleteClient` checks
  appointment count and then deletes the client in separate operations. A
  booking between those operations can still leave an appointment referring
  to a deleted client. The appointment create rule does not currently require
  the linked client to exist. Closing this needs a coordinated deletion and
  booking protocol plus emulator tests for both commit orders; it is outside
  this patch's authorization/cache changes.
- **Account provisioning:** the documented Auth password-reset versus employee
  setup race in `functions/CLAUDE.md` remains. Auth and Firestore cannot be
  committed atomically, and this review does not change the provisioning flow.
- **Native iOS validation:** no iOS build, physical-device performance test,
  push/Live Activity delivery test, or CarPlay test was run on this Windows
  workstation.
- The existing Maps billing-control follow-up in `AUDIT_FOLLOWUPS.md` remains.

## Rollout

The photo protection needs a Storage rules deployment. The account trigger
needs a Functions deployment, including its new helper module. Follow
`docs/DEPLOYMENT.md`; no public function names or callable payloads changed.
The cache improvements require an app release. Nothing in this review modifies
production data, deploys the backend, or publishes an app build.
